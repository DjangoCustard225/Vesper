import Foundation
import XCTest
@testable import UsenetEngine

final class EncryptedArchiveTests: XCTestCase {
    private let prefixes = ["rar4-file", "rar4-header", "rar5-file", "rar5-header"]
    private var payload: Data {
        Data([0, 0, 0, 24] + Array("ftypisom".utf8) + [0, 0, 0, 0] + Array("isomiso2".utf8))
            + Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
    }
    private func session(
        _ prefix: String, password: String? = nil, passwords: [String] = [], volumeCount: Int = 3
    ) async throws
        -> UsenetSession
    {
        let source = FixtureSource()
        var files: [NZBFile] = []
        for index in 1...volumeCount {
            let url = try XCTUnwrap(
                Bundle.module.url(
                    forResource: "\(prefix).part\(index)", withExtension: "rar", subdirectory: "Fixtures"))
            files.append(
                await source.add(
                    try Data(contentsOf: url), id: index - 1, name: url.lastPathComponent, chunk: 509))
        }
        return try UsenetSession(
            manifest: NZBManifest(files: files, password: password, passwords: passwords), source: source,
            cacheDirectory: temporaryDirectory())
    }
    func testOfficialEncryptedVolumesSupportPasswordRetryAndUnalignedSeeks() async throws {
        for prefix in prefixes {
            let session = try await session(prefix)
            await expectError(.encrypted) { _ = try await session.catalog() }
            await expectError(.badPassword) { _ = try await session.catalog(password: "wrong") }
            let videos = try await session.catalog(password: "secret")
            XCTAssertEqual(videos.count, 1, prefix)
            let video = try XCTUnwrap(videos.first)
            XCTAssertEqual(video.length, Int64(payload.count), prefix)
            for (offset, count) in [(0, 8216), (1, 1), (3989, 100), (7650, 560), (8191, 100), (17, 37)] {
                let data = try await session.read(video: video, offset: Int64(offset), count: count)
                XCTAssertEqual(
                    data, payload.subdata(in: offset..<min(payload.count, offset + count)),
                    "\(prefix) at \(offset)")
            }
            await session.stop()
        }
    }
    func testEmbeddedPasswordAndCDATAAreReadWithoutPersistingThem() async throws {
        let xml =
            #"<nzb><head><meta type="password"><![CDATA[ secret ]]></meta></head><file subject='"movie.mp4"'><segments><segment bytes="5" number="1">message@test</segment></segments></file></nzb>"#
        let manifest = try NZBManifest.parse(Data(xml.utf8))
        XCTAssertEqual(manifest.password, "secret")
        let session = try await session("rar5-header", password: manifest.password)
        let videos = try await session.catalog()
        XCTAssertEqual(videos.count, 1)
        await session.stop()
    }
    func testAutomaticHintsRetryAndLongUnicodePasswords() async throws {
        let password = "long-password-" + String(repeating: "épisode🌙-", count: 6)
        for version in [4, 5] {
            let session = try await session("rar\(version)-unicode", password: password)
            let catalog = try await session.catalog()
            let video = try XCTUnwrap(catalog.first)
            let actual = try await session.read(video: video, offset: 0, count: payload.count)
            XCTAssertEqual(actual, payload)
            await session.stop()
        }
        XCTAssertEqual(
            ArchivePasswords.candidates(
                explicit: ["secret", "secret"], names: ["Show {{other}}.nzb", "Show password=third.nzb"]),
            ["secret", "other", "third"])
        XCTAssertTrue(ArchivePasswords.candidates(explicit: [], names: ["ordinary.movie.nzb"]).isEmpty)
    }
    func testAutomaticDecryptionTriesSuppliedCandidatesWithoutUserInput() async throws {
        for prefix in prefixes {
            let session = try await session(prefix, passwords: ["incorrect", "secret"])
            let catalog = try await session.catalog()
            let video = try XCTUnwrap(catalog.first)
            let actual = try await session.read(video: video, offset: 0, count: payload.count)
            XCTAssertEqual(actual, payload)
            await session.stop()
        }
        let xml =
            #"<nzb><head><meta type="password">wrong</meta><meta type="password"><![CDATA[secret]]></meta></head><file subject='"movie.mp4"'><segments><segment bytes="5" number="1">message@test</segment></segments></file></nzb>"#
        let parsed = try NZBManifest.parse(
            Data(xml.utf8), name: "Release {{filename-secret}}.nzb", passwords: ["header-secret"])
        XCTAssertEqual(parsed.passwords, ["wrong", "secret", "header-secret", "filename-secret"])
    }
    func testEncryptedSeasonPackStreamsEachEpisodeWithItsOwnCipher() async throws {
        let session = try await session("season-pack", password: "secret", volumeCount: 5)
        let videos = try await session.catalog()
        XCTAssertEqual(videos.map(\.name), ["Show.S01E01.mp4", "Show.S01E02.mp4"])
        for video in videos {
            let actual = try await session.read(video: video, offset: 4001, count: 2017)
            XCTAssertEqual(actual, payload.subdata(in: 4001..<6018))
        }
        await session.stop()
    }
    func testEpisodeSelectionRequiresExactCoordinatesAndSkipsSamples() {
        let target = UsenetEpisodeTarget(season: 1, episode: 2, airDate: "2020-01-02")
        for name in ["Show.S01E02.mkv", "Show.1x02.mp4", "Show.2020.01.02.mkv"] {
            XCTAssertTrue(target.matches(UsenetVideo(id: 0, name: name, extents: [])), name)
        }
        for name in [
            "Show.S01E020.mkv", "Show.S02E02.mkv", "Show.S01E02.sample.mp4", "Show.S01E03.mkv",
            "obfuscated.mkv",
        ] {
            XCTAssertFalse(target.matches(UsenetVideo(id: 0, name: name, extents: [])), name)
        }
    }
    func testConcurrentEncryptedReadsAcrossVolumeAndBlockBoundaries() async throws {
        for prefix in prefixes {
            let session = try await session(prefix, password: "secret")
            let catalog = try await session.catalog(), video = try XCTUnwrap(catalog.first)
            let ranges = [(1, 197), (3989, 200), (4007, 300), (7989, 200), (17, 70)]
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, count) in ranges {
                    group.addTask {
                        (
                            offset,
                            try await session.read(
                                video: video, offset: Int64(offset), count: count, priority: .download)
                        )
                    }
                }
                for try await (offset, bytes) in group {
                    XCTAssertEqual(bytes, payload.subdata(in: offset..<(offset + bytes.count)), prefix)
                }
            }
            await session.stop()
        }
    }
    func testExcessiveKDFWorkIsRejectedBeforeDerivation() async {
        let keys = RARKeyStore(password: "secret")
        await expectError(.unsupported) {
            _ = try await keys.rar5(
                salt: Data(repeating: 0, count: 16), logRounds: 21, iv: Data(repeating: 0, count: 16))
        }
    }
}
