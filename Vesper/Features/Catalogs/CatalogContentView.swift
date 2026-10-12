import SwiftUI
import VesperCore

/// Both catalog providers use the same retry, empty-state, and automatic paging rules.
struct CatalogContentView: View {
    let model: CatalogController
    var spacing: CGFloat = 24
    var loadingTitle: String?
    var progressPadding: CGFloat = 16
    let emptyTitle: String
    var emptyDescription: String?

    private var canLoadMore: Bool {
        model.hasMore && !model.loading && model.error == nil
    }

    var body: some View {
        VStack(spacing: spacing) {
            MediaGrid(items: model.items, onNearEnd: requestNextPage)
            if model.loading {
                Group {
                    if let loadingTitle { ProgressView(loadingTitle) }
                    else { ProgressView() }
                }.padding(progressPadding)
            }
            if let error = model.error {
                ErrorNotice(message: error) { Task { await model.loadMore() } }
            }
            if !model.loading, model.items.isEmpty, model.error == nil {
                if let emptyDescription {
                    ContentUnavailableView(emptyTitle, systemImage: "film", description: Text(emptyDescription))
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "film")
                }
            }
            if canLoadMore, !model.items.isEmpty {
                AutoPaginationTrigger(load: requestNextPage).id(model.pageRevision)
            }
        }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
    }

    private func requestNextPage() {
        guard canLoadMore else { return }
        Task { await model.loadMore() }
    }
}
