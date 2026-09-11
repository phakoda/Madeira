// Source-owned input: two controls holding W must not release each other's W.
// Call on the UI executor. The native queue separately serializes Wine delivery.
// GPL-3.0-or-later.
import Foundation

final class GuestInputState {
    enum Control: Hashable {
        case key(Int32)
        case mouse(Int) // 0 = left, 1 = right, 2 = middle
        var valid: Bool {
            switch self {
            case .key(let vk): return (1...255).contains(vk)
            case .mouse(let button): return (0...2).contains(button)
            }
        }
    }
    private var owners: [Control: Set<UUID>] = [:]
    private let send: (Control, Bool) -> Void
    init(send: @escaping (Control, Bool) -> Void) { self.send = send }

    func set(_ control: Control, down: Bool, source: UUID) {
        guard control.valid else { return }
        let wasDown = !(owners[control]?.isEmpty ?? true)
        if down {
            owners[control, default: []].insert(source)
        } else {
            owners[control]?.remove(source)
            if owners[control]?.isEmpty == true { owners.removeValue(forKey: control) }
        }
        let isDown = !(owners[control]?.isEmpty ?? true)
        if wasDown != isDown { send(control, isDown) }
    }

    func release(source: UUID) {
        // Copy keys before mutating the dictionary; callbacks never observe a
        // partially removed owner set for the same control.
        for control in Array(owners.keys) { set(control, down: false, source: source) }
    }

    func releaseAll() {
        let controls = Array(owners.keys)
        owners.removeAll(keepingCapacity: true)
        for control in controls { send(control, false) }
    }
}

#if canImport(UIKit)
import UIKit

final class GuestInput {
    static let shared = GuestInput()
    let state: GuestInputState
    private var observer: NSObjectProtocol?

    private init() {
        state = GuestInputState { control, down in
            switch control {
            case .key(let vk): winios_post_key(vk, down ? 1 : 0)
            case .mouse(let button):
                let flags: [(UInt32, UInt32)] = [(0x2, 0x4), (0x8, 0x10), (0x20, 0x40)]
                winios_pointer(0, 0, down ? flags[button].0 : flags[button].1, 0)
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAll() }
    }
    func releaseAll() {
        state.releaseAll()
        // Also release legacy/native sources and discard stale pending presses.
        winios_release_all_inputs()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
#endif
