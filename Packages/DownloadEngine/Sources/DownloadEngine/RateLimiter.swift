//
//  RateLimiter.swift
//  DownloadEngine
//
//  Aggregate throughput limiter shared by all of a job's connections, so the configured cap
//  throttles *total* download speed. Instead of a mutable token count (which mis-accounts when
//  several connections await concurrently — each waking writer erased the others' debt), each
//  request atomically reserves a contiguous slot on a shared timeline cursor and sleeps until its
//  slot begins. Reserving before sleeping makes concurrent `take(_:)` calls queue correctly.
//

import Foundation

actor RateLimiter {
    private let bytesPerSecond: Double
    /// How far the reservation cursor may sit behind "now" — i.e. the burst allowance (~1 second).
    private let burstWindow: Duration
    /// The instant the next reserved slot begins; advances by each request's transfer time.
    private var cursor: ContinuousClock.Instant?

    /// nil when unlimited (cap <= 0).
    init?(bytesPerSecond: Int) {
        guard bytesPerSecond > 0 else { return nil }
        self.bytesPerSecond = Double(bytesPerSecond)
        self.burstWindow = .seconds(1)
    }

    /// Consume `n` bytes of budget, sleeping until this request's slot on the shared timeline.
    func take(_ n: Int) async {
        guard n > 0 else { return }
        let now = ContinuousClock().now
        let earliest = now - burstWindow

        // Start from the current cursor (or a full bucket on first use), but never let idle credit
        // accumulate beyond the burst window.
        var slotStart = cursor ?? earliest
        if slotStart < earliest { slotStart = earliest }

        let cost = Duration.seconds(Double(n) / bytesPerSecond)
        cursor = slotStart + cost  // reserve atomically before any suspension point

        if slotStart > now {
            try? await Task.sleep(until: slotStart, clock: ContinuousClock())
        }
    }
}
