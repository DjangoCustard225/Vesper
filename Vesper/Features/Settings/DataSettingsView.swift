import SwiftUI
import UniformTypeIdentifiers
import VesperCore

struct DataSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var document = ExportDocument(data: Data())
    @State private var filename = AppIdentity.filePrefix + "-library"
    @State private var exporting = false
    @State private var importing = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Button("Export library backup", systemImage: "square.and.arrow.up") {
                    do {
                        document = ExportDocument(data: try store.exportLibrary())

                        filename = AppIdentity.filePrefix + "-library"
                        exporting = true
                    } catch { message = error.localizedDescription }
                }
                Button("Import library backup", systemImage: "square.and.arrow.down") { importing = true }
            }
            Section {
                Button {
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            try await store.clearCache()
                            message = "Cache cleared."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Label("Clear Cache", systemImage: "trash")
                        Spacer()
                        if store.isClearingCache { ProgressView().controlSize(.small) }
                    }
                }
            }
            Section {
                Button("Export diagnostics", systemImage: "doc.text") {
                    Task {
                        do {
                            document = ExportDocument(data: try await DiagnosticRecorder.shared.export())
                            filename = AppIdentity.filePrefix + "-diagnostics"
                            exporting = true
                        } catch { message = error.localizedDescription }
                    }
                }
            }
        }.disabled(working || store.isClearingCache).appScrollEdges().navigationTitle("Data")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(
                isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename
            ) { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else {
                    if case .failure(let error) = result { message = error.localizedDescription }
                    return
                }
                working = true
                Task {
                    defer { working = false }
                    do {
                        let data = try await Task.detached { try Self.readBackup(url) }.value
                        try store.restoreLibrary(data)
                        message = "Backup merged into your library."
                    } catch { message = error.localizedDescription }
                }
            }
            .alert("Data", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }

    private nonisolated static func readBackup(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw LibraryError.tooLarge }
        let data = try Data(contentsOf: url)
        _ = try LibraryRepository.decode(data)
        return data
    }
}

private struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LibraryError.invalidBackup }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
