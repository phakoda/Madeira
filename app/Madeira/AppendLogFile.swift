// O_APPEND keeps Swift writes compatible with Wine/stderr writers. A persistent
// descriptor avoids open/seek/close per line; timestamp formatting is serialized.
// GPL-3.0-or-later.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AppendLogFile: @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1
    private let lock = NSLock()
    private let formatter: DateFormatter
    init(path: String) {
        self.path = path
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
    @discardableResult func append(_ message: String, level: LogRecord.Level) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if descriptor < 0 { descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { return false }
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue)] \(message)\n"
        return Array(line.utf8).withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}
