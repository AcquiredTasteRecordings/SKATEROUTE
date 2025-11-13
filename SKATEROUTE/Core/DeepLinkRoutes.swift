// Core/DeepLinkRoutes.swift
// Canonical URL schema + parsing/building for SkateRoute.
// Consistent with DownhillNavigatorApp handlers. Pure, testable, and localized where it touches UX.

import Foundation
import CoreLocation

public enum DeepLinkRoutes {
    // MARK: - Canonical scheme + hosts

    public static let appScheme = "skateroute"

    public enum Host: String, CaseIterable {
        case navigate   // plan & present map with src/dst/mode
        case map        // open map on a destination (src optional)
        case referral   // credit a referral/creator code
        case paywall    // show paywall
        case profile    // view a user profile
        case spot       // open a spot by id
        case challenge  // open a challenge by id
    }

    // MARK: - Route (semantic)

    public enum Route: Equatable, Sendable {
        case navigate(src: CLLocationCoordinate2D?, dst: CLLocationCoordinate2D, mode: String?)
        case map(dst: CLLocationCoordinate2D, mode: String?)
        case referral(code: String)
        case paywall
        case profile(userId: String)
        case spot(id: String)
        case challenge(id: String)
    }

    // MARK: - Build

    public static func url(for route: Route) -> URL {
        var comps = URLComponents()
        comps.scheme = appScheme

        switch route {
        case let .navigate(src, dst, mode):
            comps.host = Host.navigate.rawValue
            comps.queryItems = [
                src.flatMap { .coord(name: "src", $0) },
                .coord(name: "dst", dst),
                mode.flatMap { URLQueryItem(name: "mode", value: $0) }
            ].compactMap { $0 }

        case let .map(dst, mode):
            comps.host = Host.map.rawValue
            comps.queryItems = [
                .coord(name: "dst", dst),
                mode.flatMap { URLQueryItem(name: "mode", value: $0) }
            ].compactMap { $0 }

        case let .referral(code):
            comps.host = Host.referral.rawValue
            comps.queryItems = [.string(name: "code", code)]

        case .paywall:
            comps.host = Host.paywall.rawValue

        case let .profile(userId):
            comps.host = Host.profile.rawValue
            comps.queryItems = [.string(name: "id", userId)]

        case let .spot(id):
            comps.host = Host.spot.rawValue
            comps.queryItems = [.string(name: "id", id)]

        case let .challenge(id):
            comps.host = Host.challenge.rawValue
            comps.queryItems = [.string(name: "id", id)]
        }

        guard let url = comps.url else {
            // Fallback to a harmless “about:blank”-like placeholder if construction fails.
            return URL(string: "\(appScheme)://")!
        }
        return url
    }

    // MARK: - Parse

    public static func parse(url: URL) -> Route? {
        // Accept both scheme links (skateroute://) and universal links (https)
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // If coming from https://…/navigate, treat path/host similarly to scheme.
        let hostString: String? = {
            if comps.scheme?.lowercased() == appScheme { return comps.host }
            // Try path first segment as host, e.g., https://skateroute.app/navigate?...
            if let first = comps.path.split(separator: "/").first { return String(first) }
            return comps.host // fallback
        }()

        guard let hostRaw = hostString, let host = Host(rawValue: hostRaw.lowercased()) else { return nil }
        let q = Query(items: comps.queryItems ?? [])

        switch host {
        case .navigate:
            guard let dst = q.coord("dst") else { return nil }
            let src = q.coord("src")
            let mode = q.string("mode")
            return .navigate(src: src, dst: dst, mode: mode)

        case .map:
            guard let dst = q.coord("dst") else { return nil }
            let mode = q.string("mode")
            return .map(dst: dst, mode: mode)

        case .referral:
            guard let code = q.string("code"), !code.isEmpty else { return nil }
            return .referral(code: code)

        case .paywall:
            return .paywall

        case .profile:
            guard let id = q.string("id"), !id.isEmpty else { return nil }
            return .profile(userId: id)

        case .spot:
            guard let id = q.string("id"), !id.isEmpty else { return nil }
            return .spot(id: id)

        case .challenge:
            guard let id = q.string("id"), !id.isEmpty else { return nil }
            return .challenge(id: id)
        }
    }

    // MARK: - Command bridge (optional)

    /// Tiny command that higher layers can switch on without re-parsing.
    public enum Command: Equatable, Sendable {
        case presentMap(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D, mode: String?)
        case showPaywall
        case showProfile(String)
        case showSpot(String)
        case showChallenge(String)
        case applyReferral(String)
    }

    public static func command(for route: Route) -> Command {
        switch route {
        case let .navigate(src, dst, mode):
            return .presentMap(from: src, to: dst, mode: mode)
        case let .map(dst, mode):
            return .presentMap(from: nil, to: dst, mode: mode)
        case let .profile(id):
            return .showProfile(id)
        case let .spot(id):
            return .showSpot(id)
        case let .challenge(id):
            return .showChallenge(id)
        case let .referral(code):
            return .applyReferral(code)
        case .paywall:
            return .showPaywall
        }
    }

    // MARK: - NSUserActivity helpers (universal link handoff)

    public static let userActivityType = "com.yourcompany.skateroute.browsing"

    /// Create an activity that mirrors a deep link; use in handoffs to SceneDelegate/App.
    public static func makeUserActivity(for route: Route) -> NSUserActivity {
        let activity = NSUserActivity(activityType: userActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForSearch = false
        let url = url(for: route)
        activity.webpageURL = url // if you host universal links later, replace with public URL
        activity.userInfo = ["deeplink": url.absoluteString]
        return activity
    }

    // MARK: - Query parsing

    struct Query {
        let map: [String: String]
        init(items: [URLQueryItem]) {
            var m: [String: String] = [:]
            for it in items {
                if let v = it.value { m[it.name] = v }
            }
            self.map = m
        }
        func string(_ name: String) -> String? { map[name] }
        func coord(_ name: String) -> CLLocationCoordinate2D? {
            guard let raw = map[name] else { return nil }
            return Self.parseCoord(raw)
        }
        static func parseCoord(_ raw: String) -> CLLocationCoordinate2D? {
            let parts = raw.split(separator: ",").map(String.init)
            guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
                  abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}

// MARK: - URLQueryItem helpers

private extension URLQueryItem {
    static func coord(name: String, _ c: CLLocationCoordinate2D) -> URLQueryItem {
        URLQueryItem(name: name, value: String(format: "%.6f,%.6f", c.latitude, c.longitude))
    }
    static func string(name: String, _ v: String) -> URLQueryItem {
        URLQueryItem(name: name, value: v)
    }
}


