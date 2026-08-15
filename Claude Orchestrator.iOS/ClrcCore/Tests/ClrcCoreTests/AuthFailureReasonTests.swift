import Testing
@testable import ClrcCore

@Suite("AuthFailureReason")
struct AuthFailureReasonTests {

    @Test("401 maps to unauthorized")
    func unauthorized() {
        #expect(AuthFailureReason(statusCode: 401) == .unauthorized)
    }

    @Test("429 maps to rateLimited")
    func rateLimited() {
        #expect(AuthFailureReason(statusCode: 429) == .rateLimited)
    }

    @Test("other 4xx codes map to serverError with the code preserved")
    func otherClientErrors() {
        #expect(AuthFailureReason(statusCode: 400) == .serverError(statusCode: 400))
        #expect(AuthFailureReason(statusCode: 403) == .serverError(statusCode: 403))
        #expect(AuthFailureReason(statusCode: 404) == .serverError(statusCode: 404))
    }

    @Test("5xx codes map to serverError with the code preserved")
    func serverErrors() {
        #expect(AuthFailureReason(statusCode: 500) == .serverError(statusCode: 500))
        #expect(AuthFailureReason(statusCode: 503) == .serverError(statusCode: 503))
    }
}
