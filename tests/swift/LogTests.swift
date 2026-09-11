import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CapturedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@main struct LogTests {
    static func main() throws {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, line: Int = #line) {
            checks += 1
            precondition(ok(), "Log test failed at line \(line)")
        }
        func wait(_ predicate: () -> Bool, line: Int = #line) {
            let deadline = Date().addingTimeInterval(4)
            while !predicate() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            check(predicate(), line: line)
        }
        var framer = LogLineFramer(limit: 32)
        var lines: [String] = []
        for byte in Array("hello\r\n🙂 UTF-8\nlast".utf8) {
            [byte].withUnsafeBufferPointer { framer.append($0) { lines.append($0) } }
        }
        check(lines == ["hello", "🙂 UTF-8"])
        Array(" half\n".utf8).withUnsafeBufferPointer { framer.append($0) { lines.append($0) } }
        check(lines.last == "last half")
        [UInt8(0xff), 10].withUnsafeBufferPointer { framer.append($0) { lines.append($0) } }
        check(lines.last == "�")
        Array((String(repeating: "x", count: 10000) + "\nnext\n").utf8).withUnsafeBufferPointer {
            framer.append($0) { lines.append($0) }
        }
        check(lines[lines.count - 2] == String(repeating: "x", count: 32) + " [line truncated]")
        check(lines.last == "next")
        Array("unclosed".utf8).withUnsafeBufferPointer { framer.append($0) { lines.append($0) } }
        framer.reset()
        Array("fresh\n".utf8).withUnsafeBufferPointer { framer.append($0) { lines.append($0) } }
        check(lines.last == "fresh")
        let pattern = LogPattern.canonicalize("[12:34:56.789] [ERR] failed 0x1234 count 1000")
        check(pattern.level == .error && pattern.signature == "failed 0x? count #")
        check(LogPattern.canonicalize("[OK] ready").level == .success)
        check(LogPattern.canonicalize("[DBG] success counter").level == .debug)
        check(LogPattern.canonicalize("[ERR] success not achieved").level == .error)
        check(LogPattern.canonicalize("0024:trace:file:open 0xabc #123").signature == "T:trace:file:open 0x? #_")
        let pending = LogAccumulator(capacity: 16)
        DispatchQueue.concurrentPerform(iterations: 32) { worker in
            for index in 0..<2000 {
                pending.append(signature: "worker \(worker % 8)", raw: "\(index)", level: .debug)
            }
        }
        let batch = pending.drain()
        check(batch.evictedLines == 0 && batch.records.count == 8)
        check(batch.records.reduce(0) { $0 + $1.count } == 64000)
        for entry in batch.records { check(entry.count == 8000) }
        check(pending.drain().records.isEmpty)
        var rows = LogAccumulator.merge(batch.records, into: [], capacity: 8)
        let ids = Dictionary(uniqueKeysWithValues: rows.map { ($0.signature, $0.id) })
        // Reordering and eviction never misapply a producer's captured index.
        for entry in rows.reversed() { pending.append(signature: entry.signature, raw: "latest", level: .error) }
        rows.reverse()
        rows = LogAccumulator.merge(pending.drain().records, into: rows, capacity: 8)
        for row in rows {
            check(row.count == 8001 && row.lastRaw == "latest" && row.level == .error)
            check(row.id == ids[row.signature])
        }
        for n in 0..<1000 { pending.append(signature: "unique \(n)", raw: "raw", level: .info) }
        let pressure = pending.drain()
        check(pressure.records.count == 16 && pressure.evictedLines == 984)
        check(pressure.records.first?.signature == "unique 984")
        check(LogAccumulator.merge(pressure.records, into: rows, capacity: 5).count == 5)
        pending.append(signature: "old", raw: "x", level: .info); pending.clear()
        check(pending.drain().records.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("log.txt").path
        let writer = AppendLogFile(path: path)
        DispatchQueue.concurrentPerform(iterations: 1000) { n in
            precondition(writer.append("line-\(n)", level: .info))
        }
        let disk = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        check(disk.count == 1000)
        let messages = Set(disk.map { String($0.split(separator: " ").last!) })
        for n in 0..<1000 { check(messages.contains("line-\(n)")) }
        let capture = CapturedLines()
        let tail = LogTail(path: path, pollInterval: 0.01) { capture.append($0) }
        tail.start(); tail.start()
        wait { capture.snapshot.count == 1000 }
        check(writer.append("after-start", level: .success))
        wait { capture.snapshot.contains { $0.contains("after-start") } }
        check(capture.snapshot.count == 1001)
        // Replace the inode. The tail must follow the new path, not an old fd.
        try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
        try "replacement has a longer line\n".write(toFile: path, atomically: false, encoding: .utf8)
        wait { capture.snapshot.last == "replacement has a longer line" }
        // Truncation with the same inode.
        let truncateFD = open(path, O_WRONLY | O_TRUNC)
        check(truncateFD >= 0)
        let short = Array("reset\n".utf8)
        check(short.withUnsafeBytes { write(truncateFD, $0.baseAddress, $0.count) } == short.count)
        close(truncateFD)
        wait { capture.snapshot.last == "reset" }
        let skipped = DispatchSemaphore(value: 0)
        tail.skipToEnd { skipped.signal() }
        check(skipped.wait(timeout: .now() + 2) == .success)
        let stopped = DispatchSemaphore(value: 0)
        tail.stop { stopped.signal() }
        check(stopped.wait(timeout: .now() + 2) == .success)
        let before = capture.snapshot.count
        let unrelated = open(path, O_RDONLY)
        check(unrelated >= 0)
        Thread.sleep(forTimeInterval: 0.05)
        check(fcntl(unrelated, F_GETFD) >= 0) // cancellation must not close a reused fd
        close(unrelated)
        check(capture.snapshot.count == before)
        tail.start()
        wait { capture.snapshot.count == before + 1 }
        tail.stop { stopped.signal() }
        check(stopped.wait(timeout: .now() + 2) == .success)
        // A failed initial open must not schedule retries which resurrect stop.
        let missingPath = root.appendingPathComponent("missing.log").path
        let missing = LogTail(path: missingPath, pollInterval: 0.01) { capture.append($0) }
        missing.start(); missing.stop { stopped.signal() }
        check(stopped.wait(timeout: .now() + 2) == .success)
        try "must not arrive\n".write(toFile: missingPath, atomically: false, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.08)
        check(!capture.snapshot.contains("must not arrive"))
        // Failure to open remains visible to the caller, not silently successful.
        let badWriter = AppendLogFile(path: root.appendingPathComponent("absent/no.log").path)
        check(!badWriter.append("not persisted", level: .error))
        print("Logging: \(checks) checks passed (64,000 concurrent events; 1,000 concurrent file appends)")
    }
}
