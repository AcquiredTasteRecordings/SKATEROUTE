// Features/Referrals/ReferralLandingView.swift
// Post-link welcome; confirms referral attribution and offers a one-tap join/claim path.
// - Shows who referred you (if referrer display is allowed), campaign blurb, and reward preview.
// - One primary CTA that adapts: “Join Challenge” (if campaign) or “Claim Reward” (if reward grant).
// - Safe defaults: no PII shown without consent; handles already-credited + expired tokens gracefully.
// - A11y: Dynamic Type, ≥44pt hit targets, clear VO labels/hints, high-contrast friendly.
// - Privacy: no tracking; optional Analytics façade logs coarse events only.

// Expected deep link (example):
//   skateroute://referral?token=abc123&campaign=fall_jam
// ReferralService resolves token → ReferralAttribution with integrity flags.
// RewardsWallet mints invite reward (once), ChallengeEngine enrolls user (idempotent join).

import SwiftUI
import Combine

// MARK: - DI seams (narrow, testable)

public struct ReferralAttribution: Sendable, Equatable {
    public enum Status: Equatable { case pending, credited, expired, invalid }
    public let token: String
    public let campaign: String?
    public let referrerDisplayName: String? // Optional, subject to privacy settings
    public let previewRewardTitle: String?  // e.g., “Deck Sticker Pack” or “Pro Trial”
    public let status: Status
    public let isEligibleForReward: Bool
    public let isEligibleForChallenge: Bool
}

public protocol ReferralResolving: AnyObject {
    /// Resolve and (server-side) tentatively attribute this device/user to the referral token.
    /// Safe to call multiple times (idempotent on backend).
    func resolve(token: String) async throws -> ReferralAttribution

    /// Finalize attribution on sign-up or explicit user confirmation (idempotent).
    func confirmAttribution(token: String) async throws -> ReferralAttribution
}

public enum RewardClaimResult: Equatable { case minted(badgeId: String?), alreadyClaimed, ineligible, expired }
public protocol RewardsWalletServing: AnyObject {
    func claimReferralReward(token: String) async throws -> RewardClaimResult
}

public protocol ChallengeJoining: AnyObject {
    /// Joins the user into a campaign challenge (no-op if already joined).
    func joinChallenge(campaignId: String) async throws -> Bool
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
public enum AnalyticsValue: Sendable, Hashable { case string(String), bool(Bool) }

// MARK: - ViewModel

@MainActor
public final class ReferralLandingViewModel: ObservableObject {

    @Published public private(set) var attribution: ReferralAttribution?
    @Published public private(set) var isLoading = false
    @Published public private(set) var ctaInFlight = false

    @Published public var infoMessage: String?
    @Published public var errorMessage: String?

    public enum CTAKind: Equatable { case claimReward, joinChallenge, done, none }

    private let token: String
    private let resolver: ReferralResolving
    private let rewards: RewardsWalletServing
    private let challenges: ChallengeJoining
    private let analytics: AnalyticsLogging?

    public init(token: String,
                resolver: ReferralResolving,
                rewards: RewardsWalletServing,
                challenges: ChallengeJoining,
                analytics: AnalyticsLogging? = nil) {
        self.token = token
        self.resolver = resolver
        self.rewards = rewards
        self.challenges = challenges
        self.analytics = analytics
    }

    public func onAppear() {
        Task { await resolve() }
    }

    public func resolve() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let a = try await resolver.resolve(token: token)
            self.attribution = a
            analytics?.log(.init(name: "referral_landing_resolved", category: .referrals,
                                 params: ["status": .string(String(describing: a.status)),
                                          "campaign": .string(a.campaign ?? "none")]))
        } catch {
            errorMessage = NSLocalizedString("This invite link couldn’t be verified. Try again later.", comment: "resolve fail")
        }
    }

    public var ctaKind: CTAKind {
        guard let a = attribution else { return .none }
        if a.status == .expired || a.status == .invalid { return .done }
        if a.isEligibleForReward { return .claimReward }
        if a.isEligibleForChallenge, a.campaign != nil { return .joinChallenge }
        return .done
    }

    public var titleText: String {
        guard let a = attribution else { return NSLocalizedString("Welcome", comment: "fallback title") }
        switch a.status {
        case .pending, .credited:
            if let name = a.referrerDisplayName {
                return String(format: NSLocalizedString("%@ invited you", comment: "title w/ name"), name)
            } else {
                return NSLocalizedString("You’ve been invited", comment: "title anon")
            }
        case .expired:
            return NSLocalizedString("This invite expired", comment: "title expired")
        case .invalid:
            return NSLocalizedString("Invalid invite", comment: "title invalid")
        }
    }

    public var subtitleText: String {
        guard let a = attribution else { return "" }
        if let r = a.previewRewardTitle, a.isEligibleForReward {
            return String(format: NSLocalizedString("Claim your reward: %@", comment: "reward subtitle"), r)
        }
        if let c = a.campaign, a.isEligibleForChallenge {
            return String(format: NSLocalizedString("Join the %@ challenge and start skating.", comment: "challenge subtitle"), c)
        }
        switch a.status {
        case .credited:
            return NSLocalizedString("You’re all set. Attribution confirmed.", comment: "credited")
        case .expired:
            return NSLocalizedString("Invite is past its window. You can still use the app—no worries.", comment: "expired")
        case .invalid:
            return NSLocalizedString("We couldn’t validate this link.", comment: "invalid")
        default:
            return NSLocalizedString("Skate smarter with hazard alerts and community spots.", comment: "generic")
        }
    }

    public func primaryAction() {
        guard let a = attribution else { return }
        analytics?.log(.init(name: "referral_landing_cta", category: .referrals,
                             params: ["cta": .string(String(describing: ctaKind))]))
        Task { await runCTA(for: a) }
    }

    private func runCTA(for a: ReferralAttribution) async {
        ctaInFlight = true
        defer { ctaInFlight = false }
        do {
            // Confirm attribution (idempotent) before any grant/join.
            let confirmed = try await resolver.confirmAttribution(token: token)
            self.attribution = confirmed

            switch ctaKind {
            case .claimReward:
                let result = try await rewards.claimReferralReward(token: token)
                switch result {
                case .minted:
                    infoMessage = NSLocalizedString("Reward unlocked. Check your Wallet.", comment: "minted")
                case .alreadyClaimed:
                    infoMessage = NSLocalizedString("Already claimed on this account.", comment: "already")
                case .ineligible:
                    errorMessage = NSLocalizedString("Not eligible to claim on this device/account.", comment: "ineligible")
                case .expired:
                    errorMessage = NSLocalizedString("This reward has expired.", comment: "expired reward")
                }
            case .joinChallenge:
                if let campaign = confirmed.campaign {
                    let joined = try await challenges.joinChallenge(campaignId: campaign)
                    if joined {
                        infoMessage = String(format: NSLocalizedString("You joined %@. Let’s roll!", comment: "joined"), campaign)
                    } else {
                        infoMessage = NSLocalizedString("You’re already in. Keep skating!", comment: "already in")
                    }
                }
            case .done, .none:
                infoMessage = NSLocalizedString("You’re good to go.", comment: "done")
            }
        } catch {
            errorMessage = NSLocalizedString("Couldn’t complete this action. Check your connection.", comment: "cta fail")
        }
    }
}

// MARK: - View

public struct ReferralLandingView: View {
    @ObservedObject private var vm: ReferralLandingViewModel
    @Environment(\.dismiss) private var dismiss

    private let corner: CGFloat = 16
    private let buttonH: CGFloat = 54

    public init(viewModel: ReferralLandingViewModel) { self.vm = viewModel }

    public var body: some View {
        VStack(spacing: 16) {
            header
            infoCard
            Spacer(minLength: 8)
            primaryCTA
            secondaryHelp
        }
        .padding(16)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(Text(NSLocalizedString("Welcome", comment: "nav title")))
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
        .accessibilityElement(children: .contain)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.titleText)
                .font(.largeTitle.bold())
                .accessibilityLabel(Text(vm.titleText))
            Text(vm.subtitleText)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var infoCard: some View {
        Group {
            if vm.isLoading {
                card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(NSLocalizedString("Checking your invite…", comment: "resolve"))
                    }
                }
            } else if let a = vm.attribution {
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        if let name = a.referrerDisplayName {
                            labeledRow(label: NSLocalizedString("From", comment: "from"), value: name)
                        }
                        labeledRow(label: NSLocalizedString("Status", comment: "status"),
                                   value: statusText(a.status))
                        if let r = a.previewRewardTitle, a.isEligibleForReward {
                            labeledRow(label: NSLocalizedString("Reward", comment: "reward"), value: r)
                        }
                        if let c = a.campaign, a.isEligibleForChallenge {
                            labeledRow(label: NSLocalizedString("Challenge", comment: "campaign"), value: c)
                        }
                    }
                }
            } else {
                card {
                    Text(NSLocalizedString("No invite details yet.", comment: "empty"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusText(_ s: ReferralAttribution.Status) -> String {
        switch s {
        case .pending: return NSLocalizedString("Pending confirmation", comment: "pending")
        case .credited: return NSLocalizedString("Credited", comment: "credited")
        case .expired: return NSLocalizedString("Expired", comment: "expired")
        case .invalid: return NSLocalizedString("Invalid", comment: "invalid")
        }
    }

    private func labeledRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value)"))
    }

    private var primaryCTA: some View {
        Button(action: vm.primaryAction) {
            HStack {
                if vm.ctaInFlight { ProgressView().controlSize(.large) }
                Text(ctaTitle())
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16) // ≥44pt
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, minHeight: buttonH)
        .disabled(vm.ctaKind == .none || vm.ctaKind == .done || vm.ctaInFlight || vm.attribution == nil)
        .accessibilityIdentifier("referral_primary_cta")
        .accessibilityLabel(Text(ctaTitle()))
        .padding(.top, 4)
    }

    private func ctaTitle() -> String {
        switch vm.ctaKind {
        case .claimReward: return NSLocalizedString("Claim Reward", comment: "cta reward")
        case .joinChallenge: return NSLocalizedString("Join Challenge", comment: "cta challenge")
        case .done: return NSLocalizedString("Continue", comment: "cta done")
        case .none: return NSLocalizedString("Loading…", comment: "cta loading")
        }
    }

    private var secondaryHelp: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("We only credit real sign-ups. No spam. No tracking.", comment: "ethics"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                // Give users an escape hatch.
                self.dismiss()
            } label: {
                Text(NSLocalizedString("Skip for now", comment: "skip"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("referral_skip")
        }
        .padding(.top, 4)
    }

    // MARK: UI bits

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: Toasts

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                banner(text: msg, system: "exclamationmark.triangle.fill", background: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                banner(text: info, system: "checkmark.seal.fill", background: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
        .accessibilityElement(children: .contain)
    }

    private func banner(text: String, system: String, background: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(background.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run(body) }
    }
}

// MARK: - Convenience builder

public extension ReferralLandingView {
    static func make(token: String,
                     resolver: ReferralResolving,
                     rewards: RewardsWalletServing,
                     challenges: ChallengeJoining,
                     analytics: AnalyticsLogging? = nil) -> ReferralLandingView {
        ReferralLandingView(viewModel: .init(token: token,
                                             resolver: resolver,
                                             rewards: rewards,
                                             challenges: challenges,
                                             analytics: analytics))
    }
}

// MARK: - DEBUG fakes (previews)

#if DEBUG
private final class ResolverFake: ReferralResolving {
    func resolve(token: String) async throws -> ReferralAttribution {
        ReferralAttribution(token: token, campaign: "week_ride",
                            referrerDisplayName: "Alex",
                            previewRewardTitle: "Pro Trial (7 days)",
                            status: .pending, isEligibleForReward: true, isEligibleForChallenge: true)
    }
    func confirmAttribution(token: String) async throws -> ReferralAttribution {
        ReferralAttribution(token: token, campaign: "week_ride",
                            referrerDisplayName: "Alex",
                            previewRewardTitle: "Pro Trial (7 days)",
                            status: .credited, isEligibleForReward: true, isEligibleForChallenge: true)
    }
}
private final class RewardsFake: RewardsWalletServing {
    func claimReferralReward(token: String) async throws -> RewardClaimResult { .minted(badgeId: "badge.invite") }
}
private final class ChallengesFake: ChallengeJoining {
    func joinChallenge(campaignId: String) async throws -> Bool { true }
}

struct ReferralLandingView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ReferralLandingView.make(token: "FAKE123",
                                     resolver: ResolverFake(),
                                     rewards: RewardsFake(),
                                     challenges: ChallengesFake(),
                                     analytics: nil)
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            ReferralLandingView.make(token: "FAKE123",
                                     resolver: ResolverFake(),
                                     rewards: RewardsFake(),
                                     challenges: ChallengesFake(),
                                     analytics: nil)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • AppCoordinator handles universal link → extract `token` (& optional campaign) → push `ReferralLandingView.make(...)`.
// • ReferralService should implement ReferralResolving (resolve + confirm) and enforce fraud guardrails already specified.
// • RewardsWallet implements claimReferralReward(token:) with single-claim guarantees; updates wallet UI after success.
// • ChallengeEngine implements joinChallenge(campaignId:) with idempotent joins; emits progress to ChallengesView.
// • After CTA success, you can dismiss or route to the relevant tab (Challenges/Rewards) via coordinator.
// • Accessibility: VO reads the dynamic title, status, and a single primary CTA. All buttons are ≥44pt and scale with Dynamic Type.

// MARK: - Test plan (unit / UI)
// Unit:
// 1) Resolve happy path: ResolverFake returns .pending → title/subtitle reflect eligibility.
// 2) Claim reward: confirmAttribution → claimReferralReward → info toast “Reward unlocked”; calling again → alreadyClaimed → info accordingly.
// 3) Join challenge: returns true → “You joined <campaign>”; second call returns false → “already in”.
// 4) Expired/invalid tokens: set attribution.status accordingly → primary CTA becomes “Continue” and is disabled or no-op.
// UI:
// • Snapshot with AX sizes; no clipping; CTAs accessible.
// • VO order: title → subtitle → info card rows → primary CTA → skip.
// • Deep link E2E: open universal link → landing view resolves → primary CTA → wallet/challenges updated.


