import Testing
import Foundation
@testable import DownloadEngine

struct NNTPProtocolTests {
    @Test func parsesStatusLine() {
        let s = NNTPStatus(string: "222 0 <abc@example> body follows")
        #expect(s?.code == 222)
        #expect(s?.isSuccess == true)
        #expect(s?.text == "0 <abc@example> body follows")
    }

    @Test func classifiesErrorCodes() {
        #expect(NNTPStatus(string: "430 No such article")?.isError == true)
        #expect(NNTPStatus(string: "381 password required")?.isContinue == true)
        #expect(NNTPStatus(string: "281 authentication accepted")?.isSuccess == true)
    }

    @Test func rejectsNonNumeric() {
        #expect(NNTPStatus(string: "not a status") == nil)
    }

    @Test func terminatorDetected() {
        #expect(NNTP.processBodyLine(Data(".".utf8)) == .terminator)
    }

    @Test func dotUnstuffing() {
        #expect(NNTP.processBodyLine(Data("..foo".utf8)) == .content(Data(".foo".utf8)))
        #expect(NNTP.processBodyLine(Data("normal".utf8)) == .content(Data("normal".utf8)))
        // A real "." inside text (not first char) is untouched.
        #expect(NNTP.processBodyLine(Data("a.b".utf8)) == .content(Data("a.b".utf8)))
    }
}
