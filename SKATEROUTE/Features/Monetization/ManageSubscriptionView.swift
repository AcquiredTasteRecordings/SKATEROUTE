// Features/Monetization/ManageSubscriptionView.swift
// System manage UI deep link (App Store), with restore + purchase history snippet.
// - Zero dark patterns: this is the “easy cancel / manage” surface.
// - Integrates with Store (manageSubscriptionsURL, entitlement stream, restore(), history()).
// - A11y: Dynamic Type, ≥44pt targets, VoiceOver labels/hints, high-contrast safe.
// - No tracking; optional AnalyticsLogger façade logs only generic taps (no PII).

import SwiftUI
import Combine
import StoreKit
import ServicesAnalytics
import UIKit

// MARK: - DI seams (narrow & testable)

public protocol ManageSubscriptionsURLProviding: AnyObject {
    /// System URL to Apple's Manage Subscriptions (StoreKit 2: `await AppStore.showManageSubscriptions()`; here we open the URL if provided)
    var manageSubscriptionsURL: URL? { get }
}

public enum PurchaseStatus: String, Sendable {
    case active, expired, refunded, revoked, pending, unknown
}

public struct PurchaseRecord: Identifiable, Sendable, Equatable {
    public var id: String { transactionId }
    public let transactionId: String
    public let productId: String
    public let purchaseDate: Date
    public let status: PurchaseStatus
}

public protocol PurchaseHistoryProviding: AnyObject {
    var entitlementPublisher: AnyPublisher<Set<String>, Never> { get }
    func restorePurchases() async throws
    func fetchPurchaseHistory(limit: Int) async -> [PurchaseRecord]   // redacted records (no price / region)
}

// MARK: - ViewModel

@MainActor
public final class ManageSubscriptionViewModel: ObservableObject {
    @Published public private(set) var isProActive = false
    @Published public private(set) var history: [PurchaseRecord] = []
    @Published public var isRestoring = false
    @Published public var infoMessage: String?
    @Published public var errorMessage: String?

    private let store: PurchaseHistoryProviding & ManageSubscriptionsURLProviding
    private let analytics: AnalyticsLogging?
    private var cancellables = Set<AnyCancellable>()

    public init(store: PurchaseHistoryProviding & ManageSubscriptionsURLProviding,
                analytics: AnalyticsLogging? = nil) {
        self.store = store
        self.analytics = analytics
        bind()
    }

    private func bind() {
        store.entitlementPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] ents in
                self?.isProActive = ents.contains("pro")
            }
            .store(in: &cancellables)
    }

    public func onAppear() {
        Task { await loadHistory() }
    }

    public func openManage() {
        analytics?.log(.init(name: "manage_subs_open", category: .paywall, params: [:]))
        if let url = store.manageSubscriptionsURL {
            UIApplication.shared.open(url)
        } else {
            // Fallback for iOS 16+ if URL not provided: attempt native sheet (non-blocking).
            if #available(iOS 16.0, *) {
                Task { try? await AppStore.showManageSubscriptions() }
            } else {
                errorMessage = NSLocalizedString("Unable to open subscriptions. Update iOS to manage.", comment: "manage fallback")
            }
        }
    }

    public func restore() {
        analytics?.log(.init(name: "manage_subs_restore", category: .paywall, params: [:]))
        Task {
            isRestoring = true
            defer { isRestoring = false }
            do {
                try await store.restorePurchases()
                infoMessage = NSLocalizedString("Restore complete.", comment: "restore success")
                await loadHistory()
            } catch {
                errorMessage = NSLocalizedString("Restore failed. Try again later.", comment: "restore failed")
            }
        }
    }

    private func loadHistory() async {
        let items = await store.fetchPurchaseHistory(limit: 10)
        await MainActor.run { self.history = items }
    }

    // MARK: - Formatters

    public func statusText(for s: PurchaseStatus) -> String {
        switch s {
        case .active: return NSLocalizedString("Active", comment: "status")
        case .expired: return NSLocalizedString("Expired", comment: "status")
        case .refunded: return NSLocalizedString("Refunded", comment: "status")
        case .revoked: return NSLocalizedString("Revoked", comment: "status")
        case .pending: return NSLocalizedString("Pending", comment: "status")
        case .unknown: return NSLocalizedString("Unknown", comment: "status")
        }
    }

    public func statusColor(for s: PurchaseStatus) -> Color {
        switch s {
        case .active: return .green
        case .pending: return .orange
        case .expired, .refunded, .revoked: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - View

public struct ManageSubscriptionView: View {
    @ObservedObject private var vm: ManageSubscriptionViewModel
    @Environment(\.dismiss) private var dismiss

    private let buttonHeight: CGFloat = 54
    private let corner: CGFloat = 14

    public init(viewModel: ManageSubscriptionViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        List {
            sectionHeader
            statusSection
            historySection
            helpSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Manage Subscription", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: vm.openManage) {
                    Label(NSLocalizedString("Open App Store", comment: "open manage"), systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("manage_open_store")
                .accessibilityLabel(Text(NSLocalizedString("Open App Store Subscriptions", comment: "VO")))
            }
        }
        .safeAreaInset(edge: .bottom) { bottomActions }
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
    }

    private var sectionHeader: some View {
        Section {
            Text(NSLocalizedString("SkateRoute Pro is billed by Apple. Manage, cancel, or change plan in your App Store account.", comment: "explainer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(NSLocalizedString("Manage in App Store", comment: "VO explainer")))
        }
    }

    private var statusSection: some View {
        Section(header: Text(NSLocalizedString("Status", comment: "status header"))) {
            HStack {
                Label {
                    Text(vm.isProActive ? NSLocalizedString("Pro is active", comment: "active") :
                          NSLocalizedString("Pro is not active", comment: "inactive"))
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: vm.isProActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.isProActive ? .green : .orange)
                        .accessibilityHidden(true)
                }
                Spacer()
                Button(action: vm.restore) {
                    if vm.isRestoring { ProgressView().controlSize(.regular) }
                    Text(vm.isRestoring ? NSLocalizedString("Restoring…", comment: "") :
                         NSLocalizedString("Restore", comment: "restore"))
                }
                .buttonStyle(.bordered)
                .disabled(vm.isRestoring)
                .accessibilityIdentifier("manage_restore")
                .accessibilityHint(Text(NSLocalizedString("Re-activates existing purchases", comment: "")))
            }
            .contentShape(Rectangle())
        }
    }

    private var historySection: some View {
        Section(header: Text(NSLocalizedString("Purchase History", comment: "history header"))) {
            if vm.history.isEmpty {
                Text(NSLocalizedString("No recent purchases found.", comment: "empty history"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.history.prefix(5)) { rec in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.productId)
                                .font(.subheadline.weight(.semibold))
                                .accessibilityLabel(Text(String(format: NSLocalizedString("Product: %@", comment: ""), rec.productId)))
                            Text(rec.purchaseDate, style: .date)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(rec.purchaseDate.formatted(date: .abbreviated, time: .omitted)))
                        }
                        Spacer()
                        Text(vm.statusText(for: rec.status))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(vm.statusColor(for: rec.status))
                            .accessibilityLabel(Text(vm.statusText(for: rec.status)))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("history_row_\(rec.id)")
                }

                if vm.history.count > 5 {
                    Text(String(format: NSLocalizedString("And %d more…", comment: "more count"), vm.history.count - 5))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var helpSection: some View {
        Section(header: Text(NSLocalizedString("Help", comment: "help header"))) {
            Link(destination: URL(string: "https://support.apple.com/billing")!) {
                Label(NSLocalizedString("Apple Billing Support", comment: "billing link"),
                      systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("manage_billing_support")

            Link(destination: URL(string: "https://support.apple.com/en-us/HT202039")!) {
                Label(NSLocalizedString("Request a Refund", comment: "refund link"),
                      systemImage: "arrow.uturn.left.circle")
            }
            .accessibilityIdentifier("manage_refund_link")
        }
    }

    private var bottomActions: some View {
        Button(action: vm.openManage) {
            HStack {
                Image(systemName: "creditcard")
                    .accessibilityHidden(true)
                Text(NSLocalizedString("Manage in App Store", comment: "manage CTA"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, minHeight: buttonHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("manage_primary_cta")
        .accessibilityHint(Text(NSLocalizedString("Opens App Store subscriptions page", comment: "")))
    }

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                banner(text: msg, system: "exclamationmark.triangle.fill", background: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let info = vm.infoMessage {
                banner(text: info, system: "checkmark.seal.fill", background: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .background(background.opacity(0.92), in: RoundedRectangle(cornerRadius: corner))
        .foregroundColor(.white)
        .onAppear { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { vm.errorMessage = nil; vm.infoMessage = nil } } }
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Convenience builder

public extension ManageSubscriptionView {
    static func make(store: PurchaseHistoryProviding & ManageSubscriptionsURLProviding,
                     analytics: AnalyticsLogging? = nil) -> ManageSubscriptionView {
        ManageSubscriptionView(viewModel: .init(store: store, analytics: analytics))
    }
}

// MARK: - DEBUG Previews

#if DEBUG
private final class StoreManageFake: PurchaseHistoryProviding, ManageSubscriptionsURLProviding {
    var entitlementPublisher: AnyPublisher<Set<String>, Never> { ents.eraseToAnyPublisher() }
    private let ents = CurrentValueSubject<Set<String>, Never>(["pro"])
    var manageSubscriptionsURL: URL? { URL(string: "https://apps.apple.com/account/subscriptions")! }
    func restorePurchases() async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
        ents.send(["pro"])
    }
    func fetchPurchaseHistory(limit: Int) async -> [PurchaseRecord] {
        [
            PurchaseRecord(transactionId: "T1", productId: "pro.monthly", purchaseDate: Date().addingTimeInterval(-86400*10), status: .active),
            PurchaseRecord(transactionId: "T0", productId: "pro.trial", purchaseDate: Date().addingTimeInterval(-86400*40), status: .expired)
        ]
    }
}
struct ManageSubscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ManageSubscriptionView.make(store: StoreManageFake(), analytics: AnalyticsLoggerSpy())
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        NavigationView {
            ManageSubscriptionView.make(store: StoreManageFake(), analytics: AnalyticsLoggerSpy())
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • AppDI: expose your Store as a single instance that conforms to `PurchaseHistoryProviding & ManageSubscriptionsURLProviding`.
//   - StoreKit2 provides native management via `await AppStore.showManageSubscriptions()`. If you prefer deep link, supply `manageSubscriptionsURL`.
// • From SettingsView → “Manage Subscription” pushes `ManageSubscriptionView.make(store:di.store, analytics: di.analytics)`.
// • Restore CTA calls Store.restorePurchases(); entitlementPublisher updates status pill immediately on success.
// • Purchase history snippet is redacted: transactionId only for stable list identity, productId + date + coarse status. No price/region/user data.
// • Accessibility: buttons ≥44pt, text scales with Dynamic Type, VoiceOver labels/hints added, high-contrast colors chosen automatically.
// • UITest IDs: "manage_open_store", "manage_restore", "history_row_*", "manage_primary_cta".

// MARK: - Test plan (unit / UI)
// Unit:
// 1) Restore idempotency: simulate two rapid taps → only one in-flight (isRestoring gates); entitlement remains consistent.
// 2) History fetch: fake returns N>10 → ensure `.prefix(5)` is shown and “And X more…” appears when appropriate.
// 3) Status mapping: verify color/label mapping for each PurchaseStatus.
// 4) Manage open path: with URL → UIApplication.open called (spy); without URL and iOS >=16 → AppStore.showManageSubscriptions() invoked.
//
// UI:
// • Snapshot at multiple Dynamic Type sizes; CTAs remain visible and non-clipping.
// • VoiceOver reads: “Manage Subscription, Pro is active, Restore, Purchase History, Product: pro.monthly, Active, Open App Store”.
// • Tap “Restore” → shows progress, then “Restore complete.” toast.
// • Tap primary CTA → system manage sheet or deep link opens (assert via spy).


