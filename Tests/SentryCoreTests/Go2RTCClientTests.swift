import Foundation
import Testing
@testable import SentryCore

struct PanReplyTests {
    private let json = #"{"ret":0,"angle":31,"elevation":1}"#

    private func reply(hex: String, text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hex": hex, "reply": text])
    }

    @Test func readsHexWithCommandPrefixAndTrailingNul() throws {
        // The patched go2rtc returns the camera bytes: 4-byte command id, JSON, sometimes a NUL.
        let hex = "00000113" + json.utf8.map { String(format: "%02x", $0) }.joined() + "00"
        #expect(PanReply.parse(try reply(hex: hex, text: "")) == PanReply(ret: 0, angle: 31, elevation: 1, noReply: false))
    }

    @Test func fallsBackToTheReplyText() throws {
        let parsed = PanReply.parse(try reply(hex: "", text: "\u{0}\u{0}\u{1}\u{13}" + json))
        #expect(parsed == PanReply(ret: 0, angle: 31, elevation: 1, noReply: false))
    }

    @Test func emptyFieldsMeanTheCameraDidNotAnswer() throws {
        #expect(PanReply.parse(try reply(hex: "", text: "")).noReply)
    }

    @Test func nonJSONBodyIsTreatedAsNoReply() {
        #expect(PanReply.parse(Data("Unauthorized".utf8)).noReply)
    }

    @Test func replyWithoutPositionIsKeptButEmpty() throws {
        let parsed = PanReply.parse(try reply(hex: "", text: "garbage without braces"))
        #expect(parsed == PanReply(noReply: false))
    }
}

struct Go2RTCClientTests {
    @Test func webSocketRequestCarriesTheLogin() throws {
        let client = Go2RTCClient(config: ServerConfig(host: "192.0.2.10", port: 1984, username: "user", password: "pass"))
        defer { client.invalidate() }
        let request = try client.webSocketRequest(stream: "front door")

        #expect(request.url?.absoluteString == "ws://192.0.2.10:1984/api/ws?src=front%20door")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:pass".utf8).base64EncodedString())
    }

    @Test func plusInAStreamNameIsEncoded() throws {
        let client = Go2RTCClient(config: ServerConfig(host: "192.0.2.10", port: 1984, username: "", password: ""))
        defer { client.invalidate() }
        #expect(try client.webSocketRequest(stream: "cam+1").url?.query == "src=cam%2B1")
    }

    @Test func noLoginMeansNoAuthorizationHeader() throws {
        let client = Go2RTCClient(config: ServerConfig(host: "192.0.2.10", port: 1984, username: "", password: ""))
        defer { client.invalidate() }
        #expect(try client.webSocketRequest(stream: "cam").value(forHTTPHeaderField: "Authorization") == nil)
    }
}
