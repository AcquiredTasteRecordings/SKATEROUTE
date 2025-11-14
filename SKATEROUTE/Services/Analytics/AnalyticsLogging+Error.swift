// Services/Analytics/AnalyticsLogging+Error.swift
// Convenience helpers for logging events alongside optional error diagnostics.

import Foundation

public extension AnalyticsLogging {
    /// Default implementation that preserves existing analytics behaviour while allowing
    /// call sites to attach an error for local diagnostics.
    func log(event: AnalyticsEvent, error: Error?) {
        log(event)
        #if DEBUG
        if let error {
            // In DEBUG builds surface the error via os_log through the analytics event category for visibility.
            // Production sinks already receive the event, and errors are handled via OSLog in call sites.
            let nsError = error as NSError
            let message = "[Analytics] \(event.name) error: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)"
            NSLog("%@", message)
        }
        #endif
    }
}

