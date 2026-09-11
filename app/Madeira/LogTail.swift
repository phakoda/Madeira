import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A single serial, bounded reader. Polling also works when Wine's writes do
/// not deliver filesystem notifications. No second source owns/closes the fd.
/// Callback and optional stop/skip completions run on the utility queue.
final class LogTail {
    private let path: String
    private let onLine: (String) -> Void
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.madeira.logtail", qos: .utility)
    private var fd: Int32 = -1
    private var identity = stat()
    private var position: off_t = 0
    private var running = false
    private var continuationScheduled = false
    private var timer: DispatchSourceTimer?
    private var framer = LogLineFramer()
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(path: String, pollInterval: TimeInterval = 0.25, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
        interval = pollInterval.isFinite ? max(pollInterval, 0.01) : 0.25
    }
    deinit {
        timer?.cancel()
        if fd >= 0 { close(fd) }
    }
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval,
                           leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            if let self {
                self.running = false
                self.timer?.cancel()
                self.timer = nil
                self.closeFile()
            }
            completion?()
        }
    }
    func skipToEnd(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            if let self {
                if self.fd >= 0 {
                    let end = lseek(self.fd, 0, SEEK_END)
                    if end >= 0 { self.position = end }
                }
                self.framer.reset()
            }
            completion?()
        }
    }
    private func closeFile() {
        if fd >= 0 { close(fd); fd = -1 }
        position = 0
        framer.reset()
    }
    private func poll() {
        guard running else { return }
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            closeFile()
            return // timer retries only while running
        }
        if fd >= 0 && (current.st_dev != identity.st_dev || current.st_ino != identity.st_ino) {
            closeFile()
        }
        if fd < 0 {
            fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return }
            guard fstat(fd, &identity) == 0,
                  identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { closeFile(); return }
            position = 0
        }
        if current.st_size < position {
            guard lseek(fd, 0, SEEK_SET) >= 0 else { closeFile(); return }
            position = 0
            framer.reset()
        }
        // Yield between 256 KiB batches so stop/clear cannot be starved by a
        // continuously growing log. Continue without a 250ms gap for backlogs.
        var readBytes = 0
        while readBytes < 256 * 1024 {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            position += off_t(n)
            readBytes += n
            buffer.withUnsafeBufferPointer {
                framer.append(UnsafeBufferPointer(start: $0.baseAddress, count: n), onLine: onLine)
            }
        }
        if !continuationScheduled {
            continuationScheduled = true
            queue.async { [weak self] in
                guard let self else { return }
                self.continuationScheduled = false
                self.poll()
            }
        }
    }
}
