import Foundation

public enum TokenError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case expired
}

public enum TailscaleError: Error, Equatable {
    case authFailed
    case badIP(String)
}

public enum AgentError: Error, Equatable {
    case configFailed
    case startFailed
}
