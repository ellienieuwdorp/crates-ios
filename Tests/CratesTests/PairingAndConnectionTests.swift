import Testing
import Foundation
@testable import CratesIOS

struct PairingAndConnectionTests {
    @Test func buildsCorrectBaseAndPathURLs() {
        let conn = CratesConnection(host: "192.168.1.42", port: 54735, token: "tok")
        #expect(conn.baseURL?.absoluteString == "http://192.168.1.42:54735/resources")
        #expect(conn.url(path: "backend/ping")?.absoluteString == "http://192.168.1.42:54735/resources/backend/ping")
        #expect(conn.url(path: "/stream/42")?.absoluteString == "http://192.168.1.42:54735/resources/stream/42")
        #expect(conn.streamURL(tuneID: 42)?.absoluteString == "http://192.168.1.42:54735/resources/stream/42")
    }

    @Test func authHeaderPresentOnlyWithToken() {
        let paired = CratesConnection(host: "h", port: 1, token: "abc")
        #expect(paired.authHeader == ["Authorization": "Bearer abc"])
        let bare = CratesConnection(host: "h", port: 1, token: "")
        #expect(bare.authHeader.isEmpty)
        #expect(!bare.isConfigured)
        #expect(paired.isConfigured)
    }

    /// The pairing 200 body shape is undocumented (server returns "the token" in an unknown
    /// wrapper); the extractor must be liberal. Pin every shape we can anticipate.
    @Test func extractsTokenFromAnyPlausibleShape() throws {
        #expect(try PairingService.extractToken(from: Data(#""raw-token""#.utf8)) == "raw-token")
        #expect(try PairingService.extractToken(from: Data("bare-token".utf8)) == "bare-token")
        #expect(try PairingService.extractToken(from: Data(#"{"token": "t1"}"#.utf8)) == "t1")
        #expect(try PairingService.extractToken(from: Data(#"{"accessToken": "t2"}"#.utf8)) == "t2")
        #expect(try PairingService.extractToken(from: Data(#"{"access_token": "t3"}"#.utf8)) == "t3")
        #expect(try PairingService.extractToken(from: Data("  padded \n".utf8)) == "padded")
        #expect(throws: (any Error).self) {
            _ = try PairingService.extractToken(from: Data())
        }
    }
}
