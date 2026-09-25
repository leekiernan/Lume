//
//  TransientNetworkError.swift
//  Lume
//
//  Which transport failures are worth retrying.
//

import Foundation

/// Classifies transport failures for the clients that retry with backoff.
///
/// Only failures a second attempt can plausibly fix count: timeouts, dropped
/// or refused connections, DNS hiccups, a flaky server response. A cancelled
/// request, an unsupported URL or a TLS failure fails the same way every time,
/// so retrying it only adds backoff before the same error — and a cancellation
/// must never be retried at all.
nonisolated enum TransientNetworkError {
    static func isTransient(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return isTransient(urlError)
    }

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .badServerResponse:
            true
        default:
            false
        }
    }
}
