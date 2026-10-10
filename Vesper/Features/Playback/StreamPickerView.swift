import SwiftUI
import VesperCore

struct StreamPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let media: MediaItem
    let video: VideoSelection
    @State private var result = StreamResults()
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            SourceResultsScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.name).font(.title3.bold())
                    if let title = video.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                HStack {
                    Text("Player").font(.headline)
                    Spacer()
                    Picker("Player", selection: $store.preferredPlayer) {
                        ForEach(VideoPlayer.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }.padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.22), lineWidth: 1) }
                if loading { ProgressView("Finding streams…").frame(maxWidth: .infinity).padding(.vertical, 30) }
                if !loading && result.options.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView("No streams found", systemImage: "play.slash", description: Text("Install a stream add-on in Settings → Add-ons. TMDB supplies details, artwork, and episode information."))
                        Button("Try again") { Task { await load() } }.buttonStyle(.glass).frame(maxWidth: .infinity)
                    }
                }
                if !result.options.isEmpty {
                    Text("Available sources").font(.headline).padding(.horizontal, 2).padding(.top, 12).padding(.bottom, 4)
                    ForEach(result.options) { option in
                        SourceResultCard(option: option) { play(option.source) }
                        .contextMenu {
                            ForEach(VideoPlayer.allCases) { player in
                                Button("Play in \(player.title)", systemImage: "play") { play(option.source, player: player) }
                            }
                        }
                        .modifier(SourceCardScrollEffect())
                    }
                }
                if !result.failures.isEmpty {
                    Text("Unavailable add-ons").font(.headline).padding(.top, 12)
                    ForEach(result.failures, id: \.self) { failure in
                        ErrorNotice(message: failure)
                    }
                    Button("Retry add-ons") { Task { await load() } }.buttonStyle(.glass)
                }
            }.navigationTitle("Choose a stream").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task(id: video.id) { await load() }
                .alert("Unable to play", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func load() async {
        loading = true
        let next = await store.streamOptions(type: media.type, videoID: video.id, embedded: video.embedded) { partial in
            guard !Task.isCancelled else { return }
            result = partial
            if !partial.options.isEmpty { loading = false }
        }
        guard !Task.isCancelled else { return }
        result = next; loading = false
    }
    private func play(_ source: StreamSource, player: VideoPlayer? = nil) {
        do {
            switch try StreamResolver.resolve(source, server: store.streamingServer) {
            case .native(let url):
                let player = player ?? store.preferredPlayer
                let progress = store.progress(for: media, videoID: video.id)
                let position = progress?.isFinished == false ? progress?.position ?? 0 : 0
                let launch = try player.launchURL(for: url, position: position)
                openURL(launch) { accepted in
                    if !accepted { error = "Couldn’t open \(player.title). Install it or select another player." }
                }
            case .external(let url): openURL(url) { accepted in if !accepted { error = "Couldn’t open the external link." } }
            }
        } catch { self.error = error.localizedDescription }
    }
}
