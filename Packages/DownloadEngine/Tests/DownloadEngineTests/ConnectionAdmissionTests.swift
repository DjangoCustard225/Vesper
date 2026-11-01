import Foundation
import Testing
@testable import DownloadEngine

private actor AdmissionServer {
    var active = 0
    var rejected = 0
    let rejectAll: Bool
    let rejection: NNTPError
    init(rejectAll: Bool = false, rejection: NNTPError = .authenticationFailed(502)) {
        self.rejectAll = rejectAll; self.rejection = rejection
    }
    func open() async throws {
        if rejectAll || active >= 1 {
            rejected += 1
            // Healthy workers can drain the queue before excess logins finish failing.
            try await Task.sleep(for: .milliseconds(30))
            throw rejection
        }
        active += 1
    }
    func close() { active -= 1 }
}

private actor AdmissionConnection: DownloadConnection {
    let server: AdmissionServer
    var opened = false
    init(_ server: AdmissionServer) { self.server = server }
    func open() async throws { try await server.open(); opened = true }
    func close() async {
        guard opened else { return }
        opened = false; await server.close()
    }
    func fetchBody(messageID: String) async throws -> [Data] {
        let data = Data([65]), crc = String(format: "%08x", CRC32.checksum(of: data))
        return [
            Data("=ybegin line=128 size=1 name=\(messageID).bin".utf8), Data([107]),
            Data("=yend size=1 crc32=\(crc) pcrc32=\(crc)".utf8),
        ]
    }
}

struct ConnectionAdmissionTests {
    private func run(_ server: AdmissionServer) async throws -> (EngineResult?, Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<12).map { index in
            FileSpec(
                id: "f\(index)", filename: "f\(index).bin", groups: [],
                segments: [
                    SegmentSpec(id: "s\(index)", messageID: "f\(index)", byteCount: 1, number: 1)
                ])
        }
        let engine = NZBDownloadEngine(makeConnection: { _, _ in AdmissionConnection(server) })
        let events = await engine.run(
            job: JobSpec(id: "job", files: files, workingDirectory: root),
            server:
                ServerConfig(
                    host: "test.invalid", port: 563, useSSL: true, username: "user", password: "pass",
                    maxConnections: 8))
        var result: EngineResult?
        for await event in events { if case .finished(let value) = event { result = value } }
        await engine.cancelAndWait()
        let saved = files.filter {
            (try? Data(contentsOf: root.appendingPathComponent($0.filename))) == Data([65])
        }.count
        #expect(await server.active == 0)
        return (result, saved)
    }

    @Test func excessConnectionsDoNotCancelHealthyDownloads() async throws {
        for rejection in [NNTPError.authenticationFailed(502), .badGreeting(502)] {
            let server = AdmissionServer(rejection: rejection)
            let (result, saved) = try await run(server)
            guard case .completed(_, let missing) = result else {
                Issue.record("A valid login with rejected excess connections must finish"); return
            }
            #expect(missing == 0)
            #expect(saved == 12)
            #expect(await server.rejected > 0)
        }
    }

    @Test func invalidCredentialsStillFailWithoutCompletingFiles() async throws {
        let (result, saved) = try await run(
            AdmissionServer(rejectAll: true, rejection: .authenticationFailed(481)))
        guard case .failed(let reason) = result else {
            Issue.record("A rejected baseline login must fail"); return
        }
        #expect(reason.contains("481"))
        #expect(saved == 0)
    }
}
