import Foundation

@main struct FrameRateTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, line: Int = #line) {
            checks += 1
            precondition(condition(), "Frame rate check failed at line \(line)")
        }
        var sampler = FrameRateSampler()
        check(sampler.record(count: 100, at: 0) == 0)
        for index in 1...50000 {
            let fps = sampler.record(count: 100 + UInt64(index * 15), at: Double(index) / 4)
            check(abs(fps - 60) < 0.0001)
            check(sampler.sampleCount <= 21)
        }
        sampler.reset()
        for index in 0...80 {
            let t = Double(index) / 4
            let fps = sampler.record(count: UInt64(floor(t * 19)), at: t)
            if index >= 4 { check(abs(fps - 19) < 0.0001) }
        }
        sampler.reset()
        for index in 0...120 {
            let t = Double(index) / 4
            let fps = sampler.record(count: UInt64(t), at: t)
            if index >= 12 { check(fps >= 0.8 && fps <= 1.001) }
        }
        // A stopped guest decays to zero; no stale readings beyond the window.
        for index in 121...145 {
            let fps = sampler.record(count: 30, at: Double(index) / 4)
            if index >= 140 { check(fps == 0) }
        }
        check(sampler.record(count: 0, at: 37) == 0) // counter reset
        check(sampler.record(count: 60, at: 38) == 60)
        check(sampler.record(count: 70, at: 1) == 0) // clock moved backward
        check(sampler.record(count: 190, at: 2) == 120)
        check(sampler.record(count: 191, at: .nan) == 0 && sampler.sampleCount == 0)
        check(sampler.record(count: 191, at: .infinity) == 0)
        check(sampler.record(count: 191, at: -1) == 0)
        check(sampler.record(count: UInt64.max - 1, at: 100) == 0)
        check(sampler.record(count: UInt64.max, at: 101) == 1)
        check(sampler.record(count: 0, at: 102) == 0) // UInt64 rollover
        check(sampler.record(count: 0, at: 200) == 0) // long pause
        check(sampler.record(count: 1, at: 200) == 0) // same-time sample, no divide by zero
        check(sampler.sampleCount == 1)
        check(sampler.record(count: 61, at: 201) == 60)
        sampler.reset()
        for index in 0...10000 {
            let fps = sampler.record(count: UInt64(index), at: Double(index) / 1000)
            check(fps.isFinite && fps >= 0 && sampler.sampleCount <= 128)
        }
        print("Frame-rate sampling: \(checks) checks passed")
    }
}
