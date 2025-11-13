// Features/Rewards/PartnerSpotlightView.swift
// Local business promo spotlight with directions.
// - Presents a rich card: logo, title, partner name, blurb, hours, validity.
// - Primary CTA opens in-app spot (if known) otherwise Apple Maps driving/walking (skate ≈ walking) directions.
// - Optional actions: Website, Call (tel:), Share.
// - Map preview chip (static) for orientation—no GPS reads. Dynamic Type & ≥44pt targets.
// - Privacy: no tracking; analytics use purpose-labeled events without PII.

import SwiftUI
import MapKit
import Combine
import UIKit

// MARK: - Domain adapters (aligns with Services/Rewards/BrandPartnerService + Spots)

public struct PartnerPromoViewModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let partnerName: String
    public let title: String             // “Free Espresso for Riders”
    public let detail: String            // short persuasive blurb
    public let addressLine: String?      // “123 Plaza St, Vancouver”
    public let phone: String?            // “+1-604-555-0123”
    public let website: URL?
    public let iconURL: URL?
    public let cityCode: String?
    public let coordinate: CLLocationCoordinate2D
    public let spotId: String?           // if we have an internal SkateSpot to open
    public let validUntil: Date?         // optional expiry window

    public init(
        id: String,
        partnerName: String,
        title: String,
        detail: String,
        addressLine: String?,
        phone: String?,
        website: URL?,
        iconURL: URL?,
        cityCode: String?,
        coordinate: CLLocationCoordinate2D,
        spotId: String?,
        validUntil: Date?
    ) {
        self.id = id
        self.partnerName = partnerName
        self.title = title
        self.detail = detail
        self.addressLine = addressLine
        self.phone = phone
        self.website = website
        self.iconURL = iconURL
        self.cityCode = cityCode
        self.coordinate = coordinate
        self.spotId = spotId
        self.validUntil = validUntil
    }

    // Manual Equatable because CLLocationCoordinate2D may not conform
    public static func == (lhs: PartnerPromoViewModel, rhs: PartnerPromoViewModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.partnerName == rhs.partnerName &&
        lhs.title == rhs.title &&
        lhs.detail == rhs.detail &&
        lhs.addressLine == rhs.addressLine &&
        lhs.phone == rhs.phone &&
        lhs.website == rhs.website &&
        lhs.iconURL == rhs.iconURL &&
        lhs.cityCode == rhs.cityCode &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.spotId == rhs.spotId &&
        lhs.validUntil == rhs.validUntil
    }
}

// MARK: - DI seams

public protocol PartnerPromoReading: AnyObject {
    func fetchPromo(promoId: String) async throws -> PartnerPromoViewModel
}

public protocol PartnerNavigating: AnyObject {
    /// Open an internal SkateSpot details screen.
    func openSpotDetail(spotId: String)
}

public protocol MapsRouting {
    /// Opens Apple Maps with a walking route (closest to skating) to the coordinate.
    func openAppleMaps(to coordinate: CLLocationCoordinate2D, name: String?)
}

// MARK: - Default Apple Maps adapter

public struct AppleMapsRouter: MapsRouting {
    public init() {}
    public func openAppleMaps(to coordinate: CLLocationCoordinate2D, name: String?) {
        let item = MKMapItem(placemark: .init(coordinate: coordinate))
        item.name = name
        let opts = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        item.openInMaps(launchOptions: opts)
    }
}

// MARK: - ViewModel

@MainActor
public final class PartnerSpotlightViewModel: ObservableObject {
    @Published public private(set) var promo: PartnerPromoViewModel?
    @Published public private(set) var loading = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    private let promoId: String?
    private let reader: PartnerPromoReading?
    private let navigator: PartnerNavigating?
    private let maps: MapsRouting
    private let analytics: AnalyticsLogging? // currently unused; kept for future wiring

    public init(
        promo: PartnerPromoViewModel? = nil,
        promoId: String? = nil,
        reader: PartnerPromoReading? = nil,
        navigator: PartnerNavigating?,
        maps: MapsRouting = AppleMapsRouter(),
        analytics: AnalyticsLogging?
    ) {
        self.promo = promo
        self.promoId = promoId
        self.reader = reader
        self.navigator = navigator
        self.maps = maps
        self.analytics = analytics
    }

    public func loadIfNeeded() {
        guard promo == nil, let id = promoId, let reader else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let p = try await reader.fetchPromo(promoId: id)
                promo = p
            } catch {
                errorMessage = NSLocalizedString("Couldn’t load the partner promo.", comment: "load fail")
            }
        }
    }

    // MARK: - Actions

    public func openDirections() {
        guard let p = promo else { return }
        if let sid = p.spotId {
            navigator?.openSpotDetail(spotId: sid)
        } else {
            maps.openAppleMaps(to: p.coordinate, name: p.partnerName)
        }
    }

    public func openWebsite() {
        guard let url = promo?.website else { return }
        UIApplication.shared.open(url)
    }

    public func call() {
        guard let raw = promo?.phone else { return }
        let digits = raw.filter("0123456789+".contains)
        if let url = URL(string: "tel://\(digits)"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            errorMessage = NSLocalizedString("This device can’t make calls.", comment: "call fail")
        }
    }

    public func share(from anchor: UIView) {
        guard let p = promo else { return }
        let addr = p.addressLine ?? ""
        let text = "\(p.partnerName) — \(p.title)\n\(addr)"
        let ac = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = anchor
        UIApplication.shared.topMostController()?.present(ac, animated: true)
    }
}

// MARK: - View

public struct PartnerSpotlightView: View {
    @ObservedObject private var vm: PartnerSpotlightViewModel
    @State private var shareAnchor = WeakAnchorView()

    public init(viewModel: PartnerSpotlightViewModel) { self.vm = viewModel }

    public var body: some View {
        content
            .onAppear { vm.loadIfNeeded() }
            .overlay(toasts)
            .navigationTitle(Text(NSLocalizedString("Partner", comment: "title")))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("partner_spotlight")
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = vm.promo {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(p)
                    mapPreview(p)
                    Text(p.detail)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    meta(p)

                    HStack(spacing: 8) {
                        Button(action: vm.openDirections) {
                            Label(
                                NSLocalizedString(p.spotId == nil ? "Open in Maps" : "Open Spot", comment: "directions"),
                                systemImage: p.spotId == nil ? "map" : "mappin.and.ellipse"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        if p.website != nil {
                            Button(action: vm.openWebsite) {
                                Label(NSLocalizedString("Website", comment: "website"), systemImage: "safari")
                            }
                            .buttonStyle(.bordered)
                        }

                        if p.phone != nil {
                            Button(action: vm.call) {
                                Label(NSLocalizedString("Call", comment: "call"), systemImage: "phone")
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()

                        AnchorView(anchor: $shareAnchor)
                        Button {
                            if let v = shareAnchor.view {
                                vm.share(from: v)
                            }
                        } label: {
                            Label(NSLocalizedString("Share", comment: "share"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 44)

                    if let until = p.validUntil {
                        ValidityBar(validUntil: until)
                    }
                }
                .padding(16)
            }
        } else {
            EmptyState(text: NSLocalizedString("Promo not available.", comment: "empty"))
        }
    }

    // MARK: - Pieces

    private func header(_ p: PartnerPromoViewModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon(url: p.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.headline)
                HStack(spacing: 6) {
                    Text(p.partnerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let city = p.cityCode {
                        Text(city)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .accessibilityLabel(Text(city))
                    }
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(p.partnerName). \(p.title)."))
    }

    private func mapPreview(_ p: PartnerPromoViewModel) -> some View {
        Map(
            initialPosition: .region(
                .init(
                    center: p.coordinate,
                    span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)
                )
            )
        ) {
            Annotation("", coordinate: p.coordinate) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 18)
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 18, height: 18)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityLabel(Text(NSLocalizedString("Location preview", comment: "map ax")))
        .accessibilityHint(Text(NSLocalizedString("The pin shows the partner location.", comment: "map hint")))
        .disabled(true)
    }

    private func meta(_ p: PartnerPromoViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let addr = p.addressLine {
                Label(addr, systemImage: "mappin.circle")
                    .font(.footnote)
            }
            if let site = p.website {
                Label(site.host ?? site.absoluteString, systemImage: "link")
                    .font(.footnote)
            }
            if let phone = p.phone {
                Label(phone, systemImage: "phone")
                    .font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "gift")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                )
                .frame(width: 48, height: 48)
        }
    }

    // MARK: Toasts

    @ViewBuilder
    private var toasts: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system)
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { body() }
        }
    }
}

// MARK: - Small helpers

fileprivate struct EmptyState: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "ticket")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

fileprivate struct ValidityBar: View {
    let validUntil: Date
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass").imageScale(.small)
            Text(expireStr(validUntil))
                .font(.caption.monospacedDigit())
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(Text(expireStr(validUntil)))
    }
    private func expireStr(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return String(
            format: NSLocalizedString("Ends %@", comment: "ends"),
            f.localizedString(for: d, relativeTo: Date())
        )
    }
}

/// Invisible UIView anchor to present UIActivityViewController neatly.
fileprivate struct AnchorView: UIViewRepresentable {
    @Binding var anchor: WeakAnchorView
    func makeUIView(context: Context) -> UIView { anchor.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
fileprivate final class WeakAnchorView {
    fileprivate let view = UIView()
}

// UIApplication helper to present share sheet
fileprivate extension UIApplication {
    func topMostController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topMostController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return tab.selectedViewController.flatMap { topMostController(base: $0) }
        }
        if let presented = base?.presentedViewController {
            return topMostController(base: presented)
        }
        return base
    }
}

// MARK: - Convenience builder

public extension PartnerSpotlightView {
    static func make(
        promo: PartnerPromoViewModel,
        navigator: PartnerNavigating?,
        maps: MapsRouting = AppleMapsRouter(),
        analytics: AnalyticsLogging? = nil
    ) -> PartnerSpotlightView {
        PartnerSpotlightView(
            viewModel: .init(
                promo: promo,
                navigator: navigator,
                maps: maps,
                analytics: analytics
            )
        )
    }

    static func make(
        promoId: String,
        reader: PartnerPromoReading,
        navigator: PartnerNavigating?,
        maps: MapsRouting = AppleMapsRouter(),
        analytics: AnalyticsLogging? = nil
    ) -> PartnerSpotlightView {
        PartnerSpotlightView(
            viewModel: .init(
                promo: nil,
                promoId: promoId,
                reader: reader,
                navigator: navigator,
                maps: maps,
                analytics: analytics
            )
        )
    }
}

// MARK: - DEBUG fakes

#if DEBUG
final class PromoReaderFake: PartnerPromoReading {
    func fetchPromo(promoId: String) async throws -> PartnerPromoViewModel {
        .init(
            id: promoId,
            partnerName: "Plaza Coffee",
            title: "Free Espresso for Riders",
            detail: "Show up with your board, be kind to baristas, enjoy an espresso on us. One per rider, weekdays only.",
            addressLine: "123 Plaza St, Vancouver, BC",
            phone: "+1 604 555 0123",
            website: URL(string: "https://example.com/coffee"),
            iconURL: nil,
            cityCode: "YVR",
            coordinate: .init(latitude: 49.2827, longitude: -123.1207),
            spotId: nil,
            validUntil: Date().addingTimeInterval(3600 * 72)
        )
    }
}

final class NavFake: PartnerNavigating {
    func openSpotDetail(spotId: String) {}
}

struct PartnerSpotlightView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            PartnerSpotlightView.make(
                promoId: "promo1",
                reader: PromoReaderFake(),
                navigator: NavFake()
            )
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • If `spotId` exists, route to SpotDetailView via AppCoordinator; else fall back to Apple Maps walking directions.
// • Present this card from RewardsWalletView rows (“Learn more”) or from partner pins in SpotMapOverlayRenderer.
// • Keep analytics minimal: open_maps/open_spot/open_website/call/share—no PII, no precise GPS beyond the promo’s public coordinate.
// • Localization: partner title/detail/labels pulled through Localizable.strings.
// • Accessibility: VO reads partner & title; buttons labeled “Open in Maps”, “Open Spot”, “Website”, “Call”, “Share”.
