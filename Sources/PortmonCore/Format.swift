import Foundation

public enum Format {
    public static func uptime(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(max(seconds, 0))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes < 1024 ? "\(Int(megabytes.rounded())) MB" : String(format: "%.1f GB", megabytes / 1024)
    }

    public static func cpu(_ percent: Double) -> String {
        percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    public static func latency(_ interval: TimeInterval) -> String {
        let milliseconds = interval * 1000
        return milliseconds < 1000
            ? "\(Int(milliseconds.rounded()))ms"
            : String(format: "%.1fs", interval)
    }

    public static let unavailable = "—"
}

public enum TunnelURL {
    public static func extract(from line: String) -> String? {
        let pattern = #"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range, in: line) else { return nil }
        return String(line[range])
    }
}
