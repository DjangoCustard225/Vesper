//
//  ServerProbe.swift
//  DownloadEngine
//
//  A lightweight "can we connect + authenticate?" check for the server-setup UI.
//

import Foundation

public enum ServerProbe {
    /// Open, authenticate, and immediately close a connection. Returns nil on success or a
    /// human-readable reason on failure.
    public static func test(_ config: ServerConfig) async -> String? {
        let connection = NNTPConnection(config: config)
        do {
            try await connection.open()
            await connection.close()
            return nil
        } catch let error as NNTPError {
            await connection.close()
            switch error {
            case .authenticationFailed:
                return "The server rejected the login. Check the username and password."
            case .badGreeting: return "The server answered with something that isn't NNTP."
            case .connectionFailed(let detail): return "Couldn't connect: \(detail)"
            case .timeout: return "The connection timed out."
            default: return "The connection failed (\(error))."
            }
        } catch {
            await connection.close()
            return error.localizedDescription
        }
    }
}
