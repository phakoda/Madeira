import SwiftUI
import QuartzCore

/// Owns the interpreter on the main thread, including its bounded scheduler.
@MainActor
final class Wine32Session: NSObject {
    private var clock: CADisplayLink?
    private var pumping = false
    private var stopRequested = false
    private var completion: ((String?) -> Void)?

    func start(_ plan: LaunchPlan, completion: @escaping (String?) -> Void) throws {
        guard clock == nil else { throw LibraryError.message("A 32-bit session is already running.") }
        guard let rootfs = Bundle.main.url(forResource: "wine11", withExtension: "zip", subdirectory: "Wine32"),
              let graphics = Bundle.main.url(forResource: "madeira-graphics", withExtension: "zip", subdirectory: "Wine32") else {
            throw LibraryError.message("This IPA is missing the Wine32 runtime. Build it with the updated Build Madeira IPA workflow. Your imported files have been kept.")
        }
        try FileManager.default.createDirectory(at: LibraryFiles.wine32Root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: LibraryFiles.drive, withIntermediateDirectories: true)
        let arguments = plan.wine32Arguments(rootfs: rootfs, graphics: graphics,
            root: LibraryFiles.wine32Root, sharedDrive: LibraryFiles.drive,
            resolution: Wine32Resolution(rawValue: UserDefaults.standard.string(forKey: "wine32.resolution") ?? "") ?? .hd)
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { storage.forEach { free($0) } }
        for argument in arguments {
            guard let copy = strdup(argument) else { throw LibraryError.message("Not enough memory to start Windows.") }
            storage.append(copy)
        }
        var argv: [UnsafePointer<CChar>?] = storage.map { UnsafePointer($0) }
        let started = argv.withUnsafeMutableBufferPointer {
            madeira_wine32_start(Int32($0.count), $0.baseAddress)
        }
        guard started != 0 else { throw LibraryError.message(Self.engineError) }
        self.completion = completion
        stopRequested = false
        let clock = CADisplayLink(target: self, selector: #selector(tick))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        self.clock = clock
        clock.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        guard !pumping else { return }
        pumping = true
        let result = madeira_wine32_tick()
        pumping = false
        if result < 0 { finish(error: Self.engineError) }
        else if result == 0 || stopRequested { finish(error: nil) }
    }

    func stop() {
        // SDL can pump UIKit events inside tick(). Finish only after that
        // stack unwinds, so the library cannot start a new session too early.
        if pumping {
            stopRequested = true
            madeira_wine32_stop()
        } else { finish(error: nil) }
    }

    private func finish(error: String?) {
        clock?.invalidate()
        clock = nil
        stopRequested = false
        let stopped = madeira_wine32_stop()
        let callback = completion
        completion = nil
        callback?(error ?? (stopped == 0 ? Self.engineError : nil))
    }

    private static var engineError: String {
        let message = String(cString: madeira_wine32_error())
        return message.isEmpty ? "The 32-bit Windows runtime stopped unexpectedly." : message
    }
}

@MainActor
private final class Wine32HostController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Match the native display's touch handling. SwiftUI's ancestor
        // recognizers can otherwise delay or cancel SDL's raw UIKit touches.
        var ancestor: UIView? = view
        while let current = ancestor {
            current.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            ancestor = current.superview
        }
    }
}

@MainActor
struct Wine32Display: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = Wine32HostController()
        controller.view.backgroundColor = .black
        madeira_wine32_set_view_host(controller)
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        madeira_wine32_set_view_host(controller)
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        madeira_wine32_remove_view_host(controller)
    }
}
