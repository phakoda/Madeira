import Foundation
import SwiftUI

final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// One row per unique signature — semantically identical events bucket here.
    @Published var entries: [LogEntry] = []

    private let logFileURL: URL
    private let fileWriter: AppendLogFile
    private let pending = LogAccumulator()
    private var tail: LogTail?
    private var flushTimer: Timer?

    /// When true, UI flushes slowly (1.5s) instead of normally (200ms). Used
    /// during Wine runtime so SwiftUI list churn doesn't drag frame pacing.
    /// Tail reader keeps running either way — pending entries just batch up
    /// longer before reaching @Published. Setting this restarts the timer.
    var uiPaused = false {
        didSet { if oldValue != uiPaused { rescheduleFlush() } }
    }

    // Flush intervals (seconds)
    private let fastFlushInterval: TimeInterval = 0.2
    private let slowFlushInterval: TimeInterval = 1.5

    // Cap on distinct entries kept in memory
    private let maxEntries = 200

    typealias LogEntry = LogRecord

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("madeira-log.txt")
        fileWriter = AppendLogFile(path: logFileURL.path)

        // ml601: ROTATE, don't destroy.
        //
        // This used to truncate unconditionally, so relaunching the app before
        // pulling wiped the previous run. That cost us the first run in which
        // Steam's Library view actually rendered content (2026-08-09) — a result
        // we had never seen before and could not get back. Runs here are
        // expensive and often not reproducible on demand, so the previous log is
        // worth one file's worth of disk.
        //
        // Pull the previous run with the usual devicectl command, substituting
        // Documents/madeira-log.prev.txt for Documents/madeira-log.txt.
        let prevLogURL = docs.appendingPathComponent("madeira-log.prev.txt")
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.removeItem(at: prevLogURL)
            try? FileManager.default.moveItem(at: logFileURL, to: prevLogURL)
        }
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)

        // Start batch flush timer on main thread. Interval depends on uiPaused.
        DispatchQueue.main.async {
            self.rescheduleFlush()
        }

        // Tail the log file. Reads everything Wine + DXMT + FEX write via
        // dprintf(STDERR_FILENO, ...), wine_log_write, etc.
        tail = LogTail(path: logFileURL.path) { [weak self] line in
            self?.handleRawLine(line)
        }
        tail?.start()

        // Wine's native loggers already write this file. Ingesting their UI
        // callback AND tailing the same bytes double-counts events and allocates
        // Swift objects on exception paths. Use the file as the single feed.
        wine_set_ui_log_callback(nil)
        jit_set_log_callback { cStr in
            guard let cStr else { return }
            LogStore.shared.log("[JIT] " + String(cString: cStr))
        }
    }

    /// Thread-safe producer entry point. The tail is the sole UI ingestion path
    /// after successful persistence; failed writes still produce a visible row.
    func log(_ message: String, level: LogEntry.Level = .info) {
        if !fileWriter.append(message, level: level) {
            handleRawLine("[\(level.rawValue)] " + message)
        }
    }

    private func handleRawLine(_ raw: String) {
        guard !shouldDropLine(raw) else { return }
        let (signature, level) = LogPattern.canonicalize(raw)
        pending.append(signature: signature, raw: raw, level: level)
    }

    /// Filter rules for raw lines. Anything that returns true is dropped
    /// before signature canonicalization.
    private func shouldDropLine(_ raw: String) -> Bool {
        // Drop Wine's `trace:file:WriteFile` / `NtWriteFile` / `SysCall` chatter
        // — these are amplified by our own logging path (every dprintf is
        // dup2'd to the log fd, which then goes through Wine's file trace).
        // The signal lives in the original log lines, not these wrappers.
        if raw.contains("trace:file:WriteFile") { return true }
        if raw.contains("trace:file:NtWriteFile") { return true }
        if raw.contains("SysCall  NtWriteFile") { return true }
        if raw.contains("SysCall  NtQueryPerformanceCounter") { return true }
        if raw.contains("SysRet   NtWriteFile") { return true }
        if raw.contains("SysRet   NtQueryPerformanceCounter") { return true }
        // Drop verbose IR dispatch (already silenced in FEX, but defensive)
        if raw.contains("[iOS] Arm64JIT: Dispatching Op") { return true }
        if raw.contains("[iOS] Decoder:") { return true }
        return false
    }

    /// Reschedule flush timer with the appropriate interval for the current
    /// uiPaused state. Always runs on main RunLoop.
    private func rescheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushTimer?.invalidate()
            let interval = self.uiPaused ? self.slowFlushInterval : self.fastFlushInterval
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.flushPending()
            }
        }
    }

    /// Publish once per batch, outside the producer lock.
    private func flushPending() {
        var batch = pending.drain()
        if batch.evictedLines > 0 {
            let now = Date()
            batch.records.append(LogEntry(firstTimestamp: now, lastTimestamp: now,
                signature: "[log] UI backlog summarized; complete output remains in the log file",
                lastRaw: "\(batch.evictedLines) lines evicted from the bounded UI pending buffer",
                count: batch.evictedLines, level: .info))
        }
        guard !batch.records.isEmpty else { return }
        entries = LogAccumulator.merge(batch.records, into: entries, capacity: maxEntries)
    }

    /// Clear the console, not the underlying inode. Atomic file replacement
    /// strands stderr/Wine's open descriptors and makes subsequent logs vanish.
    func clear() {
        tail?.skipToEnd { [weak self] in
            guard let self else { return }
            self.pending.clear()
            DispatchQueue.main.async { [weak self] in self?.entries.removeAll() }
        }
    }
}
