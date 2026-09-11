import Foundation
import UIKit
import GameController

// The real pointer target protocol is nested beside unrelated UI/gamepad code;
// its exact declaration is extracted by run-mouse-tests.sh, not redefined here.
final class MouseTarget: MousePointerTarget {
    var controllerCaptureAllowed = true, inside = true
    var mouseCaptureAllowed: Bool { controllerCaptureAllowed && inside }
    var deltas: [(Int32, Int32)] = []
    func moveControllerPointer(dx: Int32, dy: Int32) { deltas.append((dx, dy)) }
}
struct NativeMouseEvent { let flags: UInt32, data: UInt32 }
var nativeEvents: [NativeMouseEvent] = []
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) {
    nativeEvents.append(NativeMouseEvent(flags: flags, data: data))
}
func winios_post_key(_ vk: Int32, _ down: Int32) {}
func winios_release_all_inputs() {}

@main struct MouseTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition() { fatalError("line \(line): \(message)") }
    }
    static func main() {
        check(Thread.isMainThread, "main executor")
        var axis = PointerDeltaAccumulator()
        for _ in 0..<7 { check(axis.consume(0.125) == 0, "fractional carry") }
        check(axis.consume(0.125) == 1, "eighth sample reaches a pixel")
        check(axis.consume(-0.75) == 0 && axis.consume(-0.25) == -1, "negative carry")
        check(axis.consume(.nan) == 0 && axis.remainder == 0, "NaN resets carry")
        check(axis.consume(.infinity) == 0, "infinite delta")
        check(axis.consume(3, scale: .nan) == 0, "invalid gain")
        check(axis.consume(3, scale: 0) == 0, "zero gain")
        check(axis.consume(.greatestFiniteMagnitude, scale: 2) == 0, "overflow cannot trap")
        check(axis.consume(1e20) == Int32.max && axis.remainder == 0, "positive saturation")
        check(axis.consume(-1e20) == Int32.min && axis.remainder == 0, "negative saturation")
        check(axis.consume(0.75) == 0, "carry before reset"); axis.reset()
        check(axis.consume(0.75) == 0, "reset clears subpixels")
        check(PointerMotion.sensitivity(.nan) == 1 && PointerMotion.sensitivity(0) == 0.05, "gain bounds")
        check(PointerMotion.sensitivity(1e30) == 8, "maximum gain")
        axis.reset()
        var exact = 0.0, emitted: Int64 = 0
        for i in 0..<100000 {
            let value = Double((i * 137) % 997 - 498) / 16
            exact += value * 0.125
            emitted += Int64(axis.consume(value, scale: 0.125))
            check(abs(exact - Double(emitted) - axis.remainder) < 1e-8, "motion conserved")
            check(abs(axis.remainder) < 1, "fractional remainder bounded")
        }
        let a = GCMouse(), b = GCMouse()
        GCMouse.devices = [a, b]
        let bridge = PhysicalMouseBridge.shared, target = MouseTarget()
        bridge.attach(target)
        check(bridge.connectedCount == 2 && !bridge.isCapturing, "opt in, no default capture")
        bridge.configure(enabled: true, sensitivity: 1)
        check(bridge.isCapturing, "bind connected mice")
        let first = a.mouseInput!, second = b.mouseInput!
        for _ in 0..<4 { first.move(0.25, 0.5) }
        check(target.deltas.reduce(Int32(0)) { $0 + $1.0 } == 1, "bridge preserves subpixels")
        check(target.deltas.reduce(Int32(0)) { $0 + $1.1 } == -2, "GC Y inverted once")
        nativeEvents.removeAll()
        first.leftButton.send(true); second.leftButton.send(true); first.leftButton.send(false)
        check(nativeEvents.count == 1 && nativeEvents[0].flags == 2, "multiple mouse ownership")
        let saved = second.leftButton.pressedChangedHandler
        target.inside = false; bridge.refreshCapture()
        check(!bridge.isCapturing && nativeEvents.count == 2 && nativeEvents.last!.flags == 4, "leave releases button")
        saved?(second.leftButton, 1, true)
        check(nativeEvents.count == 2, "stale handler cannot press after unbind")
        check(first.mouseMovedHandler == nil && second.scroll.valueChangedHandler == nil, "all handlers cleared")
        target.inside = true; bridge.refreshCapture()
        saved?(second.leftButton, 1, true)
        check(nativeEvents.count == 2, "old generation cannot revive after recapture")
        let finger = UUID()
        GuestInput.shared.state.set(.mouse(0), down: true, source: finger)
        first.leftButton.send(true); bridge.configure(enabled: false, sensitivity: 1)
        check(nativeEvents.last!.flags == 2, "disconnect cannot release a touch owner")
        GuestInput.shared.state.release(source: finger)
        check(nativeEvents.last!.flags == 4, "last source releases")
        bridge.configure(enabled: true, sensitivity: 1)
        nativeEvents.removeAll()
        first.auxiliaryButtons![0].send(true); first.auxiliaryButtons![1].send(true)
        check(nativeEvents.count == 2 && nativeEvents[0].flags == 0x80 && nativeEvents[0].data == 1 &&
              nativeEvents[1].data == 2, "side button payload")
        GCMouse.devices = [b]; bridge.refreshCapture()
        check(nativeEvents.count == 4 && nativeEvents.suffix(2).allSatisfy { $0.flags == 0x100 }, "side release on disconnect")
        nativeEvents.removeAll()
        second.scroll.send(0.5, -0.25)
        check(nativeEvents.count == 2 && nativeEvents[0].flags == 0x1000 && nativeEvents[0].data == 60, "horizontal wheel")
        check(nativeEvents[1].flags == 0x800 && Int32(bitPattern: nativeEvents[1].data) == -30, "signed vertical wheel")
        nativeEvents.removeAll()
        for _ in 0..<32 { second.scroll.send(0, 1.0 / 32) }
        check(nativeEvents.reduce(Int32(0)) { $0 + Int32(bitPattern: $1.data) } == 120, "high resolution wheel preserved")
        second.rightButton!.send(true)
        UIApplication.shared.applicationState = .background
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        check(!bridge.isCapturing && second.mouseMovedHandler == nil, "background unbinds")
        check(nativeEvents.last!.flags == 0x10, "background releases right button")
        UIApplication.shared.applicationState = .active; bridge.refreshCapture()
        let replacement = MouseTarget(); bridge.attach(replacement); bridge.detach(target)
        check(bridge.isCapturing, "old view detach cannot stop new target")
        second.move(3, 4)
        check(replacement.deltas.count == 1 && replacement.deltas[0].0 == 3, "new view receives motion")
        replacement.controllerCaptureAllowed = false; second.leftButton.send(true)
        check(!bridge.isCapturing, "modal prevents new input immediately")
        replacement.controllerCaptureAllowed = true; bridge.refreshCapture()
        bridge.detach(replacement)
        check(!bridge.isCapturing, "detach releases capture")
        GCMouse.devices = []; bridge.refreshCapture()
        check(bridge.connectedCount == 0, "disconnect count")
        print("Physical mouse: \(checks) checks passed (UIKit/GameController boundaries mocked)")
    }
}
