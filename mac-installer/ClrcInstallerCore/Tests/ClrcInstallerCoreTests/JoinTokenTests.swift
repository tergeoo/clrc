import Testing
import Foundation
@testable import ClrcInstallerCore

@Test func joinRoundTrip() throws {
    let p = JoinPayload(relay: "100.1.2.3:8080", secret: "s3cr3t", tskey: "tskey-abc", exp: 2_000_000_000)
    let url = JoinToken.encodeJoin(p)
    #expect(url.hasPrefix("clrc://join?v=1&d="))
    let back = try JoinToken.decodeJoin(url, now: 1_000_000_000)
    #expect(back == p)
}

@Test func pairRoundTrip() throws {
    let p = PairPayload(relay: "http://100.1.2.3:8080", pw: "hunter2", exp: 2_000_000_000)
    let url = JoinToken.encodePair(p)
    #expect(url.hasPrefix("clrc://pair?v=1&d="))
    #expect(try JoinToken.decodePair(url, now: 1_000_000_000) == p)
}

@Test func expiredRejected() throws {
    let url = JoinToken.encodePair(PairPayload(relay: "http://x:8080", pw: "p", exp: 100))
    #expect(throws: TokenError.expired) { try JoinToken.decodePair(url, now: 200) }
}

@Test func malformedRejected() {
    #expect(throws: TokenError.malformed) { try JoinToken.decodeJoin("clrc://join?v=1&d=@@@", now: 0) }
    #expect(throws: TokenError.malformed) { try JoinToken.decodeJoin("https://nope", now: 0) }
}

@Test func versionMismatchRejected() {
    // hand-craft a v=2 link with a valid-looking payload
    let d = Data("{\"relay\":\"x\",\"pw\":\"p\",\"exp\":9999999999}".utf8)
        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(throws: TokenError.unsupportedVersion(2)) {
        try JoinToken.decodePair("clrc://pair?v=2&d=\(d)", now: 0)
    }
}
