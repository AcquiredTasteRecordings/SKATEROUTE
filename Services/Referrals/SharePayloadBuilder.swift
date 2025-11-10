// Services/Referrals/SharePayloadBuilder.swift
// Social-ready share packs for routes/spots: OpenGraph-ish image, deep link, localized text.
// Zero PII. Optional short-link. Snapshot via Support/Share/OGImageRenderer.

import Foundation
import UIKit
import CoreLocation

// MARK: - Protocol seams (DI)

public protocol OGImageRendering {
    struct Spec: Sendable, Equatable {
        public var title: String
        public var subtitle: String?
        public var badge: String?
        public var seed: UInt64?            // Enables deterministic render in tests
        public var overlay: Overlay
        public var size: CGSize             // e.g., 1200x630 for OG cards

        public enum Overlay: Equatable, Sendable {
            case routePolyline(encoded: String, focus: CLLocationCoordinate2D?)
            case spotPin(coord: CLLocationCoordinate2D)
        }

        public init(title: String,
                    subtitle: String? = nil,
                    badge: String? = nil,
                    seed: UInt64? = nil,
                    overlay: Overlay,
                    size: CGSize = CGSize(width: 1200, height: 630)) {
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.seed = seed
            self.overlay = overlay
            self.size = size
        }
    }

    func render(spec: Spec) async throws -> UIImage
}

public protocol DeepLinkBuilding {
    func buildLink(kind: SharePayloadBuilder.Subject, campaign: String?, tags: [String: String]) throws -> URL
}

public protocol ShortLinking {
    func shorten(_ url: URL) async throws -> URL
}

// MARK: - SharePayload & Subject

public struct SharePayload: Sendable {
    public let url: URL
    public let image: UIImage
    public let text: String
    public init(url: URL, image: UIImage, text: String) {
        self.url = url
        self.image = image
        self.text = text
    }
}

public final class SharePayloadBuilder: @unchecked Sendable {

    public enum Subject: Sendable, Equatable {
        case route(id: String,
                   name: String?,
                   distanceMeters: Double?,
                   durationSeconds: TimeInterval?,
                   encodedPolyline: String?,
                   center: CLLocationCoordinate2D?)
        case spot(id: String,
                  name: String,
                  coordinate: CLLocationCoordinate2D)
    }

    public struct Config: Sendable, Equatable {
        public var campaign: String? = "organic_share"
        public var utmSource: String = "app"
        public var utmMedium: String = "ios"
        public var maxTitleLen: Int = 60
        public var maxDescLen: Int = 160
        public var appendSafetyNote: Bool = true
        public var ogSize: CGSize = CGSize(width: 1200, height: 630)
        public init() {}
    }

    // MARK: - Dependencies

    private let og: OGImageRendering
    private let deepLinks: DeepLinkBuilding
    private let shortLinks: ShortLinking?
    private let locale: Locale
    private let bundle: Bundle
    private let now: () -> Date

    public init(og: OGImageRendering,
                deepLinks: DeepLinkBuilding,
                shortLinks: ShortLinking? = nil,
                locale: Locale = .current,
                bundle: Bundle = .main,
                now: @escaping () -> Date = Date.init) {
        self.og = og
        self.deepLinks = deepLinks
        self.shortLinks = shortLinks
        self.locale = locale
        self.bundle = bundle
        self.now = now
    }

    // MARK: - Build

    public func build(subject: Subject,
                      deterministicSeed: UInt64? = nil) async throws -> SharePayload {

        // 1) Text (localized title/description + safety note)
        let (title, description) = localizedCopy(for: subject)
        let finalTitle = title.trimmed(max: config.maxTitleLen)
        let baseDesc = description.trimmed(max: config.maxDescLen)
        let safety = (config.appendSafetyNote ? " " + l("share.safety") : "")
        let compositeText = [finalTitle, baseDesc + safety]
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2) Deep link with friendly, no-PII UTM-ish tags
        let tags = utmTags(subject: subject, locale: locale)
        var link = try deepLinks.buildLink(kind: subject, campaign: config.campaign, tags: tags)
        if let shortener = shortLinks {
            // Non-fatal if shortening fails: keep original link
            if let shortened = try? await shortener.shorten(link) { link = shortened }
        }

        // 3) OG image via renderer (Map snapshot + overlays)
        let overlay: OGImageRendering.Spec.Overlay = {
            switch subject {
            case .route(_, let name, _, _, let poly, let center):
                if let poly, !poly.isEmpty { return .routePolyline(encoded: poly, focus: center) }
                return .routePolyline(encoded: "", focus: center) // renderer will fallback to region heuristic
            case .spot(_, let name, let coord):
                return .spotPin(coord: coord)
            }
        }()

        let badge = badgeText(for: subject)
        let spec = OGImageRendering.Spec(
            title: finalTitle,
            subtitle: shareSubtitle(for: subject),
            badge: badge,
            seed: deterministicSeed,
            overlay: overlay,
            size: config.ogSize
        )
        let image = try await og.render(spec: spec)

        // 4) Final share text: include link at end, platform-friendly
        let shareText = compositeText + "\n" + link.absoluteString

        return SharePayload(url: link, image: image, text: shareText)
    }

    // MARK: - Public config

    public var config = Config()

    // MARK: - Copy generation

    private func localizedCopy(for subject: Subject) -> (title: String, description: String) {
        switch subject {
        case .route(_, let name, let meters, let seconds, _, _):
            let routeName = (name?.isEmpty == false ? name! : l("share.route.untitled"))
            let dist = formattedDistance(meters)
            let dur = formattedDuration(seconds)
            let title = l("share.route.title", routeName, dist)
            let desc = l("share.route.desc", dur, l("share.cta.follow"))
            return (title, desc)
        case .spot(_, let name, _):
            let title = l("share.spot.title", name)
            let desc = l("share.spot.desc", l("share.cta.meetup"))
            return (title, desc)
        }
    }

    private func shareSubtitle(for subject: Subject) -> String? {
        switch subject {
        case .route(_, _, let meters, let seconds, _, _):
            let dist = formattedDistance(meters)
            let dur = formattedDuration(seconds)
            return l("share.subtitle.route", dist, dur)
        case .spot(_, _, _):
            return l("share.subtitle.spot")
        }
    }

    private func badgeText(for subject: Subject) -> String? {
        // Small, tasteful vibe badge. Keep terse.
        let weekday = DateFormatter.localizedString(from: now(), dateStyle: .short, timeStyle: .none)
        switch subject {
        case .route:
            return l("share.badge.route", weekday)
        case .spot:
            return l("share.badge.spot", weekday)
        }
    }

    // MARK: - UTM-ish tags

    private func utmTags(subject: Subject, locale: Locale) -> [String: String] {
        var tags: [String: String] = [
            "utm_source": config.utmSource,
            "utm_medium": config.utmMedium,
            "utm_campaign": config.campaign ?? "organic_share",
            "utm_locale": locale.identifier
        ]
        switch subject {
        case .route(let id, _, _, _, _, _):
            tags["utm_content"] = "route"
            tags["rid"] = id
        case .spot(let id, _, _):
            tags["utm_content"] = "spot"
            tags["sid"] = id
        }
        return tags
    }

    // MARK: - Formatting

    private func formattedDistance(_ meters: Double?) -> String {
        guard let m = meters, m > 1 else { return l("share.distance.na") }
        let km = m / 1000.0
        if locale.usesMetricSystem {
            return String(format: l("share.distance.km"), km)
        } else {
            let miles = km * 0.621371
            return String(format: l("share.distance.mi"), miles)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s >= 1 else { return l("share.duration.na") }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return String(format: l("share.duration.h_m"), h, m) }
        return String(format: l("share.duration.m"), m)
    }

    // MARK: - Localization helper

    private func l(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: "Localizable", bundle: bundle, comment: "")
        return String(format: format, locale: locale, arguments: args)
    }
}

// MARK: - String utilities

private extension String {
    func trimmed(max: Int) -> String {
        guard count > max else { return self }
        if max <= 1 { return String(prefix(max)) }
        let end = max - 1
        return String(prefix(end)) + "…"
    }
}

// MARK: - Default DeepLinkBuilder (optional reference impl)

public final class DefaultDeepLinkBuilder: DeepLinkBuilding, @unchecked Sendable {
    private let host: String
    private let scheme: String
    private let pathRoute = "/share/route"
    private let pathSpot = "/share/spot"

    public init(host: String, scheme: String = "https") {
        self.host = host
        self.scheme = scheme
    }

    public func buildLink(kind: SharePayloadBuilder.Subject, campaign: String?, tags: [String : String]) throws -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host

        switch kind {
        case .route(let id, _, _, _, _, _):
            comps.path = pathRoute
            var q: [URLQueryItem] = [
                URLQueryItem(name: "rid", value: id),
                URLQueryItem(name: "v", value: "1")
            ]
            q.append(contentsOf: tags.map { URLQueryItem(name: $0.key, value: $0.value) })
            comps.queryItems = q
        case .spot(let id, _, _):
            comps.path = pathSpot
            var q: [URLQueryItem] = [
                URLQueryItem(name: "sid", value: id),
                URLQueryItem(name: "v", value: "1")
            ]
            q.append(contentsOf: tags.map { URLQueryItem(name: $0.key, value: $0.value) })
            comps.queryItems = q
        }

        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }
}

// MARK: - Preview/Test fakes

#if DEBUG
public final class OGImageRendererFake: OGImageRendering {
    public init() {}
    public func render(spec: Spec) async throws -> UIImage {
        // Deterministic single-color image seeded for golden tests.
        let seed = UInt64(truncatingIfNeeded: (spec.seed ?? 42))
        let side: CGFloat = max(2, min(spec.size.width, spec.size.height))
        UIGraphicsBeginImageContextWithOptions(CGSize(width: side, height: side), true, 1)
        defer { UIGraphicsEndImageContext() }
        let ctx = UIGraphicsGetCurrentContext()!
        // Simple hash→gray map to keep snapshots stable across machines
        let g = CGFloat((seed & 0xFF)) / 255.0
        ctx.setFillColor(UIColor(white: g, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return UIGraphicsGetImageFromCurrentImageContext()!
    }
}

public struct ShortLinkerFake: ShortLinking {
    public init() {}
    public func shorten(_ url: URL) async throws -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "s", value: "1")]
        return c.url!
    }
}
#endif
