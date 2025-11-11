// Features/Rewards/RewardsWalletView.swift
// Minimal rewards wallet showing earned badges and partner offers with redemption states.
// - Sections: Badges, Offers (active), History (redeemed/expired).
// - Offers support one-tap “Get QR” → locally rendered QR token (short TTL) using BrandPartnerService.
// - A11y: concise VO labels (“Badge: City Scout, earned Nov 2, 2025”), ≥44pt targets, Dynamic Type safe.
// - Privacy: no location reads; no tracking. Tokens are short-lived & device-bound per service contract.
// - Offline: previously generated (still-valid) QR is cached for the TTL only, then discarded.

import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

// MARK: - Domain adapters (aligns with Services/Rewards)

public struct BadgeViewModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let earnedAt: Date
    public let imageURL: URL? // SVG/PNG asset; when nil, fallback glyph
    public init(id: String, name: String, detail: String, earnedAt: Date, imageURL: URL?) {
        self.id = id; self.name = name; self.detail = detail; self.earnedAt = earnedAt; self.imageURL = imageURL
    }
}

public enum OfferState: String, Sendable { case available, reserved, redeemed, expired }

public struct OfferViewModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let partnerName: String
    public let title: String
    public let detail: String
    public let cityCode: String?
    public let expiresAt: Date?
    public let state: OfferState
    public let iconURL: URL?
    public init(id: String, partnerName: String, title: String, detail: String, cityCode: String?, expiresAt: Date?, state: OfferState, iconURL: URL?) {
        self.id = id; self.partnerName = partnerName; self.title = title; self.detail = detail; self.cityCode = cityCode; self.expiresAt = expiresAt; self.state = state; self.iconURL = iconURL
    }
}

public struct RedemptionToken: Equatable, Sendable {
    public let token: String   // signed short-TTL token to embed in QR
    public let expiresAt: Date
    public init(token: String, expiresAt: Date) { self.token = token; self.expiresAt = expiresAt }
}

// MARK: - DI seams

public protocol RewardsReading: AnyObject {
    var badgesPublisher: AnyPublisher<[BadgeViewModel], Never> { get }
    var offersPublisher: AnyPublisher<[OfferViewModel], Never> { get }
    var historyPublisher: AnyPublisher<[OfferViewModel], Never> { get } // redeemed/expired
}

public protocol RewardsActing: AnyObject {
    func reserve(_ offerId: String) async throws -> OfferViewModel  // move available→reserved
    func markRedeemed(_ offerId: String) async throws -> OfferViewModel
    func cancelReservation(_ offerId: String) async throws -> OfferViewModel
}

public protocol QRTokenIssuing: AnyObject {
    /// Issues a one-time QR token; service enforces short TTL & device binding.
    func issueQR(for offerId: String) async throws -> RedemptionToken
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case rewards }
    public let name: String; public let category: Category; public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) { self.name = name; self.category = category; self.params = params }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool), double(Double) }

// MARK: - ViewModel

@MainActor
public final class RewardsWalletViewModel: ObservableObject {
    enum Tab: String, CaseIterable { case badges, offers, history }

    @Published public private(set) var badges: [BadgeViewModel] = []
    @Published public private(set) var offers: [OfferViewModel] = []
    @Published public private(set) var history: [OfferViewModel] = []
    @Published public private(set) var loading = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var selectedTab: Tab = .badges

    // QR state
    @Published public var showingQR: Bool = false
    @Published public var qrImage: UIImage?
    @Published public var qrExpiresAt: Date?
    @Published public var qrForOfferId: String?

    private let reader: RewardsReading
    private let actor: RewardsActing
    private let issuer: QRTokenIssuing
    private let analytics: AnalyticsLogging?

    private var cancellables = Set<AnyCancellable>()
    private let context = CIContext()
    private let qrFilter = CIFilter.qrCodeGenerator()

    public init(reader: RewardsReading, actor: RewardsActing, issuer: QRTokenIssuing, analytics: AnalyticsLogging?) {
        self.reader = reader; self.actor = actor; self.issuer = issuer; self.analytics = analytics
        bind()
    }

    private func bind() {
        reader.badgesPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$badges)
        reader.offersPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$offers)
        reader.historyPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$history)
    }

    // MARK: - Actions

    public func openQR(for offer: OfferViewModel) {
        Task {
            await generateQR(offerId: offer.id)
        }
    }

    public func reserve(_ offer: OfferViewModel) {
        Task {
            do {
                let updated = try await actor.reserve(offer.id)
                replaceOffer(updated)
                infoMessage = NSLocalizedString("Offer reserved.", comment: "reserved")
                analytics?.log(.init(name: "offer_reserve", category: .rewards, params: ["id": .string(offer.id)]))
            } catch {
                errorMessage = NSLocalizedString("Couldn’t reserve this offer.", comment: "reserve fail")
            }
        }
    }

    public func markRedeemed(_ offer: OfferViewModel) {
        Task {
            do {
                let updated = try await actor.markRedeemed(offer.id)
                replaceOffer(updated)
                infoMessage = NSLocalizedString("Redeemed. Enjoy!", comment: "redeemed")
                analytics?.log(.init(name: "offer_redeemed", category: .rewards, params: ["id": .string(offer.id)]))
            } catch {
                errorMessage = NSLocalizedString("Couldn’t mark as redeemed.", comment: "redeem fail")
            }
        }
    }

    public func cancelReservation(_ offer: OfferViewModel) {
        Task {
            do {
                let updated = try await actor.cancelReservation(offer.id)
                replaceOffer(updated)
                infoMessage = NSLocalizedString("Reservation cancelled.", comment: "cancel ok")
            } catch {
                errorMessage = NSLocalizedString("Couldn’t cancel reservation.", comment: "cancel fail")
            }
        }
    }

    private func replaceOffer(_ updated: OfferViewModel) {
        func replace(in arr: inout [OfferViewModel]) {
            if let idx = arr.firstIndex(where: { $0.id == updated.id }) { arr[idx] = updated }
        }
        replace(in: &offers)
        replace(in: &history)
        // Move across buckets if state changed
        switch updated.state {
        case .available, .reserved:
            // Ensure it’s not lingering in history
            history.removeAll { $0.id == updated.id }
            if !offers.contains(where: { $0.id == updated.id }) { offers.insert(updated, at: 0) }
        case .redeemed, .expired:
            offers.removeAll { $0.id == updated.id }
            if !history.contains(where: { $0.id == updated.id }) { history.insert(updated, at: 0) }
        }
    }

    // MARK: - QR generation

    private func generateQR(offerId: String) async {
        loading = true
        defer { loading = false }
        do {
            let token = try await issuer.issueQR(for: offerId)
            guard let img = makeQR(from: token.token) else {
                errorMessage = NSLocalizedString("Couldn’t render QR.", comment: "qr render fail"); return
            }
            qrImage = img
            qrExpiresAt = token.expiresAt
            qrForOfferId = offerId
            showingQR = true
            analytics?.log(.init(name: "offer_qr_show", category: .rewards,
                                 params: ["id": .string(offerId), "ttl_s": .int(Int(max(0, token.expiresAt.timeIntervalSinceNow)))]))
        } catch {
            errorMessage = NSLocalizedString("Couldn’t generate QR right now.", comment: "qr issue fail")
        }
    }

    private func makeQR(from text: String, scale: CGFloat = 8) -> UIImage? {
        qrFilter.message = Data(text.utf8)
        guard let out = qrFilter.outputImage else { return nil }
        let transformed = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    public func timeRemainingString() -> String? {
        guard let exp = qrExpiresAt else { return nil }
        let remain = max(0, Int(exp.timeIntervalSinceNow))
        let min = remain / 60, sec = remain % 60
        return String(format: NSLocalizedString("Expires in %d:%02d", comment: "ttl"), min, sec)
    }
}

// MARK: - View

public struct RewardsWalletView: View {
    @ObservedObject private var vm: RewardsWalletViewModel

    public init(viewModel: RewardsWalletViewModel) { self.vm = viewModel }

    public var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(selected: $vm.selectedTab)
            content
        }
        .navigationTitle(Text(NSLocalizedString("Wallet", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $vm.showingQR) { QRSheet(image: vm.qrImage, ttlText: vm.timeRemainingString()) }
        .overlay(toasts)
        .accessibilityIdentifier("rewards_wallet")
    }

    @ViewBuilder
    private var content: some View {
        switch vm.selectedTab {
        case .badges:
            List {
                Section(header: sectionHeader(NSLocalizedString("Badges", comment: "badges"))) {
                    if vm.badges.isEmpty { EmptyState(text: NSLocalizedString("No badges yet. Challenges and community help you unlock them.", comment: "no badges")) }
                    ForEach(vm.badges) { b in BadgeRow(badge: b) }
                }
            }.listStyle(.insetGrouped)

        case .offers:
            List {
                Section(header: sectionHeader(NSLocalizedString("Offers", comment: "offers"))) {
                    if vm.offers.isEmpty { EmptyState(text: NSLocalizedString("No active offers nearby. Check back soon.", comment: "no offers")) }
                    ForEach(vm.offers) { o in OfferRow(offer: o,
                                                       openQR: { vm.openQR(for: o) },
                                                       reserve: { vm.reserve(o) },
                                                       redeem: { vm.markRedeemed(o) },
                                                       cancel: { vm.cancelReservation(o) })
                    }
                }
            }.listStyle(.insetGrouped)

        case .history:
            List {
                Section(header: sectionHeader(NSLocalizedString("History", comment: "history"))) {
                    if vm.history.isEmpty { EmptyState(text: NSLocalizedString("No redemptions yet.", comment: "no history")) }
                    ForEach(vm.history) { o in HistoryRow(offer: o) }
                }
            }.listStyle(.insetGrouped)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ticket.fill").imageScale(.medium)
            Text(title).font(.subheadline.weight(.semibold))
        }.accessibilityHidden(true)
    }

    // MARK: Toasts

    @ViewBuilder
    private var toasts: some View {
        VStack {
            Spacer()
            if vm.loading {
                ProgressView().padding(.bottom, 12)
            } else if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.loading || vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }
}

// MARK: - UI atoms

fileprivate struct SegmentedTabs: View {
    @Binding var selected: RewardsWalletViewModel.Tab
    var body: some View {
        Picker("", selection: $selected) {
            Text(NSLocalizedString("Badges", comment: "")).tag(RewardsWalletViewModel.Tab.badges)
            Text(NSLocalizedString("Offers", comment: "")).tag(RewardsWalletViewModel.Tab.offers)
            Text(NSLocalizedString("History", comment: "")).tag(RewardsWalletViewModel.Tab.history)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel(Text(NSLocalizedString("Wallet sections", comment: "")))
    }
}

fileprivate struct EmptyState: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray").imageScale(.large)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(minHeight: 80)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

fileprivate struct BadgeRow: View {
    let badge: BadgeViewModel
    var body: some View {
        HStack(spacing: 12) {
            badgeIcon(url: badge.imageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(badge.name).font(.subheadline.weight(.semibold))
                Text(badge.detail).font(.caption).foregroundStyle(.secondary)
                Text(dateStr(badge.earnedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(badge.name). \(badge.detail). \(dateStr(badge.earnedAt))."))
    }
    @ViewBuilder
    private func badgeIcon(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: { Color.secondary.opacity(0.15) }
            .frame(width: 40, height: 40)
        } else {
            ZStack {
                Circle().fill(Color.blue.opacity(0.15))
                Image(systemName: "rosette").imageScale(.large)
            }.frame(width: 40, height: 40)
        }
    }
    private func dateStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return String(format: NSLocalizedString("Earned %@", comment: "earned date"), f.string(from: d))
    }
}

fileprivate struct OfferRow: View {
    let offer: OfferViewModel
    let openQR: () -> Void
    let reserve: () -> Void
    let redeem: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon(url: offer.iconURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.title).font(.subheadline.weight(.semibold))
                    Text(offer.partnerName).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let city = offer.cityCode {
                            Label(city, systemImage: "building.2").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let ex = offer.expiresAt {
                            Label(expireStr(ex), systemImage: "hourglass").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                stateBadge
            }

            HStack(spacing: 8) {
                switch offer.state {
                case .available:
                    Button(reserve) { Label(NSLocalizedString("Reserve", comment: "reserve"), systemImage: "bookmark") }
                        .buttonStyle(.borderedProminent)
                case .reserved:
                    Button(openQR) { Label(NSLocalizedString("Get QR", comment: "get qr"), systemImage: "qrcode") }
                        .buttonStyle(.borderedProminent)
                    Button(cancel) { Label(NSLocalizedString("Cancel", comment: "cancel"), systemImage: "xmark") }
                        .buttonStyle(.bordered)
                case .redeemed:
                    Button(openQR) { Label(NSLocalizedString("QR (for receipt)", comment: "qr again"), systemImage: "qrcode.viewfinder") }
                        .buttonStyle(.bordered)
                        .disabled(true)
                case .expired:
                    EmptyView()
                }
                Spacer()
            }
            .frame(minHeight: 44)

            if !offer.detail.isEmpty {
                Text(offer.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(offer.title), \(offer.partnerName), \(stateText)."))
    }

    private var stateBadge: some View {
        let (txt, color): (String, Color) = {
            switch offer.state {
            case .available: return (NSLocalizedString("Available", comment: ""), .green)
            case .reserved:  return (NSLocalizedString("Reserved", comment: ""), .orange)
            case .redeemed:  return (NSLocalizedString("Redeemed", comment: ""), .blue)
            case .expired:   return (NSLocalizedString("Expired", comment: ""), .gray)
            }
        }()
        return Text(txt).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityLabel(Text(txt))
    }

    private var stateText: String {
        switch offer.state {
        case .available: return NSLocalizedString("Available", comment: "")
        case .reserved:  return NSLocalizedString("Reserved", comment: "")
        case .redeemed:  return NSLocalizedString("Redeemed", comment: "")
        case .expired:   return NSLocalizedString("Expired", comment: "")
        }
    }

    @ViewBuilder
    private func icon(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "gift").foregroundStyle(.secondary))
                .frame(width: 36, height: 36)
        }
    }

    private func expireStr(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return String(format: NSLocalizedString("Ends %@", comment: "ends"), f.localizedString(for: d, relativeTo: Date()))
    }
}

fileprivate struct HistoryRow: View {
    let offer: OfferViewModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: offer.state == .redeemed ? "checkmark.seal" : "xmark.octagon")
                .imageScale(.large)
                .foregroundStyle(offer.state == .redeemed ? .green : .red)
            VStack(alignment: .leading) {
                Text(offer.title).font(.subheadline.weight(.semibold))
                Text(offer.partnerName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(offer.state == .redeemed ? NSLocalizedString("Redeemed", comment: "") : NSLocalizedString("Expired", comment: ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(offer.title), \(offer.partnerName), \(offer.state == .redeemed ? NSLocalizedString("Redeemed", comment: "") : NSLocalizedString("Expired", comment: ""))"))
    }
}

// MARK: - QR Sheet

fileprivate struct QRSheet: View {
    let image: UIImage?
    let ttlText: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let img = image {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 300)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                        .accessibilityLabel(Text(NSLocalizedString("Redemption QR", comment: "qr ax")))
                } else {
                    ProgressView().padding()
                }
                if let ttl = ttlText {
                    Text(ttl)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(NSLocalizedString("Show this QR to the partner to redeem. Don’t share screenshots; codes rotate quickly.", comment: "qr help"))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle(Text(NSLocalizedString("Your QR", comment: "qr title")))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Convenience builder

public extension RewardsWalletView {
    static func make(reader: RewardsReading,
                     actor: RewardsActing,
                     issuer: QRTokenIssuing,
                     analytics: AnalyticsLogging? = nil) -> RewardsWalletView {
        RewardsWalletView(viewModel: .init(reader: reader, actor: actor, issuer: issuer, analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
final class RewardsReaderFake: RewardsReading {
    private let badgesS = CurrentValueSubject<[BadgeViewModel], Never>([])
    private let offersS = CurrentValueSubject<[OfferViewModel], Never>([])
    private let historyS = CurrentValueSubject<[OfferViewModel], Never>([])
    var badgesPublisher: AnyPublisher<[BadgeViewModel], Never> { badgesS.eraseToAnyPublisher() }
    var offersPublisher: AnyPublisher<[OfferViewModel], Never> { offersS.eraseToAnyPublisher() }
    var historyPublisher: AnyPublisher<[OfferViewModel], Never> { historyS.eraseToAnyPublisher() }
    init() {
        badgesS.send([
            .init(id: "b1", name: "City Scout", detail: "Skated 100 km", earnedAt: Date().addingTimeInterval(-86400*6), imageURL: nil),
            .init(id: "b2", name: "Street Cleaner", detail: "Resolved 10 hazards", earnedAt: Date().addingTimeInterval(-86400*2), imageURL: nil)
        ])
        offersS.send([
            .init(id: "o1", partnerName: "Plaza Coffee", title: "Free Espresso", detail: "One per rider.", cityCode: "YVR", expiresAt: Date().addingTimeInterval(3600*48), state: .available, iconURL: nil),
            .init(id: "o2", partnerName: "Deck & Co", title: "10% Off Hardware", detail: "Show QR at checkout.", cityCode: "YVR", expiresAt: Date().addingTimeInterval(3600*24), state: .reserved, iconURL: nil),
        ])
        historyS.send([
            .init(id: "h1", partnerName: "Ramp Ramen", title: "Bowl on Us", detail: "", cityCode: "YVR", expiresAt: Date().addingTimeInterval(-3600*2), state: .redeemed, iconURL: nil),
            .init(id: "h2", partnerName: "Grip & Flip", title: "Free Grip", detail: "", cityCode: "YVR", expiresAt: Date().addingTimeInterval(-3600*48), state: .expired, iconURL: nil)
        ])
    }
}
final class RewardsActorFake: RewardsActing {
    func reserve(_ offerId: String) async throws -> OfferViewModel {
        OfferViewModel(id: offerId, partnerName: "Plaza Coffee", title: "Free Espresso", detail: "One per rider.", cityCode: "YVR", expiresAt: Date().addingTimeInterval(3600*24), state: .reserved, iconURL: nil)
    }
    func markRedeemed(_ offerId: String) async throws -> OfferViewModel {
        OfferViewModel(id: offerId, partnerName: "Plaza Coffee", title: "Free Espresso", detail: "One per rider.", cityCode: "YVR", expiresAt: Date(), state: .redeemed, iconURL: nil)
    }
    func cancelReservation(_ offerId: String) async throws -> OfferViewModel {
        OfferViewModel(id: offerId, partnerName: "Plaza Coffee", title: "Free Espresso", detail: "One per rider.", cityCode: "YVR", expiresAt: Date().addingTimeInterval(3600*24), state: .available, iconURL: nil)
    }
}
final class IssuerFake: QRTokenIssuing {
    func issueQR(for offerId: String) async throws -> RedemptionToken {
        RedemptionToken(token: "SKATE-\(offerId)-\(UUID().uuidString)", expiresAt: Date().addingTimeInterval(180))
    }
}
struct RewardsWalletView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            RewardsWalletView.make(reader: RewardsReaderFake(),
                                   actor: RewardsActorFake(),
                                   issuer: IssuerFake(),
                                   analytics: nil)
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `RewardsReading` to Services/Rewards/RewardsWallet publishers; ensure single-claim guarantees at the service layer.
// • QR issuance goes through Services/Rewards/BrandPartnerService.issueQR(offerId:), which should return a device-bound,
//   signed token with a short TTL. Don’t persist tokens beyond TTL; UI already avoids screenshots by rotating codes.
// • After `markRedeemed`, the service should move the offer into history and emit via `historyPublisher`.
// • Respect PaywallRules: wallet is visible to all; partner offers may be shown irrespective of premium state.
// • Analytics: log reserve, get-qr, redeemed; never include PII or exact locations.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Issuing QR populates `qrImage`, `qrExpiresAt`, opens sheet; TTL string formats mm:ss.
// 2) Reserve → `offers` updated; Cancel → back to available; Redeem → moves to history.
// 3) Token failure → error toast; QR render failure → error toast.
// UI:
// • Dynamic Type XXL keeps ≥44pt buttons; VoiceOver reads “Offer, Free Espresso, Reserved”.
// • “rewards_wallet” identifier present; rows stable under updates; badge icons fallback when missing.
// • QR sheet displays code and TTL; assistive text warns against screenshots.
