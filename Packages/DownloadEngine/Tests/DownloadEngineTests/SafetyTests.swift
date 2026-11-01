import Testing
import Foundation
@testable import DownloadEngine

/// Guards for untrusted-input handling and the transient-vs-permanent scheduler contract.
struct SafetyTests {
    // MARK: - Filename sanitization (path traversal / degenerate names)

    @Test func sanitizeRejectsTraversal() {
        #expect(FileAssembler.sanitized("..") == "file")
        #expect(FileAssembler.sanitized(".") == "file")
        #expect(FileAssembler.sanitized("") == "file")
        #expect(FileAssembler.sanitized("../../etc/passwd") == "passwd")
        #expect(FileAssembler.sanitized("/absolute/path.rar") == "path.rar")
    }

    @Test func sanitizeStripsIllegalCharactersAndLeadingDots() {
        let cleaned = FileAssembler.sanitized("b:c*?.bin")
        #expect(!cleaned.contains(":") && !cleaned.contains("*") && !cleaned.contains("?"))
        #expect(!cleaned.contains("/"))
        #expect(!FileAssembler.sanitized(".hidden").hasPrefix("."))
        // A normal name is preserved.
        #expect(FileAssembler.sanitized("holiday-photos.zip") == "holiday-photos.zip")
    }

    // MARK: - Message-ID validation (command injection / desync)

    @Test func messageIDRejectsControlAndBrackets() {
        #expect(NNTPConnection.isValidMessageID("abc123@news.example.com"))
        #expect(!NNTPConnection.isValidMessageID("abc\r\nDELE"))  // CRLF injection
        #expect(!NNTPConnection.isValidMessageID("abc def"))  // space
        #expect(!NNTPConnection.isValidMessageID("a<b>c"))  // brackets
        #expect(!NNTPConnection.isValidMessageID(""))  // empty
    }

    // MARK: - Scheduler requeue (transient retry budget)

    @Test func schedulerRequeuesUpToBudgetThenStops() async {
        let file = FileSpec(
            id: "f", filename: "a.bin", groups: [],
            segments: [SegmentSpec(id: "s1", messageID: "m1", byteCount: 10, number: 1)])
        let scheduler = SegmentScheduler(files: [file], resolved: [])
        let item = await scheduler.next()
        let unwrapped = try! #require(item)
        // Three requeues succeed; the fourth is refused so a dead segment can't loop forever.
        #expect(await scheduler.requeue(unwrapped) == true)
        #expect(await scheduler.requeue(unwrapped) == true)
        #expect(await scheduler.requeue(unwrapped) == true)
        #expect(await scheduler.requeue(unwrapped) == false)
    }
}

/// The on-disk name must come from the yEnc header, not the NZB subject: an unquoted subject
/// ("S. T. Abby - Lana Myers.epub (1/0)") parses down to "S.", which makes PAR2 verify report
/// every slice of a perfectly good file as missing.
struct AssemblerNamingTests {
    @Test func finalizePrefersTheYEncNameOverTheSubjectGuess() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assembler-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let assembler = FileAssembler(directory: dir)
        let payload = Data("book".utf8)
        try await assembler.prepare(fileID: "f1", filename: "S.", totalBytes: payload.count)
        try await assembler.write(
            fileID: "f1", data: payload, at: 0,
            declaredFileSize: payload.count, declaredName: "A Real Book.epub")
        let url = try await assembler.finalize(fileID: "f1")

        #expect(url?.lastPathComponent == "A Real Book.epub")
        #expect(try Data(contentsOf: #require(url)) == payload)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("S.").path))
    }

    @Test func finalizeFallsBackToTheSubjectNameWhenTheHeaderHasNone() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assembler-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let assembler = FileAssembler(directory: dir)
        try await assembler.prepare(fileID: "f1", filename: "fallback.bin", totalBytes: 4)
        try await assembler.write(fileID: "f1", data: Data([1, 2, 3, 4]), at: 0, declaredFileSize: 4)
        let url = try await assembler.finalize(fileID: "f1")

        #expect(url?.lastPathComponent == "fallback.bin")
    }
}

/// Which of the two candidate names wins. The yEnc header is normally right, but an obfuscated
/// post puts a hash there — and an extension-less ".par2" breaks PAR2 discovery entirely.
struct NamePreferenceTests {
    @Test func headerNameWinsWhenItLooksLikeAFilename() {
        #expect(FileAssembler.betterName(declared: "A Real Book.epub", fallback: "S.") == "A Real Book.epub")
        #expect(
            FileAssembler.betterName(declared: "x.part01.rar", fallback: "x.part01.rar") == "x.part01.rar")
    }

    @Test func fallbackWinsWhenTheHeaderNameHasNoExtension() {
        #expect(
            FileAssembler.betterName(
                declared: "3osby74f5W5rYwETGFUetpuHxfkS",
                fallback: "Book.vol00+01.par2") == "Book.vol00+01.par2")
    }

    @Test func headerNameStillUsedWhenNeitherHasAnExtension() {
        #expect(FileAssembler.betterName(declared: "3osby74f5W5rY", fallback: "S") == "3osby74f5W5rY")
        #expect(FileAssembler.betterName(declared: nil, fallback: "only-option.bin") == "only-option.bin")
    }
}
