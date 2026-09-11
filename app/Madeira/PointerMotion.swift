// Lossless subpixel accumulation for physical pointer and high-resolution wheel
// deltas. No UIKit dependency: the production arithmetic is portable-tested.
// GPL-3.0-or-later.
import Foundation

struct PointerDeltaAccumulator {
    private(set) var remainder = 0.0

    mutating func consume(_ delta: Double, scale: Double = 1) -> Int32 {
        guard delta.isFinite, scale.isFinite, scale > 0 else { reset(); return 0 }
        let value = delta * scale + remainder
        guard value.isFinite else { reset(); return 0 }
        // Saturate before integer conversion, and discard excess rather than
        // storing an enormous carry that could move the cursor for minutes.
        let bounded = max(Double(Int32.min), min(Double(Int32.max), value))
        let whole = bounded.rounded(.towardZero)
        remainder = bounded == value ? value - whole : 0
        return Int32(whole)
    }
    mutating func reset() { remainder = 0 }
}

enum PointerMotion {
    static func sensitivity(_ value: Double) -> Double {
        value.isFinite ? max(0.05, min(8, value)) : 1
    }
}
