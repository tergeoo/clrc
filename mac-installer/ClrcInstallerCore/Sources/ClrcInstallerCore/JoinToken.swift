import Foundation

public struct JoinPayload: Codable, Equatable, Sendable {
    public let relay: String; public let secret: String; public let tskey: String; public let exp: Int64
    public init(relay: String, secret: String, tskey: String, exp: Int64) {
        self.relay = relay; self.secret = secret; self.tskey = tskey; self.exp = exp
    }
}

public struct PairPayload: Codable, Equatable, Sendable {
    public let relay: String; public let pw: String; public let exp: Int64
    public init(relay: String, pw: String, exp: Int64) {
        self.relay = relay; self.pw = pw; self.exp = exp
    }
}

public enum JoinToken {
    private static let version = 1

    public static func encodeJoin(_ p: JoinPayload) -> String { encode(verb: "join", p) }
    public static func encodePair(_ p: PairPayload) -> String { encode(verb: "pair", p) }

    public static func decodeJoin(_ url: String, now: Int64) throws -> JoinPayload {
        let p: JoinPayload = try decode(verb: "join", url)
        if p.exp <= now { throw TokenError.expired }
        return p
    }
    public static func decodePair(_ url: String, now: Int64) throws -> PairPayload {
        let p: PairPayload = try decode(verb: "pair", url)
        if p.exp <= now { throw TokenError.expired }
        return p
    }

    private static func encode<T: Encodable>(verb: String, _ payload: T) -> String {
        let json = try! JSONEncoder().encode(payload)
        return "clrc://\(verb)?v=\(version)&d=\(base64url(json))"
    }

    private static func decode<T: Decodable>(verb: String, _ url: String) throws -> T {
        guard let comps = URLComponents(string: url),
              comps.scheme == "clrc", comps.host == verb,
              let items = comps.queryItems,
              let vStr = items.first(where: { $0.name == "v" })?.value,
              let v = Int(vStr),
              let d = items.first(where: { $0.name == "d" })?.value
        else { throw TokenError.malformed }
        guard v == version else { throw TokenError.unsupportedVersion(v) }
        guard let data = base64urlDecode(d) else { throw TokenError.malformed }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TokenError.malformed }
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
