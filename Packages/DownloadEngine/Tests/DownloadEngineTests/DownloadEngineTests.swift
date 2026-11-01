import Testing
@testable import DownloadEngine

@Test func engineVersionIsSet() {
    #expect(DownloadEngine.version == "0.1.0")
}
