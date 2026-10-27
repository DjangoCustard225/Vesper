import XCTest
@testable import VesperCore

final class AppPreferenceTests: XCTestCase {
    func testRemovedOrUnknownPlayersFallBackToAVPlayer() throws {
        let name = "VesperPreferencesTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for value in ["builtIn", "unknown", "aether"] {
            defaults.set(value, forKey: "preferredPlayer")
            XCTAssertEqual(AppPreferenceStorage.preferredPlayer(in: defaults), .aether)
        }
    }

    func testExternalPreferencesAreNeverReplaced() throws {
        for player in VideoPlayer.externalPlayers {
            let name = "VesperPreferencesTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            AppPreferenceStorage.save(player, in: defaults)
            XCTAssertEqual(AppPreferenceStorage.preferredPlayer(in: defaults), player)
        }
    }

    func testFreshInstallUsesAVPlayerAndIntroTogglePersists() throws {
        let name = "VesperPreferencesTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppPreferenceStorage.preferredPlayer(in: defaults), .aether)
        XCTAssertTrue(AppPreferenceStorage.showSkipIntro(in: defaults))
        AppPreferenceStorage.saveShowSkipIntro(false, in: defaults)
        XCTAssertFalse(AppPreferenceStorage.showSkipIntro(in: defaults))
        AppPreferenceStorage.saveShowSkipIntro(true, in: defaults)
        XCTAssertTrue(AppPreferenceStorage.showSkipIntro(in: defaults))
    }
}
