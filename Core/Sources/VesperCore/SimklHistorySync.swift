import Foundation

extension SimklClient {
    /// Fetches and parses a history snapshot on the client actor, away from UI state.
    public func historyUpdates(from state: SimklSyncState) async throws -> SimklHistoryUpdate {
        let activities = try await get("sync/activities")
        let root = try JSONSerialization.jsonObject(with: activities) as? [String: Any] ?? [:]
        let old =
            state.activities.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        guard let activity = root["all"], activity is String || activity is NSNull else {
            throw SimklError.response
        }
        let timestamp = activity as? String
        var proposed = state
        if timestamp == nil || state.activities == nil || (old["all"] as? String) != timestamp {
            for kind in ["shows", "movies"] {
                var query = [
                    URLQueryItem(name: "extended", value: "full"),
                    URLQueryItem(name: "episode_watched_at", value: "yes"),
                    URLQueryItem(name: "include_all_episodes", value: "yes"),
                ]
                if let previous = old["all"] as? String {
                    query.append(URLQueryItem(name: "date_from", value: previous))
                }
                let data = try await get("sync/all-items/" + kind, query: query)
                try Task.checkCancellation()
                try proposed.apply(data)
            }
            if state.activities != nil {
                for (kind, activityKey) in [("shows", "tv_shows"), ("movies", "movies")] {
                    let removed = (root[activityKey] as? [String: Any])?["removed_from_list"] as? String
                    let previous = (old[activityKey] as? [String: Any])?["removed_from_list"] as? String
                    guard removed != previous else { continue }
                    var retained = SimklSyncState()
                    try retained.apply(
                        await get(
                            "sync/all-items/" + kind,
                            query: [URLQueryItem(name: "extended", value: "simkl_ids_only")]))
                    try Task.checkCancellation()
                    proposed.items = proposed.items.filter {
                        !$0.key.hasPrefix(kind + ":") || retained.items[$0.key] != nil
                    }
                }
            }
        }
        try Task.checkCancellation()
        return SimklHistoryUpdate(state: proposed, entries: try proposed.entries(), activities: activities)
    }
}

public struct SimklHistoryUpdate: Sendable {
    public let state: SimklSyncState
    public let entries: [TraktWatchedEntry]
    public let activities: Data
}
