import Foundation

extension UsenetProvider {
    /// Add-on servers take precedence; saved backups fill missing articles in configured order.
    public static func selection(
        servers: [String], saved: UsenetProvider?, backups: [UsenetProvider]
    ) throws -> [UsenetProvider] {
        guard servers.count <= 16 else { throw UsenetError.providerRequired }
        var selected: [UsenetProvider]
        if servers.isEmpty {
            guard let saved else { throw UsenetError.providerRequired }
            selected = [try saved.validated()]
        } else {
            selected = servers.compactMap {
                try? Self.from(server: $0, limit: saved?.connections ?? Self.defaultConnections)
            }
            guard !selected.isEmpty else { throw UsenetError.providerRequired }
        }
        // Backups are optional fill-ins: an invalid saved backup is skipped, never fatal.
        for backup in backups where !selected.contains(backup) {
            if let valid = try? backup.validated(), !selected.contains(valid) { selected.append(valid) }
        }
        return selected
    }
}
