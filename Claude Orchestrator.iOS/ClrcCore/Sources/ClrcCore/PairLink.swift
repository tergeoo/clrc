import Foundation

/// Decoded payload of a `clrc://pair` scan-to-pair link.
public struct PairInfo: Equatable, Sendable {
    public let relay: String
    public let password: String
    public init(relay: String, password: String) { self.relay = relay; self.password = password }
}

public enum PairLinkError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case expired
}

/// Decodes `clrc://pair?v=1&d=<base64url-json>` links produced by the Mac
/// installer app's `JoinToken.encodePair`, so the iOS app can prefill its
/// login screen from a scanned QR code.
public enum PairLink {
    private struct Payload: Decodable {
        let relay: String
        let pw: String
        let exp: Int64
    }

    public static func decode(_ url: String, now: Int64) throws -> PairInfo {
        guard let comps = URLComponents(string: url),
              comps.scheme == "clrc", comps.host == "pair",
              let items = comps.queryItems,
              let vStr = items.first(where: { $0.name == "v" })?.value, let v = Int(vStr),
              let d = items.first(where: { $0.name == "d" })?.value
        else { throw PairLinkError.malformed }
        guard v == 1 else { throw PairLinkError.unsupportedVersion(v) }
        guard let data = base64urlDecode(d) else { throw PairLinkError.malformed }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw PairLinkError.malformed }
        guard payload.exp > now else { throw PairLinkError.expired }
        return PairInfo(relay: payload.relay, password: payload.pw)
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
