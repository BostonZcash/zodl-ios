//
//  NetworkErrorTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers `NetworkError.allowsRetry` / `.message` (Utils/Network.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct NetworkErrorTests {
    @Test(arguments: [
        URLError.Code.timedOut,
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotConnectToHost
    ])
    func transportRetryableCodesAllowRetry(_ code: URLError.Code) {
        #expect(NetworkError.transport(URLError(code)).allowsRetry)
    }

    @Test(arguments: [
        URLError.Code.badURL,
        .cancelled,
        .unsupportedURL,
        .userAuthenticationRequired
    ])
    func transportNonRetryableCodesDoNotAllowRetry(_ code: URLError.Code) {
        #expect(!NetworkError.transport(URLError(code)).allowsRetry)
    }

    @Test func unknownErrorDoesNotAllowRetry() {
        #expect(!NetworkError.unknown(SampleError.boom).allowsRetry)
    }

    @Test func messageReflectsCase() {
        #expect(NetworkError.httpStatus(code: 404).message == "404")
        #expect(NetworkError.unknown(SampleError.boom).message == "unknown")
        #expect(!NetworkError.transport(URLError(.timedOut)).message.isEmpty)
    }

    // See docs/testing/coverage-uplift-plan.md §6.4.
    // Intended: client errors (4xx) must NOT be retried. The current implementation
    // `!(501...504).contains(code)` retries them, so these intended-behaviour assertions
    // are recorded as known issues until the bug is fixed.
    @Test func clientErrorsShouldNotRetry() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.4: 4xx HTTP statuses are incorrectly retryable") {
            #expect(NetworkError.httpStatus(code: 400).allowsRetry == false)
            #expect(NetworkError.httpStatus(code: 404).allowsRetry == false)
        }
    }

    // Intended: server errors (5xx) should be retried. The current implementation excludes 501...504.
    @Test func serverErrorsShouldRetry() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.4: 502/503 server errors are incorrectly non-retryable") {
            #expect(NetworkError.httpStatus(code: 502).allowsRetry == true)
            #expect(NetworkError.httpStatus(code: 503).allowsRetry == true)
        }
    }
}

private enum SampleError: Error {
    case boom
}
