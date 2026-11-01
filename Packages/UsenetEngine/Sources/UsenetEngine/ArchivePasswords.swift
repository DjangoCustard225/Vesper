import Foundation

/// Only explicit password hints are used. Titles and ordinary filenames are never guessed as keys.
public enum ArchivePasswords {
    public static func candidates(explicit: [String], names: [String]) -> [String] {
        var values = explicit
        for name in names.prefix(8) where name.utf8.count <= 8192 {
            var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.lowercased().hasSuffix(".nzb") { name.removeLast(4) }
            if let regex = try? NSRegularExpression(pattern: #"\{\{(.+?)\}\}"#) {
                for match in regex.matches(in: name, range: NSRange(name.startIndex..., in: name)).prefix(8) {
                    if let range = Range(match.range(at: 1), in: name) { values.append(String(name[range])) }
                }
            }
            if let range = name.range(of: "password=", options: .caseInsensitive) {
                values.append(String(name[range.upperBound...]))
            }
        }
        var seen = Set<String>()
        return Array(
            values.filter {
                !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") && seen.insert($0).inserted
            }.prefix(8))
    }
}
