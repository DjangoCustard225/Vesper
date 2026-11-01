import Foundation
import DownloadEngine
import PAR2Kit
import UsenetEngine
import VesperCore

struct UsenetDownloadResult: Sendable {
    let receipt: DownloadReceipt
    let filename: String
}

enum UsenetDownloadError: LocalizedError {
    case episodeSelection, videoSelection([String]), passwordRequired, damaged, engine(String)
    var errorDescription: String? {
        switch self {
        case .episodeSelection:
            "The requested episode could not be identified in this release. Choose a video file."
        case .videoSelection: "Choose the video to save from this release."
        case .passwordRequired: "Enter the archive password to finish this download."
        case .damaged:
            "This release is incomplete or damaged and could not be repaired. Try another provider or release."
        case .engine(let message): message
        }
    }
}

/// Persistent segment jobs are independent of playback and survive attempt changes and app restarts.
@MainActor enum UsenetDownloadTransfer {
    struct State: Codable, Sendable {
        var passwords: [String] = []
        var filenames: [String: String] = [:]
    }
    static var jobs: URL { DownloadFiles.root.appendingPathComponent("UsenetJobs", isDirectory: true) }
    static func directory(_ id: UUID) -> URL { jobs.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func run(
        record: DownloadRecord, source: StreamSource, key: DownloadTaskKey,
        begin: @escaping @MainActor (Int64) async throws -> Void,
        progress: @escaping @MainActor @Sendable (Int64, Int64, Int) -> Void,
        stage: @escaping @MainActor @Sendable (DownloadWorkProgress) async throws -> Void,
        finishing: @escaping @MainActor @Sendable (DownloadWorkProgress) -> Void
    ) async throws -> UsenetDownloadResult {
        let root = directory(record.id), payload = root.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try DownloadFiles.protect(root); try DownloadFiles.protect(payload)
        let manifestURL = root.appendingPathComponent("manifest.nzb")
        let stateURL = root.appendingPathComponent("state.json")
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        let data: Data
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard DownloadFiles.size(manifestURL) <= 16 * 1024 * 1024 else { throw UsenetError.invalidNZB }
            data = try Data(contentsOf: manifestURL)
        } else {
            guard let raw = source.nzbUrl else { throw UsenetError.invalidNZB }
            let url = try AddonURL.http(raw)
            let download: NZBDownload
            if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                parts.host?.lowercased() == "nzbfinder.ws", parts.path == "/api",
                let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
                parts.queryItems?.contains(where: { $0.name == "t" && $0.value == "get" }) == true
            {
                download = try await NZBFinderService.shared.nzb(
                    NZBRelease(id: id, title: source.title ?? ""))
            } else {
                download = try await UsenetService.fetch(url)
            }
            try Task.checkCancellation()
            data = download.data
            state.passwords = download.password.map { [$0] } ?? []
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try data.write(to: manifestURL, options: .atomic)
        }
        let passwords = state.passwords
        let manifest = try await Task.detached {
            try NZBManifest.parse(data, name: source.title, passwords: passwords)
        }.value
        var providers = (source.servers ?? []).prefix(16).compactMap {
            try? UsenetProvider.from(server: $0, limit: UsenetService.shared.provider?.connections ?? 8)
        }
        if providers.isEmpty, let provider = UsenetService.shared.provider {
            providers = [try provider.validated()]
        }
        providers += UsenetService.shared.backupProviders.filter { !providers.contains($0) }
        guard let provider = providers.first else { throw UsenetError.providerRequired }
        let options = UsenetDownloadOptions.shared
        let cap = min(1_000_000, max(0, options.bandwidthKBps)) * 1024
        let files = manifest.files.map { file in
            let id = "f\(file.id)"
            return FileSpec(
                id: id, filename: state.filenames[id] ?? file.name, groups: [],
                segments: file.segments.map {
                    SegmentSpec(
                        id: id + ":" + String($0.number), messageID: $0.messageID,
                        byteCount: $0.encodedBytes, number: $0.number)
                })
        }
        let total = files.reduce(Int64(0)) { $0 + Int64($1.totalBytes) }
        try await begin(total)
        let engine = NZBDownloadEngine()
        let config: (UsenetProvider) -> ServerConfig = {
            ServerConfig(
                host: $0.host, port: $0.port, useSSL: true, username: $0.username,
                password: $0.password, maxConnections: $0.connections, bytesPerSecondLimit: cap)
        }
        let job = JobSpec(id: record.id.uuidString, files: files, workingDirectory: payload)
        var outcome: EngineResult?
        await withTaskCancellationHandler {
            let events = await engine.run(
                job: job, server: config(provider), fallbackServers: providers.dropFirst().map(config))
            for await event in events {
                switch event {
                case .progress(let bytes, _, let connections): progress(Int64(bytes), total, connections)
                case .fileCompleted(let id, let url, _):
                    if !url.hasDirectoryPath {
                        state.filenames[id] = url.lastPathComponent
                        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
                    }
                case .finished(let result): outcome = result
                default: break
                }
            }
            await engine.cancelAndWait()
        } onCancel: {
            Task { await engine.cancel() }
        }
        try Task.checkCancellation()
        guard let outcome else {
            throw UsenetDownloadError.engine("Download stopped before it finished. Resume to continue.")
        }
        let missing: Int
        switch outcome {
        case .cancelled: throw CancellationError()
        case .failed(let reason): throw UsenetDownloadError.engine(reason)
        case .completed(_, let count): missing = count
        }
        try await stage(DownloadWorkProgress(.verifying))
        let reporting = DownloadWorkReporter { value in Task { @MainActor in finishing(value) } }
        let repair = options.repair
        let suppliedPassword = try SecureStorage.load(.archivePassword(record.id))
        var seenPasswords = Set<String>()
        let candidates = ((suppliedPassword.map { [$0] } ?? []) + manifest.passwords).filter {
            seenPasswords.insert($0).inserted
        }
        let postprocess = Task.detached {
            try await Self.finish(
                payload: payload, root: root, missing: missing, repair: repair, passwords: candidates,
                stage: stage, reporting: reporting)
        }
        let output = try await withTaskCancellationHandler {
            try await postprocess.value
        } onCancel: {
            postprocess.cancel()
        }
        try Task.checkCancellation()
        try await stage(DownloadWorkProgress(.saving))
        let selected = try select(output, root: root, record: record, source: source)
        let staged = DownloadFiles.stagingURL(key)
        try FileManager.default.createDirectory(at: DownloadFiles.incoming, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staged)
        let partial = root.appendingPathComponent("saving.partial")
        let copy = Task.detached { try Self.copy(selected, to: partial, reporting: reporting) }
        try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: {
            copy.cancel()
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: staged)
        try DownloadFiles.protect(staged)
        return UsenetDownloadResult(
            receipt: DownloadReceipt(
                location: staged, status: 200, mime: nil, total: DownloadFiles.size(staged)),
            filename: selected.lastPathComponent)
    }

    private nonisolated static func finish(
        payload: URL, root: URL, missing: Int, repair: Bool, passwords: [String],
        stage: @escaping @MainActor @Sendable (DownloadWorkProgress) async throws -> Void,
        reporting: DownloadWorkReporter
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let contents = try FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil)
        let parFiles = contents.filter { url in
            guard let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            return (try? file.read(upToCount: 8)) == Data("PAR2\0PKT".utf8)
        }
        if !parFiles.isEmpty {
            let job = PAR2Job(par2URLs: parFiles, directory: payload)
            let renames = job.restoreNames()
            let checkpointURL = payload.appendingPathComponent("checkpoint.json")
            var checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
            if !renames.isEmpty, var saved = checkpoint {
                let names = Dictionary(renames.map { ($0.from, $0.to) }, uniquingKeysWith: { _, new in new })
                for (id, name) in saved.finalizedFilenames {
                    saved.finalizedFilenames[id] = names[name] ?? name
                }
                try JSONEncoder().encode(saved).write(to: checkpointURL, options: .atomic)
                checkpoint = saved
            }
            var verified = try job.verify { fraction in
                try Task.checkCancellation()
                reporting.update(DownloadWorkProgress(.verifying, fraction: fraction))
            }
            try Task.checkCancellation()
            if !verified.hasPar2 {
                if missing > 0 { throw UsenetDownloadError.damaged }
            } else if !verified.isComplete {
                guard repair, verified.isRepairable else { throw UsenetDownloadError.damaged }
                try Task.checkCancellation()
                try await stage(DownloadWorkProgress(.repairing))
                let result = try job.repair { fraction in
                    try Task.checkCancellation()
                    reporting.update(DownloadWorkProgress(.repairing, fraction: fraction))
                }
                switch result {
                case .notNeeded, .repaired: break
                default: throw UsenetDownloadError.damaged
                }
                verified = try job.verify { _ in try Task.checkCancellation() }
                guard verified.isComplete else { throw UsenetDownloadError.damaged }
            }
            if var saved = checkpoint {
                let intact = Set(verified.files.filter(\.intact).map(\.name))
                for (id, name) in saved.finalizedFilenames where intact.contains(name) {
                    let repaired = saved.missingSegmentIDs.filter { $0.hasPrefix(id + ":") }
                    saved.completedSegmentIDs.formUnion(repaired)
                    saved.missingSegmentIDs.subtract(repaired)
                }
                try JSONEncoder().encode(saved).write(to: checkpointURL, options: .atomic)
                for (id, name) in saved.finalizedFilenames
                where ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"].contains(
                    (name as NSString).pathExtension.lowercased())
                    && saved.missingSegmentIDs.contains(where: { $0.hasPrefix(id + ":") })
                {
                    throw UsenetDownloadError.damaged
                }
            }
        } else if missing > 0 {
            throw UsenetDownloadError.damaged
        }
        try Task.checkCancellation()
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        if !UsenetArchiveExtractor.firstVolumeArchives(in: payload).isEmpty {
            try await stage(DownloadWorkProgress(.extracting))
            var unlocked = false
            for password in passwords.map(Optional.some) + [nil] {
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: extracted)
                switch UsenetArchiveExtractor.extract(
                    in: payload, to: extracted, password: password,
                    progress: {
                        reporting.update(DownloadWorkProgress(.extracting, fraction: $0))
                    })
                {
                case .extracted(let count) where count > 0: unlocked = true
                case .passwordRequired: continue
                case .failed: continue
                default: continue
                }
                if unlocked { break }
            }
            try Task.checkCancellation()
            guard unlocked else { throw UsenetDownloadError.passwordRequired }
        }
        let base = FileManager.default.fileExists(atPath: extracted.path) ? extracted : payload
        guard
            let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"].contains(
                    $0.pathExtension.lowercased())
        }.sorted { $0.path < $1.path }
    }

    private nonisolated static func copy(_ source: URL, to destination: URL, reporting: DownloadWorkReporter)
        throws
    {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DownloadFailure.storage
        }
        let input = try FileHandle(forReadingFrom: source)
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: destination) } catch { try? input.close(); throw error }
        let total = DownloadFiles.size(source)
        var written: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let bytes = try DownloadFileIO.copyChunk(from: input, to: output)
                guard bytes > 0 else { break }
                written += bytes
                reporting.update(
                    DownloadWorkProgress(.saving, fraction: Double(written) / Double(max(1, total))))
            }
            try output.synchronize(); try output.close(); try input.close()
            guard written == total else { throw DownloadFailure.incomplete }
        } catch {
            try? input.close(); try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func select(_ files: [URL], root: URL, record: DownloadRecord, source: StreamSource) throws
        -> URL
    {
        guard !files.isEmpty else { throw UsenetError.noVideo }
        func name(_ url: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }
        if let selected = record.usenetSelectedFile,
            let file = files.first(where: { name($0) == selected })
        {
            return file
        }
        let videos = files.enumerated().map { index, url in
            UsenetVideo(
                id: index, name: name(url),
                extents: [VideoExtent(fileID: index, offset: 0, length: DownloadFiles.size(url))])
        }
        var choices = try UsenetSelection.candidates(
            videos, fileIndex: record.episode == nil ? source.fileIdx : nil, pattern: source.fileMustInclude)
        if let episode = record.episode, let season = episode.season, let number = episode.episode {
            let target = UsenetEpisodeTarget(
                season: season, episode: number, airDate: episode.released.map { String($0.prefix(10)) })
            let matched = choices.filter(target.matches)
            if matched.count == 1 {
                choices = matched
            } else {
                throw UsenetDownloadError.videoSelection(choices.map(\.name))
            }
        } else {
            choices = choices.filter {
                $0.name.range(
                    of: #"(?i)(?:^|[ ._/-])(?:sample|proof)(?:[ ._/-]|$)"#, options: .regularExpression)
                    == nil
            }
        }
        guard choices.count == 1, let selected = choices.first else {
            throw UsenetDownloadError.videoSelection(choices.map(\.name))
        }
        return files[selected.id]
    }
}
