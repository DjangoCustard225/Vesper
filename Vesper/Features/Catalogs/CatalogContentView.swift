import SwiftUI
import VesperCore

@MainActor
protocol CatalogContentLoading: AnyObject {
    var items: [MediaItem] { get }
    var loading: Bool { get }
    var error: String? { get }
    var hasMore: Bool { get }
    var pageRevision: UUID { get }
    var allowsAutomaticPaging: Bool { get }
    func loadMore() async
    func retryPages() async
}

extension CatalogController: CatalogContentLoading {
    var allowsAutomaticPaging: Bool { error == nil }
    func retryPages() async { await loadMore() }
}

extension CombinedCatalogController: CatalogContentLoading {
    var allowsAutomaticPaging: Bool { true }
    func retryPages() async { await retry() }
}

/// All catalogs share the same grid, empty-state and automatic paging presentation.
struct CatalogContentView: View {
    let model: any CatalogContentLoading
    var spacing: CGFloat = 24
    var loadingTitle: String?
    var progressPadding: CGFloat = 16
    let emptyTitle: String
    var emptyDescription: String?

    private var canLoadMore: Bool {
        model.hasMore && !model.loading && model.allowsAutomaticPaging
    }

    var body: some View {
        VStack(spacing: spacing) {
            MediaGrid(items: model.items, onNearEnd: requestNextPage)
            if model.loading {
                Group {
                    if let loadingTitle { ProgressView(loadingTitle) } else { ProgressView() }
                }.padding(progressPadding)
            }
            if let error = model.error {
                ErrorNotice(message: error) { Task { await model.retryPages() } }
            }
            if !model.loading, model.items.isEmpty, model.error == nil {
                if let emptyDescription {
                    ContentUnavailableView(
                        emptyTitle, systemImage: "film", description: Text(emptyDescription))
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
