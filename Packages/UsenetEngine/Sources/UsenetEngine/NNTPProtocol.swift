//
//  NNTPProtocol.swift
//  DownloadEngine
//
//  Small, pure helpers for the NNTP wire protocol (RFC 3977): status-line parsing and the
//  dot-stuffing rules for multi-line responses. Kept separate from the socket actor so they
//  can be unit-tested without a server.
//

import Foundation

/// A parsed NNTP status response, e.g. "222 0 <id> body follows" → code 222.
struct NNTPStatus: Equatable {
    var code: Int
    var text: String

    /// First digit class: 1 info, 2 success, 3 continue, 4 transient error, 5 permanent error.
    var isSuccess: Bool { (200..<300).contains(code) }
    var isContinue: Bool { (300..<400).contains(code) }
    var isError: Bool { code >= 400 }

    init?(line: Data) {
        guard let s = String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) else {
            return nil
        }
        self.init(string: s)
    }

    init?(string s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3,
            let code = Int(trimmed.prefix(3)),
            trimmed.prefix(3).allSatisfy(\.isNumber)
        else { return nil }
        self.code = code
        self.text = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }
}

/// One line of a multi-line response body after dot-processing.
enum NNTPBodyLine: Equatable {
    /// The terminating "." line — the multi-line block is complete.
    case terminator
    /// A content line with dot-stuffing removed (a leading ".." becomes ".").
    case content(Data)
}

enum NNTP {
    private static let dot: UInt8 = 0x2E  // '.'

    /// Apply RFC 3977 dot-unstuffing / terminator detection to a raw (CRLF-stripped) body line.
    static func processBodyLine(_ line: Data) -> NNTPBodyLine {
        if line.count == 1, line.first == dot {
            return .terminator
        }
        if line.first == dot {
            // Remove exactly one leading stuffing dot.
            return .content(Data(line.dropFirst()))
        }
        return .content(line)
    }

    /// Encode a command for sending (CRLF-terminated, ASCII/Latin-1).
    static func command(_ text: String) -> Data {
        Data((text + "\r\n").utf8)
    }
}
