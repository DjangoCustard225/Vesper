//
//  NNTPError.swift
//  DownloadEngine
//

import Foundation

public enum NNTPError: Error, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case timeout
    case cancelled
    /// Server greeting wasn't a 200/201.
    case badGreeting(Int)
    /// AUTHINFO USER/PASS rejected.
    case authenticationFailed(Int)
    /// BODY/ARTICLE returned a 4xx/5xx — typically 430 (no such article / taken down).
    case articleUnavailable(code: Int)
    /// The server closed the stream mid-response.
    case connectionClosed
    case protocolError(String)

    /// Whether a fresh attempt (possibly on a new connection) might succeed.
    var isTransient: Bool {
        switch self {
        case .timeout, .connectionClosed, .connectionFailed, .notConnected: return true
        case .articleUnavailable, .authenticationFailed, .badGreeting, .protocolError, .cancelled:
            return false
        }
    }
}
