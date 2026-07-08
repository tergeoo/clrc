import Foundation

public enum TokenError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case expired
}
