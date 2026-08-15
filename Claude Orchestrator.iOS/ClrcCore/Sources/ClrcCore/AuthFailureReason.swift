import Foundation

/// Classifies an HTTP status code returned by the relay's auth endpoints
/// (`/auth/login`, `/auth/refresh`) into the reason a request failed.
///
/// Kept free of `URLSession`/`HTTPURLResponse` so the status-code-to-reason
/// mapping is a pure function that can be unit tested directly — callers
/// pass the raw `Int` from `HTTPURLResponse.statusCode` once they already
/// know a response was received (a transport failure, where no response
/// exists at all, is a separate case the caller handles before reaching
/// this mapping).
public enum AuthFailureReason: Equatable {
    /// The server rejected the credentials or token outright (401).
    case unauthorized
    /// The relay's per-IP login limiter rejected the attempt (429).
    case rateLimited
    /// Any other non-success status — the server is reachable but answered
    /// with an error.
    case serverError(statusCode: Int)

    public init(statusCode: Int) {
        switch statusCode {
        case 401:
            self = .unauthorized
        case 429:
            self = .rateLimited
        default:
            self = .serverError(statusCode: statusCode)
        }
    }
}
