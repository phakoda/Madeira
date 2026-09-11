import Foundation

/// Platform-independent controller policy, shared by device handlers and tests.
enum ControllerMath {
    static func speed(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 50), 4000) : 800
    }
    static func deadZone(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 0.8) : 0.12
    }
    static func radial(x: Double, y: Double, deadZone: Double) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let x = min(max(x, -1), 1), y = min(max(y, -1), 1)
        let magnitude = hypot(x, y)
        let zone = Self.deadZone(deadZone)
        guard magnitude > zone else { return (0, 0) }
        let gain = (min(magnitude, 1) - zone) / (1 - zone) / magnitude
        return (x * gain, y * gain)
    }
}

/// Axis hysteresis prevents W/A/S/D chattering at a noisy stick boundary.
struct DigitalStickState {
    private var horizontal = 0, vertical = 0
    private static func direction(_ value: Double, previous: Int) -> Int {
        guard value.isFinite else { return 0 }
        if value >= 0.35 { return 1 }
        if value <= -0.35 { return -1 }
        if previous == 1 && value > 0.25 { return 1 }
        if previous == -1 && value < -0.25 { return -1 }
        return 0
    }
    mutating func update(x: Double, y: Double) -> Set<Int32> {
        horizontal = Self.direction(x, previous: horizontal)
        vertical = Self.direction(y, previous: vertical)
        var keys: Set<Int32> = []
        if horizontal < 0 { keys.insert(0x41) } // A
        if horizontal > 0 { keys.insert(0x44) } // D
        if vertical > 0 { keys.insert(0x57) }   // W; GameController Y is up
        if vertical < 0 { keys.insert(0x53) }   // S
        return keys
    }
    mutating func reset() { horizontal = 0; vertical = 0 }
}

/// Integrates stick velocity against monotonic time, NOT callback frequency.
/// Carry subpixel motion and cap catch-up after scheduling stalls at 50 ms.
struct StickMotionIntegrator {
    private var previousTime: TimeInterval?
    private var carryX: Double = 0, carryY: Double = 0
    mutating func reset() { previousTime = nil; carryX = 0; carryY = 0 }
    mutating func step(x: Double, y: Double, at time: TimeInterval,
                       speed: Double, deadZone: Double) -> (x: Int32, y: Int32) {
        guard time.isFinite, time >= 0, x.isFinite, y.isFinite else { reset(); return (0, 0) }
        defer { previousTime = time }
        guard let previousTime, time >= previousTime else { carryX = 0; carryY = 0; return (0, 0) }
        let vector = ControllerMath.radial(x: x, y: y, deadZone: deadZone)
        guard vector.x != 0 || vector.y != 0 else { carryX = 0; carryY = 0; return (0, 0) }
        let dt = min(time - previousTime, 0.05)
        let gain = ControllerMath.speed(speed) * dt
        carryX += vector.x * gain
        carryY -= vector.y * gain // guest Y is down
        let dx = Int32(carryX.rounded(.towardZero)), dy = Int32(carryY.rounded(.towardZero))
        carryX -= Double(dx); carryY -= Double(dy)
        return (dx, dy)
    }
}
