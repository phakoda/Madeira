import Foundation

/// Compile constant patterns once, not for every Wine/FEX log line.
struct LogPattern {
    private static let replacements: [(NSRegularExpression, String)] = [
        (#"^\[\d{2}:\d{2}:\d{2}\.\d{3}\]\s*"#, ""),
        (#"^\[(INFO|OK|ERR|DBG|WARN|FATAL)\]\s*"#, ""),
        (#"^[IEDW]\s+[0-9a-fA-F]+\s+"#, ""),
        (#"^[0-9a-fA-F]{4}:"#, "T:"),
        (#"0x[0-9a-fA-F]+"#, "0x?"),
        (#"#\d+"#, "#_"),
        (#"\b\d{3,}\b"#, "#"),
        (#"\s+"#, " ")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func canonicalize(_ raw: String) -> (signature: String, level: LogRecord.Level) {
        var s = String(raw.prefix(4096))
        let first = replacements[0]
        s = first.0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: first.1)
        let level = inferLevel(from: s)
        for (regex, replacement) in replacements.dropFirst() {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
        }
        return (String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), level)
    }
    private static func inferLevel(from line: String) -> LogRecord.Level {
        // Explicit markers are authoritative; "success" inside an error must
        // not turn a failed operation green.
        if line.hasPrefix("[ERR]") || line.hasPrefix("[FATAL]") { return .error }
        if line.hasPrefix("[DBG]") { return .debug }
        if line.hasPrefix("[OK]") { return .success }
        if line.hasPrefix("[WARN]") || line.hasPrefix("[INFO]") { return .info }
        let l = line.lowercased()
        if l.contains("fatal") || l.contains("c000001d") || l.contains("c0000005") ||
            l.contains("ntterminateprocess") || l.contains("unhandled") ||
            l.contains("seh:") || l.contains("err:") || line.hasPrefix("E ") { return .error }
        if l.contains("ok ") || l.contains(" ok)") || l.contains("succeeded") ||
            l.contains("success") || l.contains("present #") || line.contains("🎉") { return .success }
        if line.hasPrefix("D ") || l.contains("debug") || l.contains("trace:") { return .debug }
        return .info
    }
}
