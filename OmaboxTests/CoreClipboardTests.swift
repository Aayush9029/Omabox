import CustomDump
import Foundation
import Testing
@testable import Omabox

struct CoreClipboardTests {
    @Test func handlesMessagesSplitAcrossReadsAndSeveralMessagesInOneRead() throws {
        var decoder = ClipboardFrameDecoder()
        expectNoDifference(try decoder.append(Data("{\"type\":\"ready\",".utf8)), [])
        let messages = try decoder.append(Data("\"version\":1}\n{\"type\":\"clipboard\",\"text\":\"hello\\nworld 👋\"}\n".utf8))
        expectNoDifference(messages, [
            ClipboardMessage(type: "ready", version: 1),
            ClipboardMessage(type: "clipboard", text: "hello\nworld 👋")
        ])
    }

    @Test func rejectsOversizedUnterminatedFrames() throws {
        var decoder = ClipboardFrameDecoder()
        #expect(throws: ClipboardProtocolError.self) {
            try decoder.append(Data(repeating: 32, count: ClipboardFrameDecoder.maximumFrameBytes + 1))
        }
    }

    @Test func rejectsUnsupportedAgentProtocolVersions() throws {
        var decoder = ClipboardFrameDecoder()
        #expect(throws: ClipboardProtocolError.self) {
            try decoder.append(Data("{\"type\":\"ready\",\"version\":99}\n".utf8))
        }
    }

    @Test func boundsDecodedTextByUTF8Bytes() throws {
        var decoder = ClipboardFrameDecoder()
        var frame = try JSONEncoder().encode(ClipboardMessage(type: "clipboard", text: String(repeating: "👋", count: 20_000)))
        frame.append(10)
        #expect(throws: ClipboardProtocolError.self) {
            try decoder.append(frame)
        }
    }

    @Test func rejectsUnrecognizedCommandsFromTheGuest() throws {
        var decoder = ClipboardFrameDecoder()
        #expect(throws: ClipboardProtocolError.self) {
            try decoder.append(Data("{\"type\":\"execute\",\"text\":\"ignored\"}\n".utf8))
        }
    }
}
