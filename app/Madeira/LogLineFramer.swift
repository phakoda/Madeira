// Streaming UTF-8 line framing. No repeated Data-prefix removals or invalid
// nonzero Data indices; work is linear in bytes and memory is bounded per line.
// GPL-3.0-or-later.
import Foundation

struct LogLineFramer {
    private var bytes: [UInt8] = []
    private var truncated = false
    private let limit: Int
    init(limit: Int = 64 * 1024) {
        precondition(limit > 0)
        self.limit = limit
        bytes.reserveCapacity(min(limit, 4096))
    }
    mutating func append(_ input: UnsafeBufferPointer<UInt8>, onLine: (String) -> Void) {
        for byte in input {
            if byte == 10 {
                if bytes.last == 13 { bytes.removeLast() }
                if !bytes.isEmpty || truncated {
                    var line = String(decoding: bytes, as: UTF8.self)
                    if truncated { line += " [line truncated]" }
                    onLine(line)
                }
                reset()
            } else if bytes.count < limit {
                bytes.append(byte)
            } else { truncated = true }
        }
    }
    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        truncated = false
    }
}
