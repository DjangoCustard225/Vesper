import Testing
import Foundation
@testable import DownloadEngine

struct RateLimiterTests {
    @Test func unlimitedWhenZero() {
        #expect(RateLimiter(bytesPerSecond: 0) == nil)
        #expect(RateLimiter(bytesPerSecond: -5) == nil)
    }

    @Test func throttlesToApproximatelyTheConfiguredRate() async throws {
        // 1 MB/s limiter; consume ~3 MB beyond the initial 1 MB burst → expect ≳ 2s.
        let rate = 1_000_000
        let limiter = try #require(RateLimiter(bytesPerSecond: rate))
        let clock = ContinuousClock()
        let start = clock.now
        // Initial bucket holds ~1s of budget; take 4s worth in chunks.
        for _ in 0..<64 {
            await limiter.take(62_500)  // 64 * 62_500 = 4 MB total
        }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        // 4 MB at 1 MB/s, minus the 1 MB initial burst ⇒ ~3s. Allow generous slack for CI timing.
        #expect(seconds >= 2.0)
        #expect(seconds <= 6.0)
    }
}
