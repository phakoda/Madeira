// Bounded log aggregation shared by the app and portable regression tests.
// GPL-3.0-or-later.
import Foundation

struct LogRecord: Identifiable {
    let id = UUID()
    var firstTimestamp: Date
    var lastTimestamp: Date
    var signature: String
    var lastRaw: String
    var count: Int
    var level: Level
    enum Level: String {
        case info = "INFO", success = "OK", error = "ERR", debug = "DBG"
    }
    mutating func merge(_ other: LogRecord) {
        count = count > Int.max - other.count ? Int.max : count + other.count
        firstTimestamp = min(firstTimestamp, other.firstTimestamp)
        if other.lastTimestamp >= lastTimestamp {
            lastTimestamp = other.lastTimestamp
            lastRaw = other.lastRaw
            if level != .error { level = other.level }
        }
        if other.level == .error { level = .error }
    }
}

/// Every mutable field is protected by lock. No producer ever captures a UI
/// array index, so sorting/eviction cannot redirect updates to another row.
final class LogAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var order: [String?]
    private var head = 0, count = 0
    private var pending: [String: LogRecord] = [:]
    private var evictedLines = 0

    init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
        order = Array(repeating: nil, count: capacity)
    }
    func append(signature: String, raw: String, level: LogRecord.Level, at now: Date = Date()) {
        guard !signature.isEmpty else { return }
        let record = LogRecord(firstTimestamp: now, lastTimestamp: now,
            signature: String(signature.prefix(200)), lastRaw: String(raw.prefix(4096)), count: 1, level: level)
        lock.lock(); defer { lock.unlock() }
        if var old = pending[record.signature] {
            old.merge(record)
            pending[record.signature] = old
            return
        }
        if count == capacity, let key = order[head] {
            let lost = pending.removeValue(forKey: key)?.count ?? 0
            evictedLines = evictedLines > Int.max - lost ? Int.max : evictedLines + lost
            order[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        order[(head + count) % capacity] = record.signature
        count += 1
        pending[record.signature] = record
    }
    func drain() -> (records: [LogRecord], evictedLines: Int) {
        lock.lock(); defer { lock.unlock() }
        var result: [LogRecord] = []
        result.reserveCapacity(count)
        for n in 0..<count {
            let index = (head + n) % capacity
            if let key = order[index], let record = pending[key] { result.append(record) }
            order[index] = nil
        }
        let evicted = evictedLines
        pending.removeAll(keepingCapacity: true)
        head = 0; count = 0; evictedLines = 0
        return (result, evicted)
    }
    func clear() { _ = drain() }

    /// Run on the UI executor, then publish the returned array exactly once.
    static func merge(_ batch: [LogRecord], into entries: [LogRecord], capacity: Int) -> [LogRecord] {
        guard capacity > 0 else { return [] }
        var result = entries
        var indices: [String: Int] = [:]
        for (index, entry) in result.enumerated() { indices[entry.signature] = index }
        for entry in batch {
            if let index = indices[entry.signature] { result[index].merge(entry) }
            else {
                indices[entry.signature] = result.count
                result.append(entry)
            }
        }
        if result.count > capacity {
            // Retain most recently active signatures, with deterministic ties.
            result.sort {
                $0.lastTimestamp == $1.lastTimestamp
                    ? $0.signature < $1.signature : $0.lastTimestamp < $1.lastTimestamp
            }
            result.removeFirst(result.count - capacity)
            result.sort {
                $0.firstTimestamp == $1.firstTimestamp
                    ? $0.signature < $1.signature : $0.firstTimestamp < $1.firstTimestamp
            }
        }
        return result
    }
}
