import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public enum SubtitleParser {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[index].components(separatedBy: " --> ")
            guard times.count == 2, let start = timestamp(times[0]),
                  let end = timestamp(String(times[1].split(separator: " ").first ?? "")), end > start else { return nil }
            let content = lines.dropFirst(index + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            guard !content.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: content)
        }.sorted { $0.start < $1.start }
    }
    public static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              numbers.last! < 60, numbers[numbers.count - 2] < 60 else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }
    public static func text(at time: Double, in cues: [SubtitleCue]) -> String? {
        cues.last { $0.start <= time && time < $0.end }?.text
    }
}
