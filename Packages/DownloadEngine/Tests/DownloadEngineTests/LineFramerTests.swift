import Testing
import Foundation
@testable import DownloadEngine

struct LineFramerTests {
    private func lines(_ datas: [Data]) -> [String] {
        datas.map { String(data: $0, encoding: .utf8) ?? "<binary>" }
    }

    @Test func splitsCRLF() {
        var f = LineFramer()
        let out = f.append(Data("abc\r\ndef\r\n".utf8))
        #expect(lines(out) == ["abc", "def"])
        #expect(f.pending.isEmpty)
    }

    @Test func buffersPartialLineAcrossAppends() {
        var f = LineFramer()
        #expect(lines(f.append(Data("hel".utf8))) == [])
        #expect(lines(f.append(Data("lo\r\nwor".utf8))) == ["hello"])
        #expect(lines(f.append(Data("ld\r\n".utf8))) == ["world"])
    }

    @Test func toleratesBareLF() {
        var f = LineFramer()
        #expect(lines(f.append(Data("a\nb\n".utf8))) == ["a", "b"])
    }

    @Test func emptyLinesPreserved() {
        var f = LineFramer()
        #expect(lines(f.append(Data("a\r\n\r\nb\r\n".utf8))) == ["a", "", "b"])
    }

    /// CRLF straddling a read boundary: CR ends one chunk, LF begins the next. The CR must not be
    /// left dangling on the first line's content.
    @Test func crlfSplitAcrossChunks() {
        var f = LineFramer()
        #expect(lines(f.append(Data("abc\r".utf8))) == [])
        #expect(lines(f.append(Data("\ndef\r\n".utf8))) == ["abc", "def"])
        #expect(f.pending.isEmpty)
    }

    /// The single-pass drain must return many lines from one chunk in order, tail buffered.
    @Test func manyLinesOneChunkPlusTail() {
        var f = LineFramer()
        let out = f.append(Data("a\r\nbb\r\nccc\r\ndddd".utf8))
        #expect(lines(out) == ["a", "bb", "ccc"])
        #expect(String(data: f.pending, encoding: .utf8) == "dddd")
        #expect(lines(f.append(Data("\r\n".utf8))) == ["dddd"])
    }

    /// The terminator "." can arrive split from its trailing CRLF across chunks.
    @Test func terminatorSplitAcrossChunks() {
        var f = LineFramer()
        #expect(lines(f.append(Data(".".utf8))) == [])
        let out = f.append(Data("\r\n".utf8))
        #expect(lines(out) == ["."])
    }
}
