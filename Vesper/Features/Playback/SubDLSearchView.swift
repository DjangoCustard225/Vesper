import SwiftUI
import VesperCore

struct SubDLSearchView: View {
    let media: MediaItem
    let videoID: String?
    let select: (URL, SubDLSubtitle) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("subdlLanguage") private var language =
        Locale.current.language.languageCode?.identifier ?? "en"
    @State private var results: [SubDLSubtitle] = []
    @State private var error: String?
    @State private var loading = false
    @State private var selected: SubDLSubtitle?
    @State private var download: Task<Void, Never>?
    @State private var attempt = 0
    @State private var searchID = UUID()
    @State private var fullName: SubtitleName?
    private struct SubtitleName: Identifiable {
        let id = UUID()
        let value: String
    }

    var body: some View {
        NavigationStack {
            SourceResultsScrollView {
                Text(media.name).font(.title3.bold())
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                HStack {
                    Text("Language").font(.headline)
                    Spacer()
                    SubDLLanguagePicker("Language", selection: $language)
                        .pickerStyle(.menu).labelsHidden().tint(.white).disabled(selected != nil)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
                if let error {
                    ErrorNotice(message: error)
                    Button("Try again") { attempt += 1 }.buttonStyle(.glass)
                }
                if loading {
                    ProgressView("Searching…").frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if results.isEmpty, error == nil {
                    ContentUnavailableView("No subtitles found", systemImage: "captions.bubble")
                }
                if !results.isEmpty {
                    Text("Available subtitles").font(.headline).padding(.horizontal, 2).padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(results) { result in
                        Button {
                            fetch(result)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(result.name).font(.headline.weight(.semibold)).foregroundStyle(
                                        .primary
                                    )
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                    Text(result.language).font(.subheadline).foregroundStyle(.secondary)
                                    Text("SubDL").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if selected?.id == result.id {
                                    ProgressView().accessibilityLabel("Downloading subtitle")
                                }
                            }.modifier(SourceCardSurface())
                        }
                        .buttonStyle(.plain).disabled(selected != nil)
                        .accessibilityLabel([result.name, result.language, "SubDL"].joined(separator: ", "))
                        .accessibilityHint(
                            "Downloads and selects this subtitle. Long press for its full name."
                        )
                        .contextMenu {
                            Button("Show Full Name", systemImage: "text.alignleft") {
                                fullName = SubtitleName(value: result.name)
                            }
                        }
                        .modifier(SourceCardScrollEffect())
                    }
                }
            }
            .navigationTitle("SubDL").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .task(id: "\(language):\(attempt)") {
                let query = language, id = UUID()
                searchID = id
                loading = true; error = nil; results = []
                defer { if searchID == id { loading = false } }
                do {
                    let key = try SecureStorage.load(.subdlAPIKey) ?? ""
                    let value = try await SubDLClient(key: key).search(
                        media: media, videoID: videoID, language: query)
                    try Task.checkCancellation()
                    guard searchID == id else { return }
                    results = value
                } catch is CancellationError {} catch {
                    guard !Task.isCancelled, searchID == id else { return }
                    self.error = error.localizedDescription
                }
            }
            .sheet(item: $fullName) { name in
                ScrollView {
                    Text(name.value).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(24)
                }.appScrollEdges().presentationDetents([.medium]).presentationDragIndicator(.visible)
            }
            .onAppear { Task.detached(priority: .utility) { SubDLClient.removeOldDownloads() } }
            .onDisappear {
                download?.cancel()
                download = nil
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func fetch(_ result: SubDLSubtitle) {
        guard selected == nil else { return }
        selected = result; error = nil
        download = Task {
            defer { selected = nil; download = nil }
            do {
                let key = try SecureStorage.load(.subdlAPIKey) ?? ""
                let url = try await SubDLClient(key: key).download(result)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                select(url, result)
                dismiss()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
