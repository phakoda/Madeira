import SwiftUI
import UIKit
import QuartzCore

/// A refresh-rate REQUEST, not a guarantee of 120 Hz. The system can lower
/// refresh for power/thermal reasons. Per-view leases avoid rotation teardown
/// of an old overlay stopping a newly attached overlay's display link.
final class ProMotionIntent: NSObject {
    static let shared = ProMotionIntent()
    private var link: CADisplayLink?
    private var owners = Set<UUID>()

    func setActive(_ active: Bool, source: UUID) {
        if active { owners.insert(source) } else { owners.remove(source) }
        guard !owners.isEmpty, UIApplication.shared.applicationState == .active else {
            link?.invalidate(); link = nil
            return
        }
        let maximum = Float(max(UIScreen.main.maximumFramesPerSecond, 1))
        if link == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }
        link?.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }
    @objc private func tick(_ sender: CADisplayLink) {}
}

/// Guest-present throughput with a 1–5 second adaptive window. One 250 ms
/// timer samples and publishes together; no separate 100 ms SwiftUI churn.
/// Tap the readout to hide it. Sampling stops while hidden or inactive.
struct FPSOverlay: View {
    var compact: Bool = false
    private final class SamplingState { var sampler = FrameRateSampler() }
    private struct Reading {
        var presents: UInt64 = 0
        var fps: Double = 0
        var footprintMB: Int?
        var availableMB: Int?
    }
    @State private var reading = Reading()
    @State private var sampling = SamplingState()
    @State private var visible = true
    @State private var attached = false
    @State private var foreground = false
    @State private var timer: Timer?
    @State private var source = UUID()
    /// 1 = request 60; 0 = display maximum; 2 = unthrottled guest/mailbox.
    @State private var vsyncMode: Int32 = 1

    private func readFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / (1024 * 1024))
    }
    private var memColor: Color {
        guard let free = reading.availableMB else { return .secondary }
        if free > 768 { return .green }
        if free > 384 { return .yellow }
        if free > 128 { return .orange }
        return .red
    }
    private var memoryLabel: String {
        reading.footprintMB.map { "\($0)MB" } ?? "—MB"
    }
    private var memoryAccessibilityLabel: String {
        let footprint = reading.footprintMB.map { "\($0) megabytes used" } ?? "Memory usage unavailable"
        let available = reading.availableMB.map { ", approximately \($0) megabytes available to the process" } ?? ""
        return footprint + available
    }
    private var fpsText: some View {
        Text(String(format: "%.1f", reading.fps))
            .foregroundColor(fpsColor)
            .accessibilityLabel(String(format: "%.1f guest presents per second", reading.fps))
    }
    var body: some View {
        Group {
            if visible && compact {
                VStack(spacing: 4) {
                    fpsText.contentShape(Rectangle()).onTapGesture { visible = false }
                    pacingPill
                }
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color.black.opacity(0.55))
                .cornerRadius(6)
            } else if visible {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(memoryLabel)
                            .foregroundColor(memColor)
                            .frame(width: 56, alignment: .trailing)
                            .accessibilityLabel(memoryAccessibilityLabel)
                        Text("|").foregroundColor(.secondary)
                        Text("Present:").foregroundColor(.secondary)
                        Text("\(reading.presents)").foregroundColor(.primary)
                        Text("|").foregroundColor(.secondary)
                        Text("FPS:").foregroundColor(.secondary)
                        fpsText.frame(width: 40, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { visible = false }
                    pacingPill
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(6)
            } else {
                Button { visible = true } label: {
                    Circle().fill(Color.black.opacity(0.3)).frame(width: 12, height: 12)
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show performance overlay")
            }
        }
        .onAppear {
            attached = true
            foreground = UIApplication.shared.applicationState == .active
            resume()
        }
        .onDisappear {
            attached = false
            suspend()
        }
        .onChange(of: visible) { _ in updateSampling() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            foreground = false
            suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            foreground = true
            resume()
        }
    }
    private var pacingPill: some View {
        Button {
            vsyncMode = vsyncMode == 1 ? 0 : (vsyncMode == 0 ? 2 : 1)
            madeira_set_vsync_locked(vsyncMode)
            updateRefreshIntent()
        } label: {
            Text(pillLabel).foregroundColor(pillColor)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(pillColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Frame pacing: \(pillLabel). Tap to change.")
    }
    private var pillLabel: String {
        switch vsyncMode {
        case 1: return "60"
        case 0: return "MAX(\(UIScreen.main.maximumFramesPerSecond))"
        default: return "RAW"
        }
    }
    private var pillColor: Color {
        switch vsyncMode {
        case 1: return .cyan
        case 0: return .pink
        default: return .orange
        }
    }
    private var fpsColor: Color {
        if reading.fps >= 50 { return .green }
        if reading.fps >= 30 { return .yellow }
        if reading.fps >= 1 { return .orange }
        if reading.fps > 0 { return Color(red: 1, green: 0.4, blue: 0.2) }
        return .secondary
    }
    private func updateRefreshIntent() {
        ProMotionIntent.shared.setActive(attached && foreground && vsyncMode != 1, source: source)
    }
    private func resume() {
        guard attached else { return }
        let mode = madeira_get_vsync_locked()
        vsyncMode = (0...2).contains(mode) ? mode : 1
        updateRefreshIntent()
        updateSampling()
    }
    private func suspend() {
        timer?.invalidate(); timer = nil
        sampling.sampler.reset()
        ProMotionIntent.shared.setActive(false, source: source)
    }
    private func updateSampling() {
        timer?.invalidate(); timer = nil
        sampling.sampler.reset()
        guard attached && foreground && visible else { return }
        sample()
        let next = Timer(timeInterval: 0.25, repeats: true) { _ in sample() }
        next.tolerance = 0.025
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
    private func sample() {
        let count = madeira_get_present_count()
        let fps = sampling.sampler.record(count: count, at: CACurrentMediaTime())
        let available = madeira_available_process_memory_bytes()
        // This is a live estimate, NOT a universal jetsam threshold or a
        // guarantee that an allocation of this size will succeed.
        reading = Reading(presents: count, fps: fps, footprintMB: readFootprintMB(),
            availableMB: available == UInt64.max ? nil : Int(available / (1024 * 1024)))
    }
}
