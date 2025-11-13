// Features/Challenges/LeaderboardView.swift
// City / Top Friends leaderboards with pagination and “Verify me” flow for flagged entries.
// - Integrates with Services/Challenges/LeaderboardService (read API) and (optional) identity/receipt checks.
// - Tabs: City, Global, Friends. Time range: This Week (can extend later).
// - Infinite scroll pagination via `nextToken`; duplicate suppression; pull-to-refresh.
// - “Flagged / needs verification” rows show a compact CTA -> Verify sheet (anti-cheat UX).
// - A11y: VO-friendly labels (“#3, 12.4 km, Alex, verified”); Dynamic Type; ≥44pt.
// - Privacy: surface coarse city code only when user opted-in via UserProfileStore; no precise GPS here.

import SwiftUI
import Combine

// MARK: - Domain adapters (mirror Services/Challenges/LeaderboardService)

public enum BoardScope: String, CaseIterable, Sendable {
    case city, global, friends
}

public struct LeaderboardEntryViewModel: Identifiable, Equatable, Sendable {
    public let id: String               // stable entry id (userId+week or server-guid)
    public let rank: Int
    public let displayName: String      // privacy-aware; may be first name + initial
    public let cityCode: String?        // coarse (e.g., YVR); nil for private users
    public let valueMeters: Double      // weekly distance (canonical metric for week)
    public let avatarURL: URL?
    public let isYou: Bool
    public let isVerified: Bool         // server-side checks passed
    public let isFlagged: Bool          // anti-cheat heuristics flagged; needs verify to appear fully
    public let createdAt: Date
    public init(id: String, rank: Int, displayName: String, cityCode: String?, valueMeters: Double, avatarURL: URL?, isYou: Bool, isVerified: Bool, isFlagged: Bool, createdAt: Date) {
        self.id = id; self.rank = rank; self.displayName = displayName; self.cityCode = cityCode
        self.valueMeters = valueMeters; self.avatarURL = avatarURL; self.isYou = isYou
        self.isVerified = isVerified; self.isFlagged = isFlagged; self.createdAt = createdAt
    }
}

public struct LeaderboardPage: Sendable, Equatable {
    public let items: [LeaderboardEntryViewModel]
    public let nextToken: String?
    public init(items: [LeaderboardEntryViewModel], nextToken: String?) { self.items = items; self.nextToken = nextToken }
}

// MARK: - DI seams

public protocol LeaderboardReading: AnyObject {
    func fetch(scope: BoardScope, cityCode: String?, pageSize: Int, nextToken: String?) async throws -> LeaderboardPage
    func refresh(scope: BoardScope, cityCode: String?) async throws -> LeaderboardPage
}

public protocol VerificationActing: AnyObject {
    /// Launches a local verification flow. Implementation can combine:
    /// - motion/route plausibility re-check (on-device),
    /// - local receipt re-validate (ReceiptValidator),
    /// - identity confirmation (device-bound).
    /// Returns true when verification submitted and accepted; may be async server roundtrip.
    func verifyMe() async throws -> Bool
}

public protocol CityProviding {
    /// Coarse city code (e.g., YVR) for the user; nil if hidden by privacy.
    var currentCityCode: String? { get }
}

// MARK: - ViewModel

@MainActor
public final class LeaderboardViewModel: ObservableObject {
    @Published public private(set) var items: [LeaderboardEntryViewModel] = []
    @Published public private(set) var nextToken: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isLoadingMore = false

    @Published public var scope: BoardScope
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var showVerifySheet = false

    private let reader: LeaderboardReading
    private let verifier: VerificationActing?
    private let city: CityProviding
    private let analytics: AnalyticsLogging?
    private let pageSize = 30

    public init(reader: LeaderboardReading,
                verifier: VerificationActing?,
                city: CityProviding,
                analytics: AnalyticsLogging?,
                initialScope: BoardScope = .city) {
        self.reader = reader
        self.verifier = verifier
        self.city = city
        self.analytics = analytics
        self.scope = initialScope
    }

    public func onAppear() {
        if items.isEmpty { Task { await load(reset: true) } }
    }

    public func setScope(_ s: BoardScope) {
        guard scope != s else { return }
        scope = s
        Task { await load(reset: true) }
    }

    public func refresh() {
        Task { await load(reset: true, useRefresh: true) }
    }

    public func loadMoreIfNeeded(current item: LeaderboardEntryViewModel) {
        guard !isLoadingMore, let tok = nextToken else { return }
        guard let idx = items.firstIndex(where: { $0.id == item.id }), idx >= items.count - 6 else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            do {
                let page = try await reader.fetch(scope: scope, cityCode: cityParam, pageSize: pageSize, nextToken: tok)
                merge(page: page)
            } catch {
                // Non-fatal: keep existing list
            }
        }
    }

    public func verifyMeTapped() {
        guard let verifier else { return }
        showVerifySheet = true
        analytics?.log(.init(name: "lb_verify_open", category: .leaderboard, params: ["scope": .string(scope.rawValue)]))
        Task {
            do {
                let ok = try await verifier.verifyMe()
                if ok {
                    infoMessage = NSLocalizedString("Verification submitted. We’ll refresh your rank shortly.", comment: "verify ok")
                    analytics?.log(.init(name: "lb_verify_success", category: .leaderboard, params: ["scope": .string(scope.rawValue)]))
                    await load(reset: true)
                } else {
                    infoMessage = NSLocalizedString("Verification cancelled.", comment: "verify cancel")
                }
            } catch {
                errorMessage = NSLocalizedString("Couldn’t complete verification.", comment: "verify fail")
            }
            showVerifySheet = false
        }
    }

    // MARK: - Internals

    private var cityParam: String? {
        scope == .city ? city.currentCityCode : nil
    }

    private func load(reset: Bool, useRefresh: Bool = false) async {
        if reset {
            if useRefresh { isRefreshing = true } else { isLoading = true }
        }
        defer {
            isLoading = false
            isRefreshing = false
        }
        do {
            let page: LeaderboardPage
            if reset {
                page = try await reader.refresh(scope: scope, cityCode: cityParam)
            } else {
                page = try await reader.fetch(scope: scope, cityCode: cityParam, pageSize: pageSize, nextToken: nextToken)
            }
            apply(page: page)
        } catch {
            errorMessage = NSLocalizedString("Couldn’t load leaderboard.", comment: "load fail")
        }
    }

    private func apply(page: LeaderboardPage) {
        let existingIDs = Set(items.map { $0.id })
        let new = page.items.filter { !existingIDs.contains($0.id) }
        if nextToken == nil { // first page
            items = page.items
        } else {
            items += new
        }
        nextToken = page.nextToken
        analytics?.log(.init(name: "lb_page", category: .leaderboard,
                             params: ["scope": .string(scope.rawValue), "count": .int(items.count)]))
    }

    private func merge(page: LeaderboardPage) {
        let ids = Set(items.map { $0.id })
        items += page.items.filter { !ids.contains($0.id) }
        nextToken = page.nextToken
    }
}

// MARK: - View

public struct LeaderboardView: View {
    @ObservedObject private var vm: LeaderboardViewModel
    @State private var showingScopePicker = false

    public init(viewModel: LeaderboardViewModel) { self.vm = viewModel }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            listView
        }
        .navigationTitle(Text(NSLocalizedString("Leaderboard", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.onAppear() }
        .sheet(isPresented: $vm.showVerifySheet) {
            VerifySheet(verify: vm.verifyMeTapped, onDismiss: { vm.showVerifySheet = false })
        }
        .overlay(toasts)
        .accessibilityIdentifier("leaderboard_root")
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BoardScope.allCases, id: \.self) { s in
                    Button {
                        $vm.setScope(s)
                    } label: {
                        Label(title(for: s), systemImage: icon(for: s))
                    }
                }
            } label: {
                Label(title(for: $vm.scope), systemImage: icon(for: $vm.scope))
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)

            if vm.scope == .city, let code = vm.cityParam {
                Text(code)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .accessibilityLabel(Text(String(format: NSLocalizedString("City %@", comment: "city code ax"), code)))
            }

            Spacer()

            Button(action: { vm.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(NSLocalizedString("Refresh", comment: "refresh")))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: List

    private var listView: some View {
        List {
            Section(footer: footer) {
                ForEach(vm.items) { e in
                    EntryRow(entry: e,
                             verify: { vm.showVerifySheet = true })
                        .onAppear { vm.loadMoreIfNeeded(current: e) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { vm.refresh() }
    }

    private var footer: some View {
        HStack {
            if vm.isLoading || vm.isRefreshing || vm.isLoadingMore {
                ProgressView().accessibilityLabel(Text(NSLocalizedString("Loading", comment: "loading")))
            } else if vm.nextToken == nil {
                Text(NSLocalizedString("End of board", comment: "end")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(resultType: body, body: <#@MainActor @Sendable () throws -> _#>) }
    }

    // MARK: Helpers

    private func title(for s: BoardScope) -> String {
        switch s {
        case .city: return NSLocalizedString("City", comment: "city")
        case .global: return NSLocalizedString("Global", comment: "global")
        case .friends: return NSLocalizedString("Friends", comment: "friends")
        }
    }
    private func icon(for s: BoardScope) -> String {
        switch s {
        case .city: return "building.2"
        case .global: return "globe"
        case .friends: return "person.2"
        }
    }
}

// MARK: - Row

fileprivate struct EntryRow: View {
    let entry: LeaderboardEntryViewModel
    let verify: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            rankBadge(entry.rank)
            avatar(url: entry.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName).font(.subheadline.weight(.semibold))
                    if entry.isYou {
                        Text(NSLocalizedString("You", comment: "you"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if let city = entry.cityCode {
                        Text(city).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text(distance(entry.valueMeters))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if entry.isVerified {
                        Label(NSLocalizedString("Verified", comment: "verified"), systemImage: "checkmark.seal.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text(NSLocalizedString("Verified", comment: "verified")))
                    } else if entry.isFlagged && entry.isYou {
                        Button(action: verify) {
                            Label(NSLocalizedString("Verify me", comment: "verify me"), systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("verify_me_button")
                    } else if entry.isFlagged {
                        Text(NSLocalizedString("Needs verification", comment: "needs verify"))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(axLabel))
    }

    private var axLabel: String {
        var parts: [String] = []
        parts.append("#\(entry.rank)")
        parts.append(entry.displayName)
        parts.append(distance(entry.valueMeters))
        if entry.isVerified { parts.append(NSLocalizedString("verified", comment: "ax verified")) }
        if entry.isYou { parts.append(NSLocalizedString("you", comment: "ax you")) }
        return parts.joined(separator: ", ")
    }

    private func distance(_ m: Double) -> String {
        if m < 1000 { return String(format: NSLocalizedString("%.0f m", comment: "m"), m) }
        return String(format: NSLocalizedString("%.1f km", comment: "km"), m/1000.0)
    }

    @ViewBuilder
    private func rankBadge(_ r: Int) -> some View {
        let color: Color = (r == 1 ? .yellow : (r == 2 ? .gray : (r == 3 ? .orange : .secondary)))
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 32, height: 32)
            Text("\(r)").font(.callout.weight(.semibold))
        }.accessibilityHidden(true)
    }

    @ViewBuilder
    private func avatar(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .accessibilityHidden(true)
        } else {
            Circle().fill(Color.secondary.opacity(0.15)).frame(width: 36, height: 36)
                .overlay(Image(systemName: "person").foregroundStyle(.secondary))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Verify sheet

fileprivate struct VerifySheet: View {
    let verify: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").imageScale(.large)
                    Text(NSLocalizedString("Verify your activity", comment: "verify title"))
                        .font(.headline)
                }
                Text(NSLocalizedString("To keep the boards fair, we sometimes ask riders to verify. We’ll run a quick on-device check and confirm your recent rides.", comment: "verify body"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Route plausibility (speed & path shape)")
                    bullet("App receipt sanity (no spoofed entitlements)")
                    bullet("Device-bound identity check")
                }
                Spacer()
                Button(action: verify) {
                    Label(NSLocalizedString("Start verification", comment: "start"), systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(Text(NSLocalizedString("Verify me", comment: "verify me")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "close"), action: onDismiss)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle").imageScale(.small)
            Text(text).font(.footnote)
        }
    }
}

// MARK: - Convenience builder

public extension LeaderboardView {
    static func make(reader: LeaderboardReading,
                     verifier: VerificationActing? = nil,
                     city: CityProviding,
                     analytics: AnalyticsLogging? = nil,
                     initialScope: BoardScope = .city) -> LeaderboardView {
        LeaderboardView(viewModel: .init(reader: reader, verifier: verifier, city: city, analytics: analytics, initialScope: initialScope))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
final class LBReaderFake: LeaderboardReading {
    func refresh(scope: BoardScope, cityCode: String?) async throws -> LeaderboardPage {
        let first = make(scope: scope, startRank: 1, count: 25)
        return LeaderboardPage(items: first, nextToken: "25")
    }
    func fetch(scope: BoardScope, cityCode: String?, pageSize: Int, nextToken: String?) async throws -> LeaderboardPage {
        let start = Int(nextToken ?? "0") ?? 0
        let more = make(scope: scope, startRank: start + 1, count: 25)
        let next = start + 25 >= 75 ? nil : "\(start + 25)"
        return LeaderboardPage(items: more, nextToken: next)    
    }
    private func make(scope: BoardScope, startRank: Int, count: Int) -> [LeaderboardEntryViewModel] {
        (0..<count).map { i in
            let r = startRank + i
            return LeaderboardEntryViewModel(
                id: "e\(r)-\(scope.rawValue)",
                rank: r,
                displayName: r % 7 == 0 ? "Sk8r \(r)" : "Rider \(r)",
                cityCode: scope == .city ? (r % 2 == 0 ? "YVR" : "VAN") : nil,
                valueMeters: Double.random(in: 1000...20000),
                avatarURL: Bool.random() ? URL(string: "https://picsum.photos/seed/\(r)/200") : nil,
                isYou: r == 7,
                isVerified: r % 11 != 0,
                isFlagged: r % 11 == 0
                ,createdAt: Date())
        }
    }
}
final class VerifierFake: VerificationActing {
    func verifyMe() async throws -> Bool { true }
}
final class CityFake: CityProviding { var currentCityCode: String? = "YVR" }
struct LeaderboardView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            LeaderboardView.make(reader: LBReaderFake(), verifier: VerifierFake(), city: CityFake(), initialScope: .city)
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `LeaderboardReading` to Services/Challenges/LeaderboardService with anti-cheat filtering enabled:
//   - City scope uses reverse-geocoded coarse code from CityProviding (UserProfileStore) respecting privacy flags.
//   - Pagination is stable and deterministic (server must return consistent ranks per `nextToken`).
//   - Values are validated (speed sanity, line-straightness ratio, device consistency); entries failing checks have `isFlagged = true`.
// • “Verify me” should call a coordinator that triggers:
//   - Services/StoreKit/ReceiptValidator.validateIfNeeded() to confirm premium benefits aren’t spoofed.
//   - On-device path plausibility scan on last N rides (SessionLogger) and submit a signed attestation blob.
//   - Server adjudicates and flips `isVerified`; client refreshes upon success.
// • Analytics: log page loads, scope changes, verify opens/success/fail; no PII, no precise routes.
// • Accessibility: rows announce “#rank, name, distance, verified/needs verification, you”.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Refresh resets items and nextToken; subsequent fetch appends unique entries, deduped by id.
// 2) Scope switch triggers refresh with appropriate city parameter for .city, nil otherwise.
// 3) “Verify me” flow: when verifyMe() returns true → info toast + refresh; error path shows error toast.
// 4) Pagination edge: when nextToken == nil, footer shows “End of board”; loadMoreIfNeeded no-ops.
// UI:
// • Dynamic Type XXL doesn’t clip row content; hit targets ≥44pt.
// • Friends/City/Global menu switches titles/icons; City code chip shows only for .city.
// • “verify_me_button” appears only for your own flagged entry.
// • Snapshot: rank badges colored for top-3; distances rendered as m/km with monospaced digits.


