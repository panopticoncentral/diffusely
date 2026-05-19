import Testing
import Foundation
@testable import Diffusely

struct SyncRetryPolicyTests {

    @Test func transientURLErrorsClassifyAsTransient() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .resourceUnavailable
        ]
        for code in codes {
            #expect(classifySyncError(URLError(code)) == .transient)
        }
    }

    @Test func decodingErrorClassifiesAsFatal() {
        let err = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(classifySyncError(err) == .fatal)
    }

    @Test func genericErrorClassifiesAsFatal() {
        let err = NSError(domain: "x", code: 1)
        #expect(classifySyncError(err) == .fatal)
    }

    @Test func badServerResponseURLErrorIsFatal() {
        #expect(classifySyncError(URLError(.badServerResponse)) == .fatal)
    }

    @Test func cancellationClassifiesAsCancellation() {
        #expect(classifySyncError(CancellationError()) == .cancellation)
    }

    @Test func backoffScheduleMatchesSpec() {
        #expect(syncRetryDelay(forAttempt: 1) == 5)
        #expect(syncRetryDelay(forAttempt: 2) == 15)
        #expect(syncRetryDelay(forAttempt: 3) == 45)
        #expect(syncRetryDelay(forAttempt: 4) == 60)
        #expect(syncRetryDelay(forAttempt: 10) == 60)
        #expect(syncRetryDelay(forAttempt: 0) == 5)
    }
}
