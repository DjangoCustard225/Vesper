import SwiftUI
import WidgetKit

@main
struct VesperWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        UpNextWidget()
        LibraryWidget()
        ResumeControl()
    }
}
