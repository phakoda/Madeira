// Opt-in public GCMouse input. Capture is limited to hovering over the active
// guest surface: host controls remain reachable. This is NOT pointer locking.
// All mutable state and device callbacks are confined to the main thread.
// GPL-3.0-or-later.
import UIKit
import GameController
import Combine

protocol MousePointerTarget: ControllerPointerTarget {
    var mouseCaptureAllowed: Bool { get }
}

final class PhysicalMouseBridge: NSObject, ObservableObject {
    static let shared = PhysicalMouseBridge()
    @Published private(set) var connectedCount = 0

    private final class Session {
        let mouse: GCMouse
        let input: GCMouseInput
        var buttons: [(GCControllerButtonInput, UUID)] = []
        var x = PointerDeltaAccumulator(), y = PointerDeltaAccumulator()
        var wheelX = PointerDeltaAccumulator(), wheelY = PointerDeltaAccumulator()
        init(_ mouse: GCMouse, _ input: GCMouseInput) { self.mouse = mouse; self.input = input }
    }
    private weak var target: MousePointerTarget?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var enabled = false, sensitivity = 1.0
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshCapture()
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.stopCapture()
        })
        connectedCount = GCMouse.mice().count
    }

    func configure(enabled: Bool, sensitivity: Double) {
        precondition(Thread.isMainThread)
        let value = PointerMotion.sensitivity(sensitivity)
        if self.enabled != enabled || self.sensitivity != value { stopCapture() }
        self.enabled = enabled; self.sensitivity = value
        refreshCapture()
    }
    func attach(_ target: MousePointerTarget) {
        precondition(Thread.isMainThread)
        if self.target !== target { stopCapture() }
        self.target = target; refreshCapture()
    }
    func detach(_ target: MousePointerTarget) {
        precondition(Thread.isMainThread)
        guard self.target === target else { return }
        stopCapture(); self.target = nil
    }
    var isCapturing: Bool { captureAllowed && !sessions.isEmpty }
    private var captureAllowed: Bool {
        enabled && UIApplication.shared.applicationState == .active && target?.mouseCaptureAllowed == true
    }
    func refreshCapture() {
        precondition(Thread.isMainThread)
        let mice = GCMouse.mice()
        if connectedCount != mice.count { connectedCount = mice.count }
        guard captureAllowed else { stopCapture(); return }
        let live = Set(mice.map { ObjectIdentifier($0) })
        for id in Array(sessions.keys) where !live.contains(id) {
            if let old = sessions.removeValue(forKey: id) { unbind(old) }
        }
        for mouse in mice where sessions[ObjectIdentifier(mouse)] == nil { bind(mouse) }
    }
    private func accept(_ session: Session) -> Bool {
        guard captureAllowed else { stopCapture(); return false }
        return sessions[ObjectIdentifier(session.mouse)] === session
    }
    private func bind(_ mouse: GCMouse) {
        let profile: GCMouseInput? = mouse.mouseInput
        guard let input = profile else { return }
        mouse.handlerQueue = .main
        let session = Session(mouse, input)
        sessions[ObjectIdentifier(mouse)] = session
        input.mouseMovedHandler = { [weak self, weak session] _, x, y in
            guard let self, let session, self.accept(session), let target = self.target else { return }
            let dx = session.x.consume(Double(x), scale: self.sensitivity)
            let dy = session.y.consume(-Double(y), scale: self.sensitivity)
            if dx != 0 || dy != 0 { target.moveControllerPointer(dx: dx, dy: dy) }
        }
        func button(_ value: GCControllerButtonInput?, _ index: Int) {
            guard let value else { return }
            let source = UUID()
            session.buttons.append((value, source))
            value.pressedChangedHandler = { [weak self, weak session] _, _, pressed in
                guard let self, let session, self.accept(session) else { return }
                GuestInput.shared.state.set(.mouse(index), down: pressed, source: source)
            }
        }
        button(input.leftButton, 0); button(input.rightButton, 1); button(input.middleButton, 2)
        let auxiliary: [GCControllerButtonInput]? = input.auxiliaryButtons
        for (index, value) in (auxiliary ?? []).prefix(2).enumerated() { button(value, index + 3) }
        let scroll: GCControllerDirectionPad? = input.scroll
        scroll?.valueChangedHandler = { [weak self, weak session] _, x, y in
            guard let self, let session, self.accept(session) else { return }
            // Windows WHEEL_DELTA = 120. Preserve fractional wheels rather than
            // forcing every small sample into a complete notch or dropping it.
            let dx = session.wheelX.consume(Double(x), scale: 120)
            let dy = session.wheelY.consume(Double(y), scale: 120)
            if dx != 0 { winios_pointer(0, 0, 0x1000, UInt32(bitPattern: dx)) }
            if dy != 0 { winios_pointer(0, 0, 0x0800, UInt32(bitPattern: dy)) }
        }
    }
    private func unbind(_ session: Session) {
        session.input.mouseMovedHandler = nil
        let scroll: GCControllerDirectionPad? = session.input.scroll
        scroll?.valueChangedHandler = nil
        for (button, source) in session.buttons {
            button.pressedChangedHandler = nil
            GuestInput.shared.state.release(source: source)
        }
    }
    private func stopCapture() {
        let old = Array(sessions.values)
        sessions.removeAll(keepingCapacity: true) // invalidate queued callback generations first
        for session in old { unbind(session) }
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
