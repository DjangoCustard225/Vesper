import Foundation
import Observation

@MainActor @Observable final class HTTPDownloadOptions {
    static let shared = HTTPDownloadOptions()
    var parallel: Bool { didSet { UserDefaults.standard.set(parallel, forKey: "httpParallelDownloads") } }
    private init() { parallel = UserDefaults.standard.bool(forKey: "httpParallelDownloads") }
}
