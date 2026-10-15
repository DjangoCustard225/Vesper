import SwiftUI
import VesperCore

struct AutoPaginationTrigger: View {
    let load: () -> Void

    var body: some View {
        Color.clear.frame(height: 1).accessibilityHidden(true)
            .onScrollVisibilityChange(threshold: 0.01) { if $0 { load() } }
    }
}
