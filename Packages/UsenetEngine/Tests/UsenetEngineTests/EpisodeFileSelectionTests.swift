import XCTest
@testable import UsenetEngine

final class EpisodeFileSelectionTests: XCTestCase {
    private let target = UsenetEpisodeTarget(season: 1, episode: 2)
    private func manifest(_ names: [String]) -> NZBManifest {
        NZBManifest(files: names.enumerated().map { NZBFile(id: $0.offset, name: $0.element, segments: []) })
    }
    func testSelectsOnlyTheRequestedVideoAndSkipsUnrelatedFiles() {
        let value = manifest(["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv", "season.par2"])
        XCTAssertEqual(value.filesForEpisode(target).map(\.name), ["Show.S01E02.mkv"])
    }
    func testSelectsTheCompleteIndependentlyNamedArchiveSet() {
        let value = manifest([
            "Show.S01E01.part01.rar", "Show.S01E02.part02.rar", "Show.S01E02.part01.rar",
            "Show.S01E01.part02.rar",
        ])
        XCTAssertEqual(
            value.filesForEpisode(target).map(\.name), ["Show.S01E02.part01.rar", "Show.S01E02.part02.rar"])
    }
    func testAmbiguousOrSharedSeasonArchivesKeepAllFiles() {
        for names in [
            ["Season.01.part01.rar", "Season.01.part02.rar", "season.par2"],
            ["Show.S01E02.720p.mkv", "Show.S01E02.1080p.mkv", "season.par2"],
            ["Show.S01E01.part01.rar", "Show.S01E02.part01.rar", "Show.S01E02.part03.rar"],
            ["Show.S01E02.mkv", "Show.S01E02.par2"],
        ] {
            let value = manifest(names)
            XCTAssertEqual(value.filesForEpisode(target).map(\.id), value.files.map(\.id))
        }
    }
    func testSamplesDoNotMatchTheEpisode() {
        let value = manifest(["Show.S01E02.sample.mkv", "Show.S01E02.mkv", "Show.S01E01.mkv"])
        XCTAssertEqual(value.filesForEpisode(target).map(\.name), ["Show.S01E02.mkv"])
    }
}
