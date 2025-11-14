// Core/Errors.swift
// Shared error taxonomy with localized, user-facing descriptions.
// Clean separation between developer diagnostics and safe UI copy.
// No SDK-specific dependencies beyond Foundation/CoreLocation/StoreKit stubs.

import Foundation
import CoreLocation

// MARK: - AppError

/// Canonical application error used across services and features.
/// Intent: predictable, localized, and easy to render in SwiftUI alerts/sheets.
public enum AppError: Error, Equatable, Sendable {
    // Routing / Navigation
    case routingUnavailable
    case routingTimeout
    case routeNotFound
    case rerouteThrottled

    // Location / Sensors
    case locationDenied
    case locationRestricted
    case locationTemporarilyUnavailable
    case motionUnavailable
    case motionPermissionDenied

    // Networking / Storage
    case offline
    case network(underlying: URLError.Code?)
    case server(status: Int)
    case decodingFailed
    case encodingFailed
    case diskIO

    // Content / Validation
    case invalidInput(field: String?)
    case contentRejected(reason: String?) // policy/UGC moderation
    case notFound(entity: String?)

    // Entitlements / Purchases
    case purchaseNotAllowed
    case productUnavailable
    case purchaseCancelled
    case productUnavailable
    case purchaseFailed
    case restoreFailed
    case productUnavailable
    case notEntitled(feature: ProFeature)

    // Media
    case cameraUnavailable
    case microphonePermissionDenied
    case exportFailed

    // Offline packs / tiles
    case tilepackPlanningFailed
    case tilepackMissing

    // Hazards / Spots
    case hazardSubmissionFailed
    case spotSubmissionFailed

    // Referrals
    case referralInvalid
    case referralConsumed

    // Misc
    case unknown
}

// MARK: - LocalizedError

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        // Routing
        case .routingUnavailable:            return NSLocalizedString("Routing isn’t available right now.", comment: "error")
        case .routingTimeout:                return NSLocalizedString("Routing took too long.", comment: "error")
        case .routeNotFound:                 return NSLocalizedString("No skateable route found.", comment: "error")
        case .rerouteThrottled:              return NSLocalizedString("Hold up—rerouting too fast.", comment: "error")

        // Location
        case .locationDenied:                return NSLocalizedString("Location access is denied.", comment: "error")
        case .locationRestricted:            return NSLocalizedString("Location access is restricted on this device.", comment: "error")
        case .locationTemporarilyUnavailable:return NSLocalizedString("Can’t get a reliable GPS fix.", comment: "error")
        case .motionUnavailable:             return NSLocalizedString("Motion sensors aren’t available.", comment: "error")
        case .motionPermissionDenied:        return NSLocalizedString("Motion access is denied.", comment: "error")

        // Networking / Storage
        case .offline:                       return NSLocalizedString("You appear to be offline.", comment: "error")
        case .network:                       return NSLocalizedString("The network request failed.", comment: "error")
        case .server:                        return NSLocalizedString("The server returned an error.", comment: "error")
        case .decodingFailed:                return NSLocalizedString("We couldn’t read the response.", comment: "error")
        case .encodingFailed:                return NSLocalizedString("We couldn’t prepare the request.", comment: "error")
        case .diskIO:                        return NSLocalizedString("There was a problem saving data.", comment: "error")

        // Content / Validation
        case .invalidInput(let field):
            if let field { return String(format: NSLocalizedString("“%@” looks invalid.", comment: "error"), field) }
            return NSLocalizedString("Some input looks invalid.", comment: "error")
        case .contentRejected:
            return NSLocalizedString("That content violates community rules.", comment: "error")
        case .notFound(let entity):
            if let entity { return String(format: NSLocalizedString("%@ not found.", comment: "error"), entity) }
            return NSLocalizedString("Not found.", comment: "error")

        // Entitlements
        case .purchaseNotAllowed:            return NSLocalizedString("Purchases aren’t allowed on this device.", comment: "error")
        case .productUnavailable:            return NSLocalizedString("That product isn’t available right now.", comment: "error")
        case .purchaseCancelled:             return NSLocalizedString("Purchase was cancelled.", comment: "error")
        case .productUnavailable:            return NSLocalizedString("That product isn’t available right now.", comment: "error")
        case .purchaseFailed:                return NSLocalizedString("Purchase failed.", comment: "error")
        case .productUnavailable:            return NSLocalizedString("That item isn’t available right now.", comment: "error")
        case .restoreFailed:                 return NSLocalizedString("Restore failed.", comment: "error")
        case .productUnavailable:            return NSLocalizedString("That product isn’t available right now.", comment: "error")
        case .notEntitled(let feature):
            return String(format: NSLocalizedString("This feature requires %@.", comment: "error"), feature.displayName)

        // Media
        case .cameraUnavailable:             return NSLocalizedString("Camera isn’t available.", comment: "error")
        case .microphonePermissionDenied:    return NSLocalizedString("Microphone access is denied.", comment: "error")
        case .exportFailed:                  return NSLocalizedString("Export failed.", comment: "error")

        // Offline packs
        case .tilepackPlanningFailed:        return NSLocalizedString("Couldn’t prepare offline tiles.", comment: "error")
        case .tilepackMissing:               return NSLocalizedString("Offline tiles are missing.", comment: "error")

        // Hazards / Spots
        case .hazardSubmissionFailed:        return NSLocalizedString("Couldn’t submit that hazard.", comment: "error")
        case .spotSubmissionFailed:          return NSLocalizedString("Couldn’t submit that spot.", comment: "error")

        // Referrals
        case .referralInvalid:               return NSLocalizedString("That referral link isn’t valid.", comment: "error")
        case .referralConsumed:              return NSLocalizedString("That referral link was already used.", comment: "error")

        // Misc
        case .unknown:                       return NSLocalizedString("Something went wrong.", comment: "error")
        }
    }

    public var failureReason: String? {
        switch self {
        case .routingTimeout:                return NSLocalizedString("Maps didn’t respond in time.", comment: "reason")
        case .locationDenied:                return NSLocalizedString("Location permissions are off.", comment: "reason")
        case .offline:                       return NSLocalizedString("No internet connection.", comment: "reason")
        case .server(let status):            return String(format: NSLocalizedString("Server returned status %d.", comment: "reason"), status)
        case .network(let code):
            if let code { return String(format: NSLocalizedString("Network error: %@.", comment: "reason"), code.debugName) }
            return NSLocalizedString("A network error occurred.", comment: "reason")
        case .productUnavailable:            return NSLocalizedString("The item is temporarily unavailable.", comment: "reason")
        case .notEntitled(let feature):      return String(format: NSLocalizedString("%@ is a Pro feature.", comment: "reason"), feature.displayName)
        case .productUnavailable:            return NSLocalizedString("The App Store isn’t currently listing this item.", comment: "reason")
        default: return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .routingUnavailable, .routingTimeout, .routeNotFound:
            return NSLocalizedString("Try another mode or move a block to improve GPS.", comment: "suggestion")
        case .locationDenied:
            return NSLocalizedString("Open Settings → Privacy → Location Services to enable access.", comment: "suggestion")
        case .motionPermissionDenied:
            return NSLocalizedString("Open Settings → Privacy → Motion & Fitness to enable access.", comment: "suggestion")
        case .offline, .network:
            return NSLocalizedString("Check your connection and try again.", comment: "suggestion")
        case .purchaseNotAllowed:
            return NSLocalizedString("Purchases may be disabled by Screen Time or your profile.", comment: "suggestion")
        case .productUnavailable:
            return NSLocalizedString("Try again later or choose a different item.", comment: "suggestion")
        case .purchaseFailed, .restoreFailed:
            return NSLocalizedString("Try again in a minute. If it continues, contact support.", comment: "suggestion")
        case .productUnavailable:
            return NSLocalizedString("Pick another product for now or try again later.", comment: "suggestion")
        case .notEntitled:
            return NSLocalizedString("Unlock on the paywall to use this feature.", comment: "suggestion")
        case .tilepackMissing:
            return NSLocalizedString("Recreate the offline pack for this route.", comment: "suggestion")
        case .contentRejected:
            return NSLocalizedString("Edit the text and remove disallowed words.", comment: "suggestion")
        default:
            return nil
        }
    }

    public var helpAnchor: String? { nil }
}

// MARK: - CustomNSError (stable domain/codes)

extension AppError: CustomNSError {
    public static var errorDomain: String { "com.skateroute.app" }

    public var errorCode: Int {
        switch self {
        // Assign stable codes: 1xx routing, 2xx location, 3xx network, 4xx validation, 5xx purchase, 6xx media, 7xx offline, 8xx domain models, 9xx misc.
        case .routingUnavailable:            return 101
        case .routingTimeout:                return 102
        case .routeNotFound:                 return 103
        case .rerouteThrottled:              return 104

        case .locationDenied:                return 201
        case .locationRestricted:            return 202
        case .locationTemporarilyUnavailable:return 203
        case .motionUnavailable:             return 204
        case .motionPermissionDenied:        return 205

        case .offline:                       return 301
        case .network:                       return 302
        case .server:                        return 303
        case .decodingFailed:                return 304
        case .encodingFailed:                return 305
        case .diskIO:                        return 306

        case .invalidInput:                  return 401
        case .contentRejected:               return 402
        case .notFound:                      return 404

        case .purchaseNotAllowed:            return 501
        case .purchaseCancelled:             return 502
        case .purchaseFailed:                return 503
        case .restoreFailed:                 return 504
        case .notEntitled:                   return 505
        case .productUnavailable:            return 506

        case .cameraUnavailable:             return 601
        case .microphonePermissionDenied:    return 602
        case .exportFailed:                  return 603

        case .tilepackPlanningFailed:        return 701
        case .tilepackMissing:               return 702

        case .hazardSubmissionFailed:        return 801
        case .spotSubmissionFailed:          return 802

        case .referralInvalid:               return 851
        case .referralConsumed:              return 852

        case .unknown:                       return 900
        }
    }

    public var errorUserInfo: [String : Any] {
        var info: [String: Any] = [:]
        if let desc = errorDescription { info[NSLocalizedDescriptionKey] = desc }
        if let reason = failureReason { info[NSLocalizedFailureReasonErrorKey] = reason }
        if let recovery = recoverySuggestion { info[NSLocalizedRecoverySuggestionErrorKey] = recovery }
        return info
    }
}

// MARK: - Presentation Model

/// SwiftUI-friendly wrapper for alerts/sheets.
public struct UXError: Identifiable, Hashable, Sendable {
    public enum Severity: Sendable { case info, warning, error }
    public let id: String
    public let title: String
    public let message: String
    public let recovery: String?
    public let severity: Severity

    public init(id: String = UUID().uuidString, title: String, message: String, recovery: String?, severity: Severity) {
        self.id = id
        self.title = title
        self.message = message
        self.recovery = recovery
        self.severity = severity
    }
}

public extension UXError {
    static func from(_ err: AppError) -> UXError {
        let title: String = {
            switch err {
            case .notEntitled: return NSLocalizedString("Locked Feature", comment: "title")
            case .productUnavailable: return NSLocalizedString("Store Unavailable", comment: "title")
            case .offline, .network: return NSLocalizedString("Network Issue", comment: "title")
            case .locationDenied, .motionPermissionDenied: return NSLocalizedString("Permissions Needed", comment: "title")
            default: return NSLocalizedString("Something Went Wrong", comment: "title")
            }
        }()
        return UXError(
            title: title,
            message: err.errorDescription ?? NSLocalizedString("An error occurred.", comment: "msg"),
            recovery: err.recoverySuggestion,
            severity: .error
        )
    }
}

// MARK: - Retriability / User-facing hints

public extension AppError {
    /// Whether retrying the operation might succeed soon (for backoff logic).
    var isRetriable: Bool {
        switch self {
        case .routingTimeout, .routingUnavailable, .locationTemporarilyUnavailable,
             .network, .server, .offline, .productUnavailable, .exportFailed, .tilepackPlanningFailed,
             .hazardSubmissionFailed, .spotSubmissionFailed:
            return true
        default:
            return false
        }
    }

    /// Should we surface this to the user (vs. log silently)?
    var isUserFacing: Bool {
        switch self {
        case .decodingFailed, .encodingFailed, .diskIO:
            return false
        default:
            return true
        }
    }
}

// MARK: - Bridging helpers (map platform errors → AppError)

public enum ErrorBridge {
    public static func from(_ error: Error) -> AppError {
        // URLError
        if let e = error as? URLError {
            if e.code == .notConnectedToInternet { return .offline }
            return .network(underlying: e.code)
        }
        // CoreLocation (coarse mapping)
        if let e = error as? CLError {
            switch e.code {
            case .denied:       return .locationDenied
            case .restricted:   return .locationRestricted
            default:            return .locationTemporarilyUnavailable
            }
        }
        // SKError without importing StoreKit (stringly-typed fallback)
        let ns = error as NSError
        if ns.domain == "SKErrorDomain" {
            switch ns.code {
            case 0:  return .unknown
            case 1:  return .purchaseCancelled
            case 2:  return .purchaseFailed
            case 3:  return .productUnavailable
            case 4:  return .purchaseNotAllowed
            case 5:  return .productUnavailable
            default: return .purchaseFailed
            }
        }
        return .unknown
    }
}

// MARK: - Convenience

public extension URLError.Code {
    var debugName: String {
        switch self {
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .timedOut: return "timedOut"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .networkConnectionLost: return "networkConnectionLost"
        default: return "\(rawValue)"
        }
    }
}


