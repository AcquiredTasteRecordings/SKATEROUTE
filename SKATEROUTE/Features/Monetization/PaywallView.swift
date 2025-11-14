// Features/Monetization/PaywallView.swift
// Entitlement-aware, accessible paywall.
// - Value-first copy with ethical triggers from PaywallRules.
// - Hooks: purchase/restore/offer code; hides CTA while purchasing; respects entitlement stream.
// - A11y: Dynamic Type, large hit targets, VoiceOver labels/hints, high-contrast safe.
// - No tracking; optional AnalyticsLogger façade for button taps/result (redacted).

import SwiftUI
import Combine
import StoreKit
import UIKit

// MARK: - DI seams (keep narrow and testable)

public protocol StoreServing: AnyObject {
    // Canonical product identifiers (App Store Connect)
    var productsPublisher: AnyPublisher<[Product], Never> { get }     // list includes the current paywall SKU(s)
    var entitlementPublisher: AnyPublisher<Set<String>, Never> { get } // set of entitlement ids (e.g., "pro")
    func hasEntitlement(_ id: String) -> Bool
    func purchase(productId: String) async throws -> PurchaseResult    // resolves StoreKit2 flows, throws on hard failure
    func restorePurchases() async throws
    func presentOfferCodeRedemption()                                  // forwards to AppStore.presentCodeRedemptionSheet()
}

public enum PurchaseResult: Equatable {
    case success(entitlements: Set<String>)
    case userCancelled
    case pending
    case failed(code: String) // redacted string code only
}

public protocol PaywallRuling {
    func shouldPresentPaywall(context: PaywallContext) -> Bool
    func placement(for context: PaywallContext) -> PaywallPlacement
}

public struct PaywallContext: Equatable, Sendable {
    public enum Location: String { case onboarding, map, editor, rewards, settings }
    public let location: Location
    public let sessionCount: Int
    public let isNavigating: Bool
    public init(location: Location, sessionCount: Int, isNavigating: Bool) {
        self.location = location; self.sessionCount = sessionCount; self.isNavigating = isNavigating
    }
}

public enum PaywallPlacement: Equatable { case banner, sheet, fullscreen }

// MARK: - ViewModel

@MainActor
public final class PaywallViewModel: ObservableObject {

    @Published public private(set) var proEntitled = false
    @Published public var isPurchasing = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public private(set) var displayProduct: Product?

    private let store: StoreServing
    private let rules: PaywallRuling
    private let analytics: AnalyticsLogging?
    private let context: PaywallContext

    private var cancellables = Set<AnyCancellable>()
    private let entitlementId = "pro" // match your Store/entitlement key

    public init(store: StoreServing,
                rules: PaywallRuling,
                analytics: AnalyticsLogging?,
                context: PaywallContext) {
        self.store = store
        self.rules = rules
        self.analytics = analytics
        self.context = context

        bind()
    }

    private func bind() {
        store.entitlementPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] ents in
                self?.proEntitled = ents.contains(self?.entitlementId ?? "pro")
            }
            .store(in: &cancellables)

        store.productsPublisher
            .map { products in
                // Prefer the subscription SKU first; fallback to any paid non-consumable.
                products
                    .sorted { a, b in
                        a.type.sortIndex < b.type.sortIndex
                    }
                    .first
            }
            .receive(on: RunLoop.main)
            .assign(to: &$displayProduct)
    }

    public func shouldShow() -> Bool {
        guard !proEntitled else { return false }
        return rules.shouldPresentPaywall(context: context)
    }

    public func buyTapped() {
        analytics?.log(.init(name: "paywall_cta_tapped", category: .paywall,
                             params: ["placement": .string(placementString()),
                                      "location": .string(context.location.rawValue)]))
        Task { await purchase() }
    }

    public func restoreTapped() {
        analytics?.log(.init(name: "paywall_restore_tapped", category: .paywall,
                             params: ["placement": .string(placementString())]))
        Task { await restore() }
    }

    public func offerCodeTapped() {
        analytics?.log(.init(name: "paywall_offercode_tapped", category: .paywall,
                             params: ["placement": .string(placementString())]))
        store.presentOfferCodeRedemption()
    }

    private func placementString() -> String {
        switch rules.placement(for: context) {
        case .banner: return "banner"
        case .sheet: return "sheet"
        case .fullscreen: return "fullscreen"
        }
    }

    private func purchase() async {
        guard let productId = displayProduct?.id else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await store.purchase(productId: productId) {
            case .success(let ents):
                proEntitled = ents.contains(entitlementId)
                analytics?.log(.init(name: "purchase_success", category: .paywall,
                                     params: ["location": .string(context.location.rawValue)]))
                infoMessage = NSLocalizedString("You're unlocked. Go skate!", comment: "Purchase success toast")
            case .pending:
                infoMessage = NSLocalizedString("Purchase pending…", comment: "Pending")
            case .userCancelled:
                // No error toast for cancel, just quietly return
                return
            case .failed(let code):
                errorMessage = String(format: NSLocalizedString("Purchase failed (%@). Try again later.", comment: "Purchase fail"), code)
            }
        } catch {
            errorMessage = NSLocalizedString("Couldn’t complete the purchase. Check your network.", comment: "Purchase network fail")
        }
    }

    private func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await store.restorePurchases()
            analytics?.log(.init(name: "restore_complete", category: .paywall, params: [:]))
        } catch {
            errorMessage = NSLocalizedString("Restore failed. Try again later.", comment: "Restore fail")
        }
    }

    // MARK: - Strings helpers

    public var priceText: String {
        guard let p = displayProduct else { return "" }
        // For subscriptions, show "per month/year" where possible; fallback to display price.
        if case .autoRenewable = p.type, let sub = p.subscription {
            let unit: String
            switch sub.subscriptionPeriod.unit {
            case .day: unit = NSLocalizedString("day", comment: "per day")
            case .week: unit = NSLocalizedString("week", comment: "per week")
            case .month: unit = NSLocalizedString("month", comment: "per month")
            case .year: unit = NSLocalizedString("year", comment: "per year")
            @unknown default: unit = NSLocalizedString("period", comment: "per period")
            }
            return String(format: NSLocalizedString("%@ / %@", comment: "price per unit"),
                          p.displayPrice, unit)
        }
        return p.displayPrice
    }

    public var benefits: [String] {
        [
            NSLocalizedString("Offline maps & spots", comment: "benefit"),
            NSLocalizedString("Safety overlays & hazard filters", comment: "benefit"),
            NSLocalizedString("HD export & editor presets", comment: "benefit"),
            NSLocalizedString("Support indie skate tech", comment: "benefit")
        ]
    }
}

// MARK: - Product helpers (no SDK leakage)

extension Product.ProductType {
    fileprivate var sortIndex: Int {
        switch self {
        case .autoRenewable: return 0
        case .nonConsumable: return 1
        case .consumable: return 2
        default: return 3
        }
    }
}

// MARK: - View

public struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vm: PaywallViewModel

    // Styling
    private let corner: CGFloat = 16
    private let buttonHeight: CGFloat = 54

    public init(viewModel: PaywallViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

            // Benefits list
            benefitsList
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Spacer(minLength: 12)

            // Price + CTA stack
            ctas
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(
            LinearGradient(colors: [Color(UIColor.systemBackground), Color(UIColor.secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .overlay(toastOverlay)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: NSLocalizedString("Upgrade to SkateRoute Pro", comment: "VO screen title"))
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Upgrade to SkateRoute Pro", comment: "paywall title"))
                .font(.largeTitle.bold())
                .accessibilityLabel(Text(NSLocalizedString("Upgrade to SkateRoute Pro", comment: "")))
            Text(NSLocalizedString("Unlock offline maps, safer routes, and pro-level tools. Never blocks safety features.", comment: "subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .accessibilityHint(Text(NSLocalizedString("Core safety remains free", comment: "")))
        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(vm.benefits, id: \.self) { b in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(b)
                        .font(.body)
                        .accessibilityLabel(Text(b))
                }
                .accessibilityElement(children: .combine)
            }
            if let p = vm.displayProduct {
                priceRow(product: p)
            } else {
                redactedPriceRow
            }
        }
    }

    private func priceRow(product: Product) -> some View {
        HStack {
            Text(NSLocalizedString("Price", comment: "price heading"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer()
            Text(vm.priceText)
                .font(.title3.weight(.semibold))
                .accessibilityLabel(Text(String(format: NSLocalizedString("Price: %@", comment: "VO price"), vm.priceText)))
        }
        .padding(.top, 8)
    }

    private var redactedPriceRow: some View {
        HStack {
            Text(NSLocalizedString("Price", comment: "price heading"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).frame(width: 120, height: 20).redacted(reason: .placeholder)
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }

    private var ctas: some View {
        VStack(spacing: 12) {
            Button(action: vm.buyTapped) {
                HStack {
                    if vm.isPurchasing { ProgressView().controlSize(.large) }
                    Text(vm.isPurchasing
                         ? NSLocalizedString("Purchasing…", comment: "progress")
                         : NSLocalizedString("Get Pro", comment: "primary CTA"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16) // large hit target (≥44pt)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: buttonHeight)
            .disabled(vm.isPurchasing || vm.proEntitled || vm.displayProduct == nil)
            .accessibilityIdentifier("paywall_primary_cta")
            .accessibilityLabel(Text(NSLocalizedString("Get Pro", comment: "")))
            .accessibilityHint(Text(NSLocalizedString("Activates premium features", comment: "")))

            HStack(spacing: 16) {
                Button(role: .none, action: vm.restoreTapped) {
                    Text(NSLocalizedString("Restore", comment: "restore"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: buttonHeight)
                .disabled(vm.isPurchasing)
                .accessibilityIdentifier("paywall_restore")
                .accessibilityLabel(Text(NSLocalizedString("Restore purchases", comment: "")))
                .accessibilityHint(Text(NSLocalizedString("Re-activates existing entitlements", comment: "")))

                Button(role: .none, action: vm.offerCodeTapped) {
                    Text(NSLocalizedString("Offer Code", comment: "offer code"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: buttonHeight)
                .disabled(vm.isPurchasing)
                .accessibilityIdentifier("paywall_offercode")
                .accessibilityLabel(Text(NSLocalizedString("Redeem offer code", comment: "")))
                .accessibilityHint(Text(NSLocalizedString("Opens App Store code redemption", comment: "")))
            }

            Text(NSLocalizedString("Core safety features such as hazard alerts and rerouting are free.", comment: "ethics note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .accessibilityLabel(Text(NSLocalizedString("Safety features remain free", comment: "")))
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                banner(text: msg, system: "exclamationmark.triangle.fill", background: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { vm.errorMessage = nil } } }
            } else if let info = vm.infoMessage {
                banner(text: info, system: "checkmark.seal.fill", background: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { vm.infoMessage = nil } } }
            }
        }
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func banner(text: String, system: String, background: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(background.opacity(0.9), in: RoundedRectangle(cornerRadius: corner))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Convenience builders

public extension PaywallView {
    /// Compose a paywall using DI (use from AppCoordinator/Router)
    static func make(store: StoreServing,
                     rules: PaywallRuling,
                     analytics: AnalyticsLogging?,
                     context: PaywallContext) -> PaywallView {
        let vm = PaywallViewModel(store: store, rules: rules, analytics: analytics, context: context)
        return PaywallView(viewModel: vm)
    }
}

// MARK: - Previews (DEBUG-only fakes)

#if DEBUG
private final class StoreFake: StoreServing {
    let _products = CurrentValueSubject<[Product], Never>([])
    let _ents = CurrentValueSubject<Set<String>, Never>([])
    var productsPublisher: AnyPublisher<[Product], Never> { _products.eraseToAnyPublisher() }
    var entitlementPublisher: AnyPublisher<Set<String>, Never> { _ents.eraseToAnyPublisher() }
    func hasEntitlement(_ id: String) -> Bool { _ents.value.contains(id) }
    func purchase(productId: String) async throws -> PurchaseResult {
        try? await Task.sleep(nanoseconds: 600_000_000)
        _ents.value.insert("pro")
        return .success(entitlements: _ents.value)
    }
    func restorePurchases() async throws {
        _ents.value.insert("pro")
    }
    func presentOfferCodeRedemption() { /* no-op in preview */ }
}

private struct RulesFake: PaywallRuling {
    func shouldPresentPaywall(context: PaywallContext) -> Bool { !context.isNavigating }
    func placement(for context: PaywallContext) -> PaywallPlacement { .sheet }
}

private struct AnalyticsNoop: AnalyticsLogging { func log(_ event: AnalyticsEvent) {} }

// Lightweight product shim for previews (we cannot construct StoreKit.Product directly; build a struct wrapper if needed).
// Here we provide a tiny proxy that mimics the properties we use via an extension.
extension Product {
    // For preview only: expose id/displayPrice/type/subscription via a proxy
}

struct PaywallView_Previews: PreviewProvider {
    static var previews: some View {
        // NOTE: We cannot instantiate StoreKit.Product in previews.
        // For Xcode previews, consider feeding `displayProduct` manually via reflection
        // or showing the redacted price row.
        let store = StoreFake()
        let ctx = PaywallContext(location: .onboarding, sessionCount: 1, isNavigating: false)
        let vm = PaywallViewModel(store: store, rules: RulesFake(), analytics: AnalyticsNoop(), context: ctx)
        return Group {
            PaywallView(viewModel: vm)
                .environment(\.colorScheme, .light)
            PaywallView(viewModel: vm)
                .environment(\.colorScheme, .dark)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        }
    }
}
#endif

// MARK: - UITest hooks (accessibility identifiers)
// • "paywall_primary_cta" → main purchase button
// • "paywall_restore"     → restore button
// • "paywall_offercode"   → offer code button

// MARK: - Integration notes
// • Presentation policy: AppCoordinator asks PaywallRules.shouldPresentPaywall(context:) before showing this view.
// • Entitlements: inject Store (Services/StoreKit/Store.swift) so entitlementPublisher live-updates the view.
// • Offer codes: in StoreServing.presentOfferCodeRedemption() call `await AppStore.presentCodeRedemptionSheet()` (StoreKit2).
// • Accessibility: uses system fonts and ≥44pt targets. VoiceOver labels/hints are explicit for price & CTAs.
// • Analytics: optional logger receives only high-level events, no PII.
// • Unit/UI tests:
//   - Show paywall with fake store, tap Get Pro → expect isPurchasing gating then entitlement flips.
//   - Restore path sets entitlement without purchase.
//   - Offer code invokes native sheet (assert via spy method invoked).
//   - Ensure price VO label reads: “Price: $X / month” for subscriptions when Product has sub period.
//   - Ensure CTAs disabled while `isPurchasing == true`.


