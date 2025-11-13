// Features/Referrals/InviteFriendsView.swift
// Growth surface with receipts: Share Sheet + QR invite + referral status.
// - Consumes ReferralService for signed invite links and status stream.
// - Uses SharePayloadBuilder for OG image thumbs (route/spot snapshot or brand template).
// - Presents QR for in-person sharing (large, high-contrast; supports Dynamic Type & VoiceOver).
// - Ethical defaults: plain-language copy, easy opt-out, no contact scraping, no tracking.
// - Privacy: no address book access, no IDFA. Analytics events optional + redacted.
//
// Integration:
//   AppDI exposes ReferralService & SharePayloadBuilder. This view pulls a signed link,
//   shows share actions, and renders status (“accepted”, “rewards minted”), backed by RewardsWallet.

import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - DI seams (narrow & testable)

public struct SharePayload: Sendable, Equatable {
    public let url: URL
    public let image: UIImage?   // OG thumbnail (map snapshot + title)
    public let text: String      // localized, value-forward copy
}

public protocol ReferralServing: AnyObject {
    /// Generate a signed invite link. May include campaign, routeId, or spotId (optional).
    func generateInviteLink(referrerUserId: String, campaign: String?, routeId: String?, spotId: String?) async throws -> URL

    /// Emits live referral status for the current user (accepted counts, credits). Never includes PII of referees.
    var statusPublisher: AnyPublisher<ReferralStatus, Never> { get }

    /// Returns last-known status immediately if available (cache).
    func currentStatus() -> ReferralStatus?

    /// Defensive: returns true if a reward can still be granted today (cap enforcement awareness for UI copy).
    func canEarnMoreToday() -> Bool
}

public struct ReferralStatus: Sendable, Equatable {
    public let invitesSent: Int
    public let clicks: Int
    public let signupsCredited: Int
    public let rewardsIssued: Int
    public let lastCreditedAt: Date?
}

public protocol SharePayloadBuilding: AnyObject {
    /// Builds a social-friendly share pack for an invite link. May snapshot map overlays for context.
    func buildInviteShare(link: URL, title: String, subtitle: String?) async throws -> SharePayload
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case referrals }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) {
        self.name = name; self.category = category; self.params = params
    }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool) }

// MARK: - ViewModel

@MainActor
public final class InviteFriendsViewModel: ObservableObject {

    @Published public private(set) var payload: SharePayload?
    @Published public private(set) var status: ReferralStatus = .init(invitesSent: 0, clicks: 0, signupsCredited: 0, rewardsIssued: 0, lastCreditedAt: nil)
    @Published public private(set) var isLoading = false
    @Published public var infoMessage: String?
    @Published public var errorMessage: String?
    @Published public var showShareSheet = false
    @Published public var showQR = false

    // Input knobs
    public var campaign: String?
    public var routeId: String?
    public var spotId: String?

    private let referral: ReferralServing
    private let shareBuilder: SharePayloadBuilding
    private let analytics: AnalyticsLogging?
    private let referrerUserId: String
    private var cancellables = Set<AnyCancellable>()

    public init(referral: ReferralServing,
                shareBuilder: SharePayloadBuilding,
                analytics: AnalyticsLogging?,
                referrerUserId: String,
                campaign: String? = "default") {
        self.referral = referral
        self.shareBuilder = shareBuilder
        self.analytics = analytics
        self.referrerUserId = referrerUserId
        self.campaign = campaign

        referral.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)

        if let cached = referral.currentStatus() { status = cached }
    }

    public func onAppear() {
        if payload == nil { Task { await preloadPayload() } }
    }

    public func preloadPayload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let link = try await referral.generateInviteLink(referrerUserId: referrerUserId,
                                                             campaign: campaign, routeId: routeId, spotId: spotId)
            let p = try await shareBuilder.buildInviteShare(
                link: link,
                title: NSLocalizedString("Skate with me on SkateRoute 🛹", comment: "invite title"),
                subtitle: NSLocalizedString("Free hazard alerts. Pro tools if you want. Safety first.", comment: "invite subtitle")
            )
            self.payload = p
        } catch {
            self.errorMessage = NSLocalizedString("Couldn’t prepare your invite. Check your network and try again.", comment: "invite error")
        }
    }

    public func copyLink() {
        guard let url = payload?.url else { return }
        UIPasteboard.general.string = url.absoluteString
        analytics?.log(.init(name: "referral_copy_link", category: .referrals, params: [:]))
        infoMessage = NSLocalizedString("Link copied.", comment: "copy toast")
    }

    public func share() {
        analytics?.log(.init(name: "referral_share_sheet", category: .referrals, params: [:]))
        showShareSheet = true
    }

    public func toggleQR() {
        analytics?.log(.init(name: "referral_qr_toggle", category: .referrals, params: ["visible": .bool(!showQR)]))
        showQR.toggle()
    }
}

// MARK: - View

public struct InviteFriendsView: View {
    @ObservedObject private var vm: InviteFriendsViewModel
    @State private var shareSheetItem: ShareSheetItem?

    private let corner: CGFloat = 16
    private let buttonH: CGFloat = 54

    public init(viewModel: InviteFriendsViewModel) { self.vm = viewModel }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                previewCard
                actions
                statusCard
                ethicsNote
            }
            .padding(16)
        }
        .navigationTitle(Text(NSLocalizedString("Invite Friends", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.onAppear() }
        .sheet(item: $shareSheetItem) { item in
            ActivityView(activityItems: item.items, applicationActivities: nil)
                .ignoresSafeArea()
        }
        .onChange(of: vm.showShareSheet) { newVal in
            guard newVal, let p = vm.payload else { return }
            shareSheetItem = ShareSheetItem(items: [p.text, p.url, p.image as Any].compactMap { $0 })
            vm.showShareSheet = false
        }
        .overlay(toastOverlay)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Skate better together", comment: "header"))
                .font(.largeTitle.bold())
            Text(NSLocalizedString("Share your link or QR so pals can join. We reward invites—fairly and without spam.", comment: "sub"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var previewCard: some View {
        Group {
            if vm.isLoading {
                card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(NSLocalizedString("Preparing your invite…", comment: "loading"))
                    }
                }
            } else if let p = vm.payload {
                card {
                    HStack(alignment: .center, spacing: 12) {
                        Image(uiImage: p.image ?? UIImage())
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(p.image == nil)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("Your invite link", comment: ""))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(p.url.absoluteString)
                                .font(.footnote)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(NSLocalizedString("OpenGraph preview generated for social apps", comment: "og"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                card {
                    Text(NSLocalizedString("No invite ready. Tap refresh to try again.", comment: "empty"))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: vm.share) {
                    Label(NSLocalizedString("Share", comment: "share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.payload == nil || vm.isLoading)
                .frame(minHeight: buttonH)
                .accessibilityIdentifier("invite_share")

                Button(action: vm.copyLink) {
                    Label(NSLocalizedString("Copy", comment: "copy"), systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.bordered)
                .disabled(vm.payload == nil || vm.isLoading)
                .frame(minHeight: buttonH)
                .accessibilityIdentifier("invite_copy")
            }

            Button(action: vm.toggleQR) {
                Label(vm.showQR ? NSLocalizedString("Hide QR", comment: "hide qr") : NSLocalizedString("Show QR", comment: "show qr"),
                      systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: buttonH)
            .accessibilityIdentifier("invite_toggle_qr")

            if vm.showQR, let url = vm.payload?.url {
                qrCard(for: url)
            }
        }
    }

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Referral status", comment: "status"))
                    .font(.headline)
                HStack {
                    stat(NSLocalizedString("Sent", comment: "sent"), vm.status.invitesSent)
                    stat(NSLocalizedString("Clicks", comment: "clicks"), vm.status.clicks)
                    stat(NSLocalizedString("Sign-ups", comment: "signups"), vm.status.signupsCredited)
                    stat(NSLocalizedString("Rewards", comment: "rewards"), vm.status.rewardsIssued)
                }
                .accessibilityElement(children: .combine)
                if let last = vm.status.lastCreditedAt {
                    Text(String(format: NSLocalizedString("Last reward: %@", comment: "last"), last.formatted(date: .abbreviated, time: .omitted)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !vm.referral.canEarnMoreToday() {
                    Text(NSLocalizedString("Daily reward cap reached. Tomorrow resets.", comment: "cap"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ethicsNote: some View {
        Text(NSLocalizedString("Heads up: No spam, no scraping contacts. Your friend chooses to opt in. Rewards mint once per real sign-up.", comment: "ethics"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }

    // MARK: UI bits

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.title3.bold())
                .accessibilityLabel(Text("\(title): \(value)"))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func qrCard(for url: URL) -> some View {
        card {
            VStack(spacing: 12) {
                QRCodeView(url: url)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel(Text(NSLocalizedString("QR code for your invite link", comment: "")))
                Text(url.absoluteString)
                    .font(.footnote).lineLimit(1).minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Text(NSLocalizedString("Scan with camera to join you on SkateRoute.", comment: "qr hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Toasts

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
        .accessibilityElement(children: .contain)
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
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run(body) }
    }
}

// MARK: - QR code view (high-contrast; no data leakage)

fileprivate struct QRCodeView: View {
    let url: URL
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    var body: some View {
        GeometryReader { geo in
            if let img = makeQR(size: geo.size) {
                Image(uiImage: img).resizable().interpolation(.none).scaledToFit()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
    }
    private func makeQR(size: CGSize) -> UIImage? {
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaleX = size.width / output.extent.size.width
        let scaleY = size.height / output.extent.size.height
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        if let cg = context.createCGImage(transformed, from: transformed.extent) {
            return UIImage(cgImage: cg)
        }
        return nil
    }
}

// MARK: - UIKit share sheet wrapper

fileprivate struct ShareSheetItem: Identifiable { let id = UUID(); let items: [Any] }

fileprivate struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        vc.excludedActivityTypes = [.assignToContact, .saveToCameraRoll] // safe defaults
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Convenience builder

public extension InviteFriendsView {
    static func make(referral: ReferralServing,
                     shareBuilder: SharePayloadBuilding,
                     analytics: AnalyticsLogging?,
                     referrerUserId: String,
                     campaign: String? = "default",
                     routeId: String? = nil,
                     spotId: String? = nil) -> InviteFriendsView {
        let vm = InviteFriendsViewModel(referral: referral,
                                        shareBuilder: shareBuilder,
                                        analytics: analytics,
                                        referrerUserId: referrerUserId,
                                        campaign: campaign)
        vm.routeId = routeId; vm.spotId = spotId
        return InviteFriendsView(viewModel: vm)
    }
}

// MARK: - DEBUG fakes (for previews & UI tests)

#if DEBUG
private final class ReferralServiceFake: ReferralServing {
    private let subject = CurrentValueSubject<ReferralStatus, Never>(
        .init(invitesSent: 12, clicks: 34, signupsCredited: 7, rewardsIssued: 7, lastCreditedAt: Date().addingTimeInterval(-86_400))
    )
    func generateInviteLink(referrerUserId: String, campaign: String?, routeId: String?, spotId: String?) async throws -> URL {
        URL(string: "https://skateroute.app/invite?code=FAKE123&ref=\(referrerUserId)")!
    }
    var statusPublisher: AnyPublisher<ReferralStatus, Never> { subject.eraseToAnyPublisher() }
    func currentStatus() -> ReferralStatus? { subject.value }
    func canEarnMoreToday() -> Bool { true }
}

private final class ShareBuilderFake: SharePayloadBuilding {
    func buildInviteShare(link: URL, title: String, subtitle: String?) async throws -> SharePayload {
        // Simple thumbnail placeholder
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 315))
        let img = renderer.image { ctx in
            UIColor.systemBackground.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 315))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.label
            ]
            title.draw(in: CGRect(x: 24, y: 24, width: 552, height: 120), withAttributes: attrs)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.secondaryLabel
            ]
            (subtitle ?? "").draw(in: CGRect(x: 24, y: 160, width: 552, height: 80), withAttributes: subAttrs)
            UIColor.systemBlue.setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 260, width: 200, height: 28), cornerRadius: 6).fill()
        }
        let text = "Skate with me on SkateRoute 🛹\n\(link.absoluteString)"
        return SharePayload(url: link, image: img, text: text)
    }
}

struct InviteFriendsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            InviteFriendsView.make(referral: ReferralServiceFake(),
                                   shareBuilder: ShareBuilderFake(),
                                   analytics: nil,
                                   referrerUserId: "u_demo",
                                   campaign: "onboarding")
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            InviteFriendsView.make(referral: ReferralServiceFake(),
                                   shareBuilder: ShareBuilderFake(),
                                   analytics: nil,
                                   referrerUserId: "u_demo",
                                   campaign: "map")
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - UITest hooks
// • Accessibility identifiers: "invite_share", "invite_copy", "invite_toggle_qr".
// • QR and link text are selectable; ShareSheet is driven by `shareSheetItem`.

// MARK: - Test plan (unit / UI)
// Unit:
// 1) Payload happy path: ReferralServiceFake returns URL, ShareBuilderFake returns image → vm.payload set, isLoading gates.
// 2) Copy link writes UIPasteboard; info toast pops.
// 3) Status stream mapping: when subject sends new counts → labels update; daily cap notice appears when canEarnMoreToday() == false.
// 4) Error path: generateInviteLink throws → error toast shown; share/QR disabled.
//
// UI:
// • Share button opens UIActivityViewController with text + URL + image.
// • QR toggles on; QR renders at large size and is readable with real devices.
// • Dynamic Type at AX3XL keeps buttons ≥44pt, no clipping.
// • VoiceOver reads: “Invite Friends, Share, Copy, Show QR, Referral status: Sent 12, Clicks 34, Sign-ups 7, Rewards 7”.


