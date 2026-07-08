import Testing
import Foundation
@testable import ClrcCore

@Test func decodesValidPairLink() throws {
    // {"relay":"http://100.1.2.3:8080","pw":"pw","exp":5000000000}
    let json = "{\"relay\":\"http://100.1.2.3:8080\",\"pw\":\"pw\",\"exp\":5000000000}"
    let d = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let info = try PairLink.decode("clrc://pair?v=1&d=\(d)", now: 1)
    #expect(info == PairInfo(relay: "http://100.1.2.3:8080", password: "pw"))
}

@Test func rejectsExpiredAndMalformed() {
    let json = "{\"relay\":\"x\",\"pw\":\"p\",\"exp\":100}"
    let d = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(throws: PairLinkError.expired) { try PairLink.decode("clrc://pair?v=1&d=\(d)", now: 200) }
    #expect(throws: PairLinkError.malformed) { try PairLink.decode("clrc://pair?v=1&d=@@@", now: 0) }
}
