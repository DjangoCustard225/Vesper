//
//  LineFramer.swift
//  DownloadEngine
//
//  Incrementally splits a byte stream into lines. NNTP is line-oriented and CRLF-terminated;
//  this buffers partial reads and yields complete lines (with the trailing CRLF/LF removed).
//

import Foundation

struct LineFramer {
    private var buffer = Data()

    /// Append freshly-read bytes and return every complete line now available.
    /// A trailing partial line (no terminator yet) stays buffered for the next append.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        return drainCompleteLines()
    }

    /// Bytes buffered that haven't been terminated by a newline yet.
    var pending: Data { buffer }
    var pendingCount: Int { buffer.count }

    /// Scan the buffer once, emitting each complete line, then drop the whole consumed prefix in a
    /// single copy. (Compacting after every line is O(n²) over a large article body.)
    private mutating func drainCompleteLines() -> [Data] {
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D
        var lines: [Data] = []
        var consumedUpTo = 0

        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            let n = bytes.count
            var i = 0
            while i < n {
                if bytes[i] == lf {
                    var end = i
                    if end > lineStart, bytes[end - 1] == cr { end -= 1 }
                    lines.append(Data(bytes[lineStart..<end]))
                    lineStart = i + 1
                }
                i += 1
            }
            consumedUpTo = lineStart
        }

        // Keep only the unterminated tail; done once instead of per line.
        if consumedUpTo > 0 {
            buffer =
                consumedUpTo < buffer.count
                ? Data(buffer[(buffer.startIndex + consumedUpTo)...])
                : Data()
        }
        return lines
    }
}
