import Foundation
import Observation
import UsenetEngine
import VesperCore

@MainActor @Observable final class UsenetService {
    static let shared = UsenetService()
    private(set) var provider: UsenetProvider?
    private(set) var backupProviders: [UsenetProvider] = []
    private(set) var storageError: String?
    private var token: UUID?
    private var session: UsenetSession?
    private var server: UsenetHTTPServer?
    private var pool: NNTPPool?
    private let root: URL
    private let cleanup: Task<Void, Never>
    private init() {
        do { provider = try SecureStorage.load(.usenetProvider) } catch {
            storageError = error.localizedDescription
        }
        do { backupProviders = try SecureStorage.load(.usenetBackupProviders) ?? [] } catch {
            storageError = error.localizedDescription
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsenetStreaming", isDirectory: true)
        self.root = root
        cleanup = Task.detached {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for url
                in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
                ?? []
            {
                if UUID(uuidString: url.lastPathComponent) != nil {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
    func save(_ value: UsenetProvider) throws {
        let validated = try value.validated()
        try SecureStorage.save(validated, for: .usenetProvider); provider = validated; storageError = nil
    }
    func saveBackupProviders(_ providers: [UsenetProvider]) throws {
        let values = try providers.map { try $0.validated() }
        try SecureStorage.save(values, for: .usenetBackupProviders)
        backupProviders = values
    }
    func test(_ value: UsenetProvider) async throws {
        let pool = try NNTPPool(provider: value.validated())
        do {
            try await pool.test()
            try Task.checkCancellation()
        } catch { await pool.stop(); throw error }
        await pool.stop()
    }
    func prepare(
        token: UUID, source: StreamSource? = nil, data: Data? = nil, name: String? = nil,
        passwords: [String] = []
    ) async throws -> [UsenetVideo] {
        let oldServer = server, oldSession = session, oldPool = pool
        self.token = token; server = nil; session = nil; pool = nil
        await oldServer?.stop(); await oldSession?.stop(); await oldPool?.stop()
        await cleanup.value
        try await DownloadManager.shared.reserveUsenetPlayback(token)
        try Task.checkCancellation()
        guard self.token == token else { throw CancellationError() }
        let selected: UsenetProvider
        if let servers = source?.servers, !servers.isEmpty {
            guard servers.count <= 16,
                let first = servers.compactMap({
                    try? UsenetProvider.from(server: $0, limit: provider?.connections ?? 8)
                }).first
            else { throw UsenetError.providerRequired }
            selected = first
        } else {
            guard let saved = provider else { throw UsenetError.providerRequired };
            selected = try saved.validated()
        }
        let bytes: Data
        var passwords = passwords
        if let data {
            bytes = data
        } else if let raw = source?.nzbUrl {
            let result = try await Self.fetch(try AddonURL.http(raw))
            bytes = result.data
            if let password = result.password { passwords.append(password) }
        } else {
            throw UsenetError.invalidNZB
        }
        let hints = passwords
        let suggestedName = name ?? source?.title ?? source?.name
        let manifest = try await Task.detached {
            try NZBManifest.parse(bytes, name: suggestedName, passwords: hints)
        }.value
        try Task.checkCancellation()
        guard self.token == token else { throw CancellationError() }
        let pool = try NNTPPool(provider: selected)
        self.pool = pool
        let session = try UsenetSession(
            manifest: manifest, source: pool,
            cacheDirectory: root.appendingPathComponent(token.uuidString, isDirectory: true))
        self.session = session
        let catalog = try await session.catalog()
        try Task.checkCancellation()
        guard self.token == token else { await session.stop(); throw CancellationError() }
        return try UsenetSelection.candidates(
            catalog, fileIndex: source?.fileIdx, pattern: source?.fileMustInclude)
    }
    func open(_ video: UsenetVideo, token: UUID, onFailure: @escaping @MainActor @Sendable (String) -> Void)
        async throws -> URL
    {
        guard self.token == token, let session else { throw UsenetError.cancelled }
        let server = UsenetHTTPServer(); self.server = server
        let url = try await server.start(video: video, session: session) { [weak self] error in
            Task { @MainActor in if self?.token == token { onFailure(error.localizedDescription) } }
        }
        guard self.token == token else { await server.stop(); throw CancellationError() }; return url
    }
    func stop(_ token: UUID?) async {
        guard let token, token == self.token else { return }
        let oldServer = server, oldSession = session, oldPool = pool
        self.token = nil; server = nil; session = nil; pool = nil
        await oldServer?.stop(); await oldSession?.stop(); await oldPool?.stop()
        DownloadManager.shared.releaseUsenetPlayback(token)
    }
    nonisolated static func fetch(_ url: URL) async throws -> NZBDownload {
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength <= 16 * 1024 * 1024
        else { throw UsenetError.invalidNZB }
        var result = Data()
        for try await byte in bytes {
            guard result.count < 16 * 1024 * 1024 else { throw UsenetError.invalidNZB }
            result.append(byte)
        }
        return NZBDownload(data: result, password: response.value(forHTTPHeaderField: "x-dnzb-password"))
    }
    nonisolated static func importFile(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource();
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw UsenetError.invalidNZB }; return data
    }
}
