import Foundation

/// Measures guest presents, not physical panel scanouts. Caller supplies a
/// monotonic timestamp. Counter resets/wraps and invalid clock values establish
/// a new baseline instead of producing unsigned-underflow FPS spikes.
struct FrameRateSampler {
    private struct Sample { let time: TimeInterval; var count: UInt64 }
    private var samples: [Sample] = []
    private let horizon: TimeInterval = 5
    private let capacity = 128
    var sampleCount: Int { samples.count }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func record(count: UInt64, at time: TimeInterval) -> Double {
        guard time.isFinite, time >= 0 else { reset(); return 0 }
        if let last = samples.last, time < last.time || count < last.count { reset() }
        if samples.last?.time == time {
            samples[samples.count - 1].count = count
        } else {
            samples.append(Sample(time: time, count: count))
        }
        while samples.count > 1 && (samples.count > capacity || samples[0].time < time - horizon) {
            samples.removeFirst()
        }
        guard let latest = samples.last, samples.count >= 2 else { return 0 }
        // Estimate a DURATION from the whole retained window. Stopping at
        // exactly the third counter change selects the shortest lucky window
        // and biases a steady 1 FPS workload upward (e.g. 3/2.25 = 1.33 FPS).
        let fullSpan = latest.time - samples[0].time
        let fullCount = latest.count - samples[0].count
        let target = fullCount > 0
            ? min(horizon, max(1, ceil(3 * fullSpan / Double(fullCount)))) : horizon
        var oldest = samples[0]
        for candidate in samples.dropLast().reversed() {
            oldest = candidate
            if latest.time - candidate.time >= target { break }
        }
        let span = latest.time - oldest.time
        guard span >= 0.0001 else { return 0 }
        let rate = Double(latest.count - oldest.count) / span
        return rate.isFinite ? rate : 0
    }
}
