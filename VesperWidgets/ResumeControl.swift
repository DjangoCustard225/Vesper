import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center, Lock Screen and Action button control that resumes the latest title.
struct ResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.vesper.resume", provider: LatestTitleProvider()) { title in
            ControlWidgetButton(action: OpenURLIntent(WidgetLink.resumeLatest)) {
                Label(title ?? "Resume Watching", systemImage: "play.fill")
            }
        }
        .displayName("Resume Watching")
        .description("Continue the last thing you watched in Vesper.")
    }
}

/// The title the control resumes, or nil when nothing is in progress.
struct LatestTitleProvider: ControlValueProvider {
    var previewValue: String? { nil }

    func currentValue() async throws -> String? {
        WidgetShelf.load().continueWatching.first?.title
    }
}
