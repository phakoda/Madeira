import Foundation

@main struct GeometryInputTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
            checks += 1
            precondition(condition(), "line \(line): \(message)")
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
        let wide = DisplayGeometry.aspectFit(CGSize(width: 1920, height: 1080),
                                            in: CGRect(x: 10, y: 20, width: 1000, height: 1000))
        check(near(wide.width, 1000) && near(wide.height, 562.5))
        check(near(wide.midX, 510) && near(wide.midY, 520))
        let traditional = DisplayGeometry.aspectFit(CGSize(width: 1024, height: 768),
                                                   in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        check(near(traditional.width, 1440) && near(traditional.minX, 240))
        let guest = CGSize(width: 1024, height: 768)
        check(DisplayGeometry.guestPoint(CGPoint(x: wide.midX, y: wide.midY), in: wide, guest: guest) == (512, 384))
        check(DisplayGeometry.guestPoint(CGPoint(x: -100, y: -100), in: wide, guest: guest) == (0, 0))
        check(DisplayGeometry.guestPoint(CGPoint(x: 5000, y: 5000), in: wide, guest: guest) == (1023, 767))
        check(DisplayGeometry.guestPoint(.zero, in: .zero, guest: guest) == (0, 0))
        check(DisplayGeometry.guestPoint(CGPoint(x: CGFloat.nan, y: 0), in: wide, guest: guest) == (0, 0))
        for bad in [CGFloat.nan, .infinity, -.infinity, 0, -10, 1e20] {
            check(DisplayGeometry.validSize(CGSize(width: bad, height: 1080)) == guest)
        }
        check(DisplayGeometry.aspectFit(guest, in: .zero) == .zero)
        check(DisplayGeometry.sensitivity(.nan) == 2)
        check(DisplayGeometry.sensitivity(.infinity) == 2)
        check(DisplayGeometry.sensitivity(-1) == 0.05)
        check(DisplayGeometry.sensitivity(300) == 20)

        typealias Control = GuestInputState.Control
        var events: [(Control, Bool)] = []
        let input = GuestInputState { events.append(($0, $1)) }
        let a = UUID(), b = UUID(), c = UUID()
        input.set(.key(87), down: true, source: a)
        input.set(.key(87), down: true, source: a) // repeated gesture updates
        input.set(.key(87), down: true, source: b) // a second control holds W
        input.release(source: a)
        check(events.count == 1 && events[0].1)
        input.release(source: c) // cancelling an unrelated control must do nothing
        check(events.count == 1)
        input.release(source: b)
        check(events.count == 2 && !events[1].1)
        input.set(.mouse(0), down: true, source: a)
        input.set(.mouse(0), down: true, source: b)
        input.release(source: b)
        check(events.count == 3)
        input.set(.key(16), down: true, source: a)
        input.set(.key(16), down: true, source: b)
        input.releaseAll()
        check(events.filter { !$0.1 }.count == 3)
        let count = events.count
        input.releaseAll(); input.release(source: a)
        check(events.count == count)
        input.set(.key(-1), down: true, source: a)
        input.set(.key(256), down: true, source: a)
        input.set(.mouse(5), down: true, source: a)
        check(events.count == count)
        // Thousands of overlapping ownership transitions, checked against a model.
        var model: Set<UUID> = []
        let sources = (0..<20).map { _ in UUID() }
        for n in 0..<10000 {
            let source = sources[(n * 7) % sources.count]
            let down = n % 3 != 0
            let old = !model.isEmpty
            if down { model.insert(source) } else { model.remove(source) }
            let previous = events.count
            input.set(.key(65), down: down, source: source)
            check(events.count == previous + (old != !model.isEmpty ? 1 : 0))
        }
        input.releaseAll()
        print("Geometry/input ownership: \(checks) checks passed")
    }
}
