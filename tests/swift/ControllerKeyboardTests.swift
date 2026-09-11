import Foundation

@main struct ControllerKeyboardTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                      line: UInt = #line) {
        checks += 1
        if !condition() { fatalError("line \(line): \(message)") }
    }
    static func main() {
        check(ControllerMath.speed(.nan) == 800, "invalid speed fallback")
        check(ControllerMath.speed(-3) == 50, "minimum speed")
        check(ControllerMath.speed(.infinity) == 800, "infinite speed")
        check(ControllerMath.speed(1e200) == 4000, "maximum speed")
        check(ControllerMath.deadZone(.nan) == 0.12, "invalid dead zone")
        check(ControllerMath.deadZone(1) == 0.8, "dead zone cannot divide by zero")
        check(ControllerMath.deadZone(-1) == 0, "negative dead zone")
        for xi in -120...120 {
            for yi in -120...120 {
                let v = ControllerMath.radial(x: Double(xi) / 100, y: Double(yi) / 100, deadZone: 0.12)
                check(v.x.isFinite && v.y.isFinite, "radial response finite")
                check(hypot(v.x, v.y) <= 1.0000000001, "diagonal cannot accelerate")
            }
        }
        let diagonal = ControllerMath.radial(x: 1, y: 1, deadZone: 0.12)
        check(abs(hypot(diagonal.x, diagonal.y) - 1) < 1e-12, "diagonal normalized")
        let invalid = ControllerMath.radial(x: .nan, y: 1, deadZone: 0)
        check(invalid.x == 0 && invalid.y == 0, "invalid stick neutral")
        var previous = 0.0
        for i in 0...1000 {
            let value = Double(i) / 1000
            let v = ControllerMath.radial(x: value, y: 0, deadZone: 0.12)
            check(v.x >= previous, "monotonic axis response")
            if value <= 0.12 { check(v.x == 0 && v.y == 0, "dead zone neutral") }
            previous = v.x
        }
        var digital = DigitalStickState()
        check(digital.update(x: 0, y: 0).isEmpty, "initial neutral")
        check(digital.update(x: 0.34, y: 0.34).isEmpty, "below engage threshold")
        check(digital.update(x: 0.35, y: 0.35) == [0x44, 0x57], "diagonal W+D")
        for value in [0.34, 0.26, 0.33, 0.28] {
            check(digital.update(x: value, y: value) == [0x44, 0x57], "hysteresis holds")
        }
        check(digital.update(x: 0.25, y: 0.25).isEmpty, "release threshold")
        check(digital.update(x: -1, y: -1) == [0x41, 0x53], "A+S")
        check(digital.update(x: 1, y: 1) == [0x44, 0x57], "fast reversal")
        check(digital.update(x: .nan, y: .infinity).isEmpty, "invalid digital neutral")
        _ = digital.update(x: 1, y: 1)
        digital.reset()
        check(digital.update(x: 0.3, y: 0.3).isEmpty, "reset clears hysteresis")

        for hz in [30, 60, 120, 240] {
            var motion = StickMotionIntegrator()
            let start = motion.step(x: 1, y: 0, at: 0, speed: 800, deadZone: 0.12)
            check(start.x == 0 && start.y == 0, "first sample has no elapsed time")
            var total = 0
            for frame in 1...(hz * 10) {
                let d = motion.step(x: 1, y: 0, at: Double(frame) / Double(hz), speed: 800, deadZone: 0.12)
                total += Int(d.x)
                check(d.y == 0, "horizontal motion")
            }
            check(abs(total - 8000) <= 1, "time-based speed independent of refresh rate")
        }
        var motion = StickMotionIntegrator()
        _ = motion.step(x: 1, y: 1, at: 1, speed: 4000, deadZone: 0)
        let stalled = motion.step(x: 1, y: 1, at: 100, speed: 4000, deadZone: 0)
        check(hypot(Double(stalled.x), Double(stalled.y)) <= 200, "50 ms catch-up bound")
        check(stalled.y < 0, "positive GC Y becomes negative desktop Y")
        let backwards = motion.step(x: 1, y: 0, at: 0, speed: 4000, deadZone: 0)
        check(backwards.x == 0 && backwards.y == 0, "backward clock reset")
        let badTime = motion.step(x: 1, y: 1, at: .nan, speed: 800, deadZone: 0)
        check(badTime.x == 0 && badTime.y == 0, "invalid clock reset")
        let afterBad = motion.step(x: 1, y: 1, at: 2, speed: 800, deadZone: 0)
        check(afterBad.x == 0 && afterBad.y == 0, "no catch-up after invalid clock")
        motion.reset()
        _ = motion.step(x: 1, y: 0, at: 0, speed: 50, deadZone: 0)
        check(motion.step(x: 1, y: 0, at: 0.01, speed: 50, deadZone: 0).x == 0, "subpixel carry")
        check(motion.step(x: 1, y: 0, at: 0.02, speed: 50, deadZone: 0).x == 1, "carry reaches pixel")
        _ = motion.step(x: 1, y: 0, at: 0.03, speed: 50, deadZone: 0)
        _ = motion.step(x: 0, y: 0, at: 0.04, speed: 50, deadZone: 0)
        check(motion.step(x: 1, y: 0, at: 0.05, speed: 50, deadZone: 0).x == 0, "idle clears old fractional drift")

        for i in 0..<26 { check(HIDKeyMap.virtualKey(for: 4+i) == Int32(0x41+i), "letter map") }
        for i in 0..<9 { check(HIDKeyMap.virtualKey(for: 0x1e+i) == Int32(0x31+i), "digit map") }
        for i in 0..<24 {
            let usage = i < 12 ? 0x3a+i : 0x68+i-12
            check(HIDKeyMap.virtualKey(for: usage) == Int32(0x70+i), "function key map")
        }
        for i in 0..<9 { check(HIDKeyMap.virtualKey(for: 0x59+i) == Int32(0x61+i), "keypad map") }
        check(HIDKeyMap.virtualKey(for: 0x27) == 0x30, "zero")
        check(HIDKeyMap.virtualKey(for: 0x52) == 0x26, "up arrow")
        check(HIDKeyMap.virtualKey(for: 0x64) == 0xE2, "ISO extra key")
        for usage in [Int.min, -1, 0, 1, 2, 3, 0xffff, Int.max] {
            check(HIDKeyMap.virtualKey(for: usage) == nil, "unmapped usage")
            check(!HIDKeyMap.isRepeatable(usage), "unmapped not repeatable")
        }
        var events: [(GuestInputState.Control, Bool)] = []
        let input = GuestInputState { events.append(($0, $1)) }
        let keyboard = HardwareKeyboardState(input: input)
        check(keyboard.press(usage: 4), "A handled")
        check(events.count == 1 && events[0].0 == .key(0x41) && events[0].1, "A down")
        check(keyboard.heldKeyCount == 1, "held count")
        keyboard.press(usage: 4)
        check(events.count == 2 && events.last!.1, "repeat is keydown without new owner")
        keyboard.release(usage: 4)
        check(events.count == 3 && !events.last!.1 && keyboard.heldKeyCount == 0, "one up ends repeats")
        keyboard.release(usage: 4)
        check(events.count == 3, "duplicate up ignored")
        events.removeAll()
        keyboard.press(usage: 0xE0); keyboard.press(usage: 0xE4)
        check(events.count == 1 && events[0].0 == .key(0x11), "both Ctrl sides share down")
        keyboard.press(usage: 0xE0)
        check(events.count == 1, "modifier repeat suppressed")
        keyboard.release(usage: 0xE0)
        check(events.count == 1, "other Ctrl still held")
        keyboard.release(usage: 0xE4)
        check(events.count == 2 && !events[1].1, "last Ctrl release")
        let touch = UUID()
        events.removeAll()
        input.set(.key(0x41), down: true, source: touch)
        keyboard.press(usage: 4); keyboard.release(usage: 4)
        check(events.count == 1, "keyboard release cannot release touch A")
        input.release(source: touch)
        check(events.count == 2 && !events.last!.1, "touch owns last release")
        events.removeAll()
        for usage in [4, 5, 6, 0xE1] { keyboard.press(usage: usage) }
        keyboard.releaseAll()
        check(events.count == 8 && keyboard.heldKeyCount == 0, "disconnect releases all keys")
        check(events.suffix(4).allSatisfy { !$0.1 }, "disconnect only ups")
        events.removeAll()
        keyboard.press(usage: 4)
        input.releaseAll()
        keyboard.press(usage: 4)
        check(events.count == 2 && !events.last!.1, "queued repeat cannot resurrect globally cancelled input")
        keyboard.releaseAll()
        check(!keyboard.press(usage: 0xFFFF), "unsupported UIKit fallback")
        check(!keyboard.release(usage: 0xFFFF), "unsupported UIKit release fallback")
        check(keyboard.heldKeyCount == 0, "unknown does not own a key")
        // A delayed toolbar release must not release a newly pressed source.
        events.removeAll()
        let oldTap = UUID(), newTap = UUID()
        input.set(.key(0x20), down: true, source: oldTap)
        input.releaseAll()
        input.set(.key(0x20), down: true, source: newTap)
        input.release(source: oldTap)
        check(events.count == 3 && events.last!.1, "old timer cannot release new press")
        input.release(source: newTap)
        check(events.count == 4 && !events.last!.1, "new owner releases")
        print("Controller/keyboard: \(checks) checks passed")
    }
}
