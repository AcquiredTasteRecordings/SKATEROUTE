// Features/Profile/ProfileView.swift
// Public profile: portfolio for riders — privacy-aware.
// - Pulls from UserProfileStore (profile, privacy flags), RewardsWallet (badges), FeedService (videos/routes).
// - Sections: Header (avatar/name/city with privacy), Stats, Badges grid, Videos carousel, Routes list.
// - A11y: Dynamic Type, ≥44pt targets, VO labels/hints, high-contrast safe.
// - No tracking. Optional Analytics façade for generic taps (no PII).
//
// Notes:
// • This file reads only public-safe fields. City visibility & route visibility respect profile.flags.
// • “Follow/Share” not included; keep scope minimal and ethical.

import SwiftUI
import Combine

// MARK: - DI seams (narrow & testable)

public protocol ProfileReading: AnyObject {
    // Minimal surface from UserProfileStore (or a read-only adapter) for viewing any user's profile.
    func load(userId: String) async -> UserProfilePublic?
    func privacyFlags(for userId: String) async -> (hideCity: Bool, hideRoutes: Bool)?
}

public struct UserProfilePublic: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let city: String?
    public let avatarURL: URL?
    public let createdAt: Date
    public let hideCity: Bool
    public let hideRoutes: Bool
    public init(id: String, displayName: String, city: String?, avatarURL: URL?, createdAt: Date, hideCity: Bool, hideRoutes: Bool) {
        self.id = id; self.displayName = displayName; self.city = city; self.avatarURL = avatarURL; self.createdAt = createdAt
        self.hideCity = hideCity; self.hideRoutes = hideRoutes
    }
}

public struct BadgeViewModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let imageURL: URL?  // from Resources/Badges or remote CDN
    public let earnedAt: Date
}

public protocol RewardsWalletReading: AnyObject {
    func badges(for userId: String, limit: Int) async -> [BadgeViewModel]
}

public enum FeedKind: String, Sendable { case video, route }

public struct FeedCard: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: FeedKind
    public let title: String
    public let thumbURL: URL?        // small image for video or route snapshot
    public let subtitle: String?     // e.g., distance/time for routes
    public let createdAt: Date
}

public protocol FeedReading: AnyObject {
    // Public-safe feed. Caller passes userId and which kinds to include.
    func fetchUserFeed(userId: String, kinds: [FeedKind], limit: Int) async -> [FeedCard]
}

// Optional analytics façade (redacted)
public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case profile }
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
public final class ProfileViewModel: ObservableObject {

    @Published public private(set) var profile: UserProfilePublic?
    @Published public private(set) var stats: ProfileStats = .empty
    @Published public private(set) var badges: [BadgeViewModel] = []
    @Published public private(set) var videos: [FeedCard] = []
    @Published public private(set) var routes: [FeedCard] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    public struct ProfileStats: Equatable {
        public let joinedOn: Date?
        public let totalDistanceKm: Double
        public let totalRides: Int
        public let totalBadges: Int
        public static var empty: Self { .init(joinedOn: nil, totalDistanceKm: 0, totalRides: 0, totalBadges: 0) }
    }

    private let userId: String
    private let profileReader: ProfileReading
    private let wallet: RewardsWalletReading
    private let feed: FeedReading
    private let analytics: AnalyticsLogging?

    public init(userId: String,
                profileReader: ProfileReading,
                wallet: RewardsWalletReading,
                feed: FeedReading,
                analytics: AnalyticsLogging? = nil) {
        self.userId = userId
        self.profileReader = profileReader
        self.wallet = wallet
        self.feed = feed
        self.analytics = analytics
    }

    public func onAppear() {
        Task { await load() }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        // Load profile
        guard let p = await profileReader.load(userId: userId) else {
            errorMessage = NSLocalizedString("Profile not found.", comment: "no profile")
            return
        }
        profile = p

        // Badges
        let badges = await wallet.badges(for: userId, limit: 12)
        self.badges = badges

        // Feed (respect privacy for routes)
        let kinds: [FeedKind] = p.hideRoutes ? [.video] : [.video, .route]
        let cards = await feed.fetchUserFeed(userId: userId, kinds: kinds, limit: 40)
        self.videos = cards.filter { $0.kind == .video }
        self.routes = cards.filter { $0.kind == .route }

        // Stats (cheap rollups from fetched data)
        let ridesCount = self.routes.count
        let distKm = self.routes
            .compactMap { $0.subtitle }                 // "12.3 km • 41 min"
            .compactMap { s -> Double? in
                // crude parse: take first number before " km"
                guard let r = s.range(of: " km") else { return nil }
                let start = s.startIndex
                let kmString = s[start..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return Double(kmString)
            }
            .reduce(0, +)

        self.stats = .init(joinedOn: p.createdAt, totalDistanceKm: distKm, totalRides: ridesCount, totalBadges: badges.count)
    }

    public func tapVideo(_ id: String) {
        analytics?.log(.init(name: "open_video", category: .profile, params: ["id": .string(id)]))
    }
    public func tapRoute(_ id: String) {
        analytics?.log(.init(name: "open_route", category: .profile, params: ["id": .string(id)]))
    }
}

// MARK: - View

public struct ProfileView: View {

    @ObservedObject private var vm: ProfileViewModel
    private let corner: CGFloat = 16
    private let buttonH: CGFloat = 44

    public init(viewModel: ProfileViewModel) { self.vm = viewModel }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statsRow
                if !vm.badges.isEmpty { badgesGrid }
                if !vm.videos.isEmpty { videosCarousel }
                if !vm.routes.isEmpty { routesList }
                footerEthics
            }
            .padding(16)
        }
        .navigationTitle(Text(vm.profile?.displayName ?? NSLocalizedString("Profile", comment: "")))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
        .accessibilityElement(children: .contain)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            avatar(size: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.profile?.displayName ?? "")
                    .font(.title.bold())
                    .accessibilityLabel(Text(String(format: NSLocalizedString("Rider: %@", comment: ""), vm.profile?.displayName ?? "")))
                if let p = vm.profile, let city = p.city, !p.hideCity {
                    Label(city, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(String(format: NSLocalizedString("City: %@", comment: ""), city)))
                }
                if let joined = vm.stats.joinedOn {
                    Text(String(format: NSLocalizedString("Joined %@", comment: "joined"), joined.formatted(date: .abbreviated, time: .omitted)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .redacted(reason: vm.profile == nil ? .placeholder : [])
    }

    private func avatar(size: CGFloat) -> some View {
        Group {
            if let url = vm.profile?.avatarURL {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "person.crop.circle.fill").imageScale(.large).foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .accessibilityLabel(Text(NSLocalizedString("Profile photo", comment: "")))
    }

    private var statsRow: some View {
        card {
            HStack(spacing: 12) {
                stat(title: NSLocalizedString("Rides", comment: "rides"), value: "\(vm.stats.totalRides)")
                Divider().frame(height: 28)
                let km = vm.stats.totalDistanceKm
                stat(title: NSLocalizedString("Distance", comment: "distance"), value: String(format: "%.1f km", km))
                Divider().frame(height: 28)
                stat(title: NSLocalizedString("Badges", comment: "badges"), value: "\(vm.stats.totalBadges)")
            }
            .accessibilityElement(children: .combine)
        }
        .redacted(reason: vm.isLoading ? .placeholder : [])
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("\(title): \(value)"))
    }

    private var badgesGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Badges", comment: "badges heading"))
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                ForEach(vm.badges) { badge in
                    VStack(spacing: 6) {
                        badgeImage(url: badge.imageURL)
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        Text(badge.title)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(String(format: NSLocalizedString("Badge: %@", comment: ""), badge.title)))
                }
            }
        }
    }

    private func badgeImage(url: URL?) -> some View {
        Group {
            if let u = url {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "seal.fill").foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var videosCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Videos", comment: "videos heading"))
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.videos) { v in
                        Button {
                            vm.tapVideo(v.id)
                            // Coordinator routes to player
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                thumb(url: v.thumbURL).frame(width: 200, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(v.title).font(.caption).lineLimit(1)
                                Text(v.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile_video_\(v.id)")
                        .accessibilityLabel(Text(String(format: NSLocalizedString("Video: %@", comment: ""), v.title)))
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    private var routesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Routes", comment: "routes heading"))
                .font(.headline)
            VStack(spacing: 12) {
                ForEach(vm.routes) { r in
                    Button {
                        vm.tapRoute(r.id)
                        // Coordinator routes to route detail
                    } label: {
                        HStack(spacing: 12) {
                            thumb(url: r.thumbURL).frame(width: 92, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let sub = r.subtitle {
                                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(r.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile_route_\(r.id)")
                    .accessibilityLabel(Text(String(format: NSLocalizedString("Route: %@", comment: ""), r.title)))
                }
            }
        }
    }

    private func thumb(url: URL?) -> some View {
        Group {
            if let u = url {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var footerEthics: some View {
        Text(NSLocalizedString("Respecting privacy: city and routes may be hidden depending on rider settings.", comment: "privacy footer"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
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

    // MARK: Toast

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.large).accessibilityHidden(true)
                    Text(msg).font(.callout).multilineTextAlignment(.leading)
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                .foregroundColor(.white)
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { vm.errorMessage = nil } } }
            }
        }
        .animation(.easeInOut, value: vm.errorMessage != nil)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Convenience builder

public extension ProfileView {
    static func make(userId: String,
                     profileReader: ProfileReading,
                     wallet: RewardsWalletReading,
                     feed: FeedReading,
                     analytics: AnalyticsLogging? = nil) -> ProfileView {
        let vm = ProfileViewModel(userId: userId, profileReader: profileReader, wallet: wallet, feed: feed, analytics: analytics)
        return ProfileView(viewModel: vm)
    }
}

// MARK: - DEBUG fakes (previews)

#if DEBUG
private final class ProfileReaderFake: ProfileReading {
    func load(userId: String) async -> UserProfilePublic? {
        UserProfilePublic(id: userId,
                          displayName: "River",
                          city: "Vancouver",
                          avatarURL: URL(string: "https://picsum.photos/200"),
                          createdAt: Date().addingTimeInterval(-86_400*120),
                          hideCity: false, hideRoutes: false)
    }
    func privacyFlags(for userId: String) async -> (hideCity: Bool, hideRoutes: Bool)? {
        (false, false)
    }
}
private final class WalletReaderFake: RewardsWalletReading {
    func badges(for userId: String, limit: Int) async -> [BadgeViewModel] {
        (0..<8).map { i in
            BadgeViewModel(id: "b\(i)", title: i % 2 == 0 ? "100 km Skated" : "Hazard Helper",
                           imageURL: URL(string: "https://picsum.photos/seed/\(i)/120"),
                           earnedAt: Date().addingTimeInterval(Double(-i) * 86_400))
        }
    }
}
private final class FeedReaderFake: FeedReading {
    func fetchUserFeed(userId: String, kinds: [FeedKind], limit: Int) async -> [FeedCard] {
        var out: [FeedCard] = []
        if kinds.contains(.video) {
            out += (0..<6).map { i in
                FeedCard(id: "v\(i)", kind: .video, title: "Session \(i+1)",
                         thumbURL: URL(string: "https://picsum.photos/seed/v\(i)/400/240"),
                         subtitle: nil,
                         createdAt: Date().addingTimeInterval(Double(-i-1) * 86_400))
            }
        }
        if kinds.contains(.route) {
            out += (0..<5).map { i in
                FeedCard(id: "r\(i)", kind: .route, title: "Seawall Cruise \(i+1)",
                         thumbURL: URL(string: "https://picsum.photos/seed/r\(i)/200/120"),
                         subtitle: String(format: "%.1f km • %d min", Double(4 + i), 20 + i*3),
                         createdAt: Date().addingTimeInterval(Double(-i-2) * 86_400))
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
}
private struct AnalyticsNoop: AnalyticsLogging { func log(_ event: AnalyticsEvent) {} }

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ProfileView.make(userId: "u_demo",
                             profileReader: ProfileReaderFake(),
                             wallet: WalletReaderFake(),
                             feed: FeedReaderFake(),
                             analytics: AnalyticsNoop())
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            ProfileView.make(userId: "u_demo",
                             profileReader: ProfileReaderFake(),
                             wallet: WalletReaderFake(),
                             feed: FeedReaderFake(),
                             analytics: AnalyticsNoop())
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • Adapter your Services/Profile/UserProfileStore to expose a read-only `ProfileReading` for public views.
// • RewardsWallet should provide a public-safe list of earned badges (title + image URL + earnedAt).
// • FeedService exposes a user feed with `FeedCard` (videos/routes) already privacy-scrubbed; when `hideRoutes` is true, return videos only.
// • Coordinator routes taps on video/route cards to the appropriate detail/player screens.
// • Accessibility: all tappables ≥44pt; AsyncImage placeholders keep contrast high; VO labels summarize each card.
// • No PII is fetched/displayed beyond what the user has opted to show (name, optional city, public media).

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Privacy flags: when profile.hideRoutes == true, ensure `routes` array is empty and “Routes” section is hidden.
// 2) Stats roll-up: with two routes having “4.0 km …” and “6.0 km …” subtitles, totalDistanceKm == 10.0 and totalRides == 2.
// 3) Loading flow: when ProfileReading returns nil → error toast renders.
// UI:
// • Snapshot at multiple Dynamic Type sizes; grid/list do not clip; buttons ≥44pt.
// • VO traversal order: Header → Stats → Badges → Videos → Routes (if any).
// • Light/Dark contrast check: placeholders maintain sufficient contrast.


