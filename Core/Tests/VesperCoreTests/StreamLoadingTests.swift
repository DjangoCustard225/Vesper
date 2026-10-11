import XCTest
@testable import VesperCore

@MainActor
final class StreamLoadingTests: XCTestCase {
    private func results(_ name: String) -> StreamResults {
        let source = try! JSONDecoder().decode(StreamSource.self, from: Data("{\"url\":\"https://video.example/\(name)\"}".utf8))
        return StreamResults(options: [StreamOption(addonName: name, source: source)])
    }
    func testOldRetryCannotOverwriteNewerPartialOrFinalResults() async {
        let model = StreamLoadingController()
        var release: CheckedContinuation<Void, Never>?
        var oldUpdate: (@MainActor (StreamResults) -> Void)?
        let old = Task {
            await model.load(key: "video") { update in
                oldUpdate = update
                await withCheckedContinuation { release = $0 }
                update(self.results("old-partial"))
                return self.results("old-final")
            }
        }
        while release == nil { await Task.yield() }
        await model.load(key: "video") { update in
            update(self.results("new-partial"))
            return self.results("new-final")
        }
        oldUpdate?(results("late-update"))
        release?.resume(); await old.value
        XCTAssertEqual(model.result.options.first?.addonName, "new-final")
        XCTAssertFalse(model.loading)
    }
    func testRetryRetainsVisibleSourcesUntilReplacementArrives() async {
        let model = StreamLoadingController()
        await model.load(key: "video") { _ in self.results("existing") }
        await model.load(key: "video") { update in
            XCTAssertEqual(model.result.options.first?.addonName, "existing")
            update(StreamResults(failures: ["Still searching"]))
            XCTAssertEqual(model.result.options.first?.addonName, "existing")
            update(self.results("replacement"))
            XCTAssertEqual(model.result.options.first?.addonName, "replacement")
            return self.results("final")
        }
        XCTAssertEqual(model.result.options.first?.addonName, "final")
    }
    func testDifferentVideoOrProviderContextClearsPreviousSources() async {
        let model = StreamLoadingController()
        await model.load(key: "video:providers1") { _ in self.results("existing") }
        await model.load(key: "video:providers2") { _ in
            XCTAssertTrue(model.result.options.isEmpty)
            return self.results("updated-provider")
        }
        await model.load(key: "other-video:providers2") { _ in
            XCTAssertTrue(model.result.options.isEmpty)
            return StreamResults()
        }
        XCTAssertTrue(model.result.options.isEmpty); XCTAssertFalse(model.loading)
    }
    func testDismissalRejectsUncooperativeProviderCompletion() async {
        let model = StreamLoadingController()
        var release: CheckedContinuation<Void, Never>?
        let task = Task {
            await model.load(key: "video") { update in
                await withCheckedContinuation { release = $0 }
                update(self.results("late")); return self.results("late")
            }
        }
        while release == nil { await Task.yield() }
        model.cancel(); release?.resume(); await task.value
        XCTAssertTrue(model.result.options.isEmpty); XCTAssertFalse(model.loading)
    }
}
