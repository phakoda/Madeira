// Optional GameController -> keyboard/mouse preset, not a guest XInput device.
// Uses public APIs. All mutable state and callbacks are confined to the main thread.
// GPL-3.0-or-later.
import UIKit
import GameController
import Combine
import QuartzCore

protocol ControllerPointerTarget: AnyObject {
    var controllerCaptureAllowed: Bool { get }
    func moveControllerPointer(dx: Int32, dy: Int32)
}

final class PhysicalControllerBridge: NSObject, ObservableObject {
    static let shared = PhysicalControllerBridge()
    @Published private(set) var connectedCount = 0

    private final class Session {
        let controller: GCController
        let stickSource = UUID()
        var buttons: [(GCControllerButtonInput, UUID)] = []
        var digital = DigitalStickState()
        var keys: Set<Int32> = []
        var lookX: Double = 0, lookY: Double = 0
        var motion = StickMotionIntegrator()
        init(_ controller: GCController) { self.controller = controller }
    }

    private weak var target: ControllerPointerTarget?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var enabled = false
    private var lookSpeed = 800.0, deadZone = 0.12
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshCapture()
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.stopCapture()
        })
        connectedCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
    }

    func configure(enabled: Bool, speed: Double, deadZone: Double) {
        precondition(Thread.isMainThread)
        let speed = ControllerMath.speed(speed), zone = ControllerMath.deadZone(deadZone)
        if self.enabled != enabled || self.deadZone != zone {
            // Re-press controls after changing the preset/dead zone. Do not
            // synthesize old held buttons into a newly focused guest.
            stopCapture()
        }
        self.enabled = enabled
        self.lookSpeed = speed
        self.deadZone = zone
        refreshCapture()
    }

    func attach(_ target: ControllerPointerTarget) {
        precondition(Thread.isMainThread)
        if self.target !== target { stopCapture() }
        self.target = target
        refreshCapture()
    }

    func detach(_ target: ControllerPointerTarget) {
        precondition(Thread.isMainThread)
        // Rotation may detach the old placeholder AFTER attaching the new one.
        guard self.target === target else { return }
        stopCapture()
        self.target = nil
    }

    /// Also called by the active display's existing 4 Hz lifecycle check, so
    /// opening a host modal stops capture even without an application transition.
    func refreshCapture() {
        precondition(Thread.isMainThread)
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        if connectedCount != controllers.count { connectedCount = controllers.count }
        guard captureAllowed else { stopCapture(); return }
        let live = Set(controllers.map { ObjectIdentifier($0) })
        for id in Array(sessions.keys) where !live.contains(id) {
            if let session = sessions.removeValue(forKey: id) { unbind(session) }
        }
        for controller in controllers where sessions[ObjectIdentifier(controller)] == nil {
            bind(controller)
        }
        updateMotionTimer()
    }

    private var captureAllowed: Bool {
        enabled && UIApplication.shared.applicationState == .active &&
            target?.controllerCaptureAllowed == true
    }

    private func accept(_ session: Session) -> Bool {
        guard captureAllowed else { stopCapture(); return false }
        // An event queued by an old binding cannot revive it after disable,
        // disconnect, focus change, or rotation (identity acts as its generation).
        return sessions[ObjectIdentifier(session.controller)] === session
    }

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        let session = Session(controller)
        sessions[ObjectIdentifier(controller)] = session
        func button(_ button: GCControllerButtonInput?, _ control: GuestInputState.Control) {
            guard let button else { return }
            let source = UUID()
            session.buttons.append((button, source))
            button.pressedChangedHandler = { [weak self, weak session] _, _, pressed in
                guard let self, let session, self.accept(session) else { return }
                GuestInput.shared.state.set(control, down: pressed, source: source)
            }
        }
        button(pad.buttonA, .key(0x20)) // bottom face: Space
        button(pad.buttonB, .key(0x11)) // right face: Ctrl
        button(pad.buttonX, .key(0x45)) // left face: E
        button(pad.buttonY, .key(0x52)) // top face: R
        button(pad.leftTrigger, .mouse(1))
        button(pad.rightTrigger, .mouse(0))
        button(pad.leftShoulder, .key(0x51))
        button(pad.rightShoulder, .key(0x46))
        button(pad.dpad.up, .key(0x26))
        button(pad.dpad.down, .key(0x28))
        button(pad.dpad.left, .key(0x25))
        button(pad.dpad.right, .key(0x27))
        button(pad.buttonMenu, .key(0x1B))
        button(pad.buttonOptions, .key(0x09))
        button(pad.leftThumbstickButton, .key(0x10))
        button(pad.rightThumbstickButton, .key(0x43))
        // The system Home/Guide button is intentionally not intercepted.
        pad.leftThumbstick.valueChangedHandler = { [weak self, weak session] _, x, y in
            guard let self, let session, self.accept(session) else { return }
            let vector = ControllerMath.radial(x: Double(x), y: Double(y), deadZone: self.deadZone)
            let keys = session.digital.update(x: vector.x, y: vector.y)
            for key in session.keys.union(keys) {
                GuestInput.shared.state.set(.key(key), down: keys.contains(key), source: session.stickSource)
            }
            session.keys = keys
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self, weak session] _, x, y in
            guard let self, let session, self.accept(session) else { return }
            session.lookX = Double(x); session.lookY = Double(y)
            if !self.isMoving(session) { session.motion.reset() }
            self.updateMotionTimer()
        }
    }

    private func isMoving(_ session: Session) -> Bool {
        let vector = ControllerMath.radial(x: session.lookX, y: session.lookY, deadZone: deadZone)
        return vector.x != 0 || vector.y != 0
    }

    private func updateMotionTimer() {
        if !sessions.values.contains(where: isMoving) {
            displayLink?.invalidate(); displayLink = nil
        } else if displayLink == nil {
            // A tilted, stationary stick does not keep sending valueChanged.
            // Integrate its velocity against time, not event count or assumed Hz.
            let link = CADisplayLink(target: self, selector: #selector(movePointers))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func movePointers() {
        guard captureAllowed, let target else { stopCapture(); return }
        let time = CACurrentMediaTime()
        for session in sessions.values {
            let delta = session.motion.step(x: session.lookX, y: session.lookY, at: time,
                                            speed: lookSpeed, deadZone: deadZone)
            if delta.x != 0 || delta.y != 0 { target.moveControllerPointer(dx: delta.x, dy: delta.y) }
        }
    }

    private func unbind(_ session: Session) {
        for (button, source) in session.buttons {
            button.pressedChangedHandler = nil
            GuestInput.shared.state.release(source: source)
        }
        session.controller.extendedGamepad?.leftThumbstick.valueChangedHandler = nil
        session.controller.extendedGamepad?.rightThumbstick.valueChangedHandler = nil
        GuestInput.shared.state.release(source: session.stickSource)
        session.motion.reset()
    }

    private func stopCapture() {
        let old = Array(sessions.values)
        sessions.removeAll(keepingCapacity: true) // invalidate callbacks before releasing
        displayLink?.invalidate(); displayLink = nil
        for session in old { unbind(session) }
    }

    deinit {
        displayLink?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
