// Features/Feed/FeedView.swift
// Mixed feed: videos, spots, routes. Infinite scroll + pull-to-refresh.
// - Integrates with Services/Feed/FeedService (paged “since” tokens, local cache).
// - Auto-plays videos when sufficiently visible; ALWAYS muted by default; captions ON by default.
// - Accessibility: Dynamic Type, ≥44pt targets, VoiceOver-friendly labels, captioning defaults.
// - Privacy: zero tracking; optional Analytics façade logs generic taps (no PII).

import SwiftUI
import Combine
import AVKit

// MARK: - Models (align with Services/Feed)

public enum FeedKind: String, Sendable { case video, route, spot }

public struct FeedItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: FeedKind
    public let title: String
    public let subtitle: String?           // e.g., distance/time, spot category
    public let thumbURL: URL?
    public let mediaURL: URL?              // video URL (HLS/MP4) for .video only
    public let createdAt: Date
}

// MARK: - DI seams

public protocol FeedPagingProviding: AnyObject {
    /// First page (newest first). Returns items plus opaque paging token.
    func fetchFirstPage(limit: Int) async throws -> (items: [FeedItem], next: String?)
    /// Subsequent pages using the token returned previously.
    func fetchNextPage(token: String, limit: Int) async throws -> (items: [FeedItem], next: String?)
    /// Pull-to-refresh newer-than first item; returns prepended items.
    func refresh(since itemId: String) async throws -> [FeedItem]
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case feed }
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
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [FeedItem] = []
    @Published public private(set) var nextToken: String?
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var isRefreshing = false
    @Published public var errorMessage: String?

    private let feed: FeedPagingProviding
    private let analytics: AnalyticsLogging?

    public init(feed: FeedPagingProviding, analytics: AnalyticsLogging? = nil) {
        self.feed = feed
        self.analytics = analytics
    }

    public func loadInitial() async {
        guard items.isEmpty else { return }
        do {
            let page = try await feed.fetchFirstPage(limit: 20)
            items = page.items
            nextToken = page.next
        } catch {
            errorMessage = NSLocalizedString("Couldn’t load feed. Pull to retry.", comment: "feed error")
        }
    }

    public func refresh() async {
        guard let first = items.first else {
            await loadInitial()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let newer = try await feed.refresh(since: first.id)
            if !newer.isEmpty {
                items = newer + items
            }
        } catch {
            // Non-fatal
        }
    }

    public func loadMoreIfNeeded(current item: FeedItem?) async {
        guard let item, let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard idx >= items.count - 5, !isLoadingMore, nextToken != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await feed.fetchNextPage(token: nextToken!, limit: 20)
            // De-dupe by id to suppress flicker
            let existing = Set(items.map { $0.id })
            let filtered = next.items.filter { !existing.contains($0.id) }
            items += filtered
            nextToken = next.next
        } catch {
            // Non-fatal; keep token so we can retry via scroll
        }
    }

    public func tapped(item: FeedItem) {
        analytics?.log(.init(name: "open_item",
                             category: .feed,
                             params: ["id": .string(item.id), "kind": .string(item.kind.rawValue)]))
    }
}

// MARK: - View

public struct FeedView: View {
    @ObservedObject private var vm: FeedViewModel

    public init(viewModel: FeedViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(vm.items) { item in
                        FeedRow(item: item, onAppear: { Task { await vm.loadMoreIfNeeded(current: item) } }) {
                            vm.tapped(item: item)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .accessibilityIdentifier("feed_row_\(item.id)")
                    }

                    if vm.isLoadingMore {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text(NSLocalizedString("Loading more…", comment: "loading more"))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowInsets(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                }
            }
            .overlay(errorToast)
            .listStyle(.plain)
            .task { await vm.loadInitial() }
            .refreshable { await vm.refresh() } // Pull to refresh
            .navigationTitle(Text(NSLocalizedString("Feed", comment: "nav title")))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var errorToast: some View {
        if let msg = vm.errorMessage {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.large)
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
                .onAppear { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { vm.errorMessage = nil } } }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut, value: vm.errorMessage != nil)
        }
    }
}

// MARK: - Row types

fileprivate struct FeedRow: View {
    let item: FeedItem
    let onAppear: () -> Void
    let onTap: () -> Void

    var body: some View {
        Group {
            switch item.kind {
            case .video: VideoCard(item: item, onTap: onTap)
            case .route: RouteCard(item: item, onTap: onTap)
            case .spot:  SpotCard(item: item,  onTap: onTap)
            }
        }
        .onAppear(perform: onAppear)
    }
}

// MARK: - Video card (auto-play muted, captions ON)

fileprivate struct VideoCard: View {
    let item: FeedItem
    let onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var isVisibleEnough = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                VideoViewport(player: $player, isVisibleEnough: $isVisibleEnough)
                    .frame(height: 280)
                    .onAppear { setupPlayerIfNeeded() }
                    .onDisappear { pauseAndTearDown() }
                    .onChange(of: isVisibleEnough) { visible in
                        // Auto-play/pause logic
                        if visible { player?.play() } else { player?.pause() }
                    }
                    .accessibilityLabel(Text(String(format: NSLocalizedString("Video: %@", comment: ""), item.title)))
                    .accessibilityHint(Text(NSLocalizedString("Double tap to play or pause.", comment: "VO")))

                // Mute badge (always muted)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash.fill").foregroundColor(.white).imageScale(.medium)
                    Text(NSLocalizedString("Muted", comment: "muted"))
                        .font(.caption.weight(.semibold)).foregroundColor(.white)
                }
                .padding(8)
                .background(Color.black.opacity(0.45), in: Capsule())
                .padding(10)
                .accessibilityHidden(true)
            }
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let sub = item.subtitle {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)

            Button(action: onTap) {
                Text(NSLocalizedString("Open", comment: "open"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("feed_video_open_\(item.id)")
        }
        .contentShape(Rectangle())
    }

    private func setupPlayerIfNeeded() {
        guard player == nil, let url = item.mediaURL else { return }
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = true
        p.allowsExternalPlayback = false

        // Prefer captions (subtitles) ON by default
        let item = p.currentItem
        if let group = item?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let option = AVMediaSelectionGroup.defaultPresentation(for: group) ?? group.options.first
            if let opt = option { item?.select(opt, in: group) }
        }

        // Loop
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            if self.isVisibleEnough { p.play() }
        }
        self.player = p
        if isVisibleEnough { p.play() }
    }

    private func pauseAndTearDown() {
        player?.pause()
        player = nil
    }
}

// Visible fraction detector: plays when ≥60% visible.
fileprivate struct VideoViewport: View {
    @Binding var player: AVPlayer?
    @Binding var isVisibleEnough: Bool

    var body: some View {
        GeometryReader { geo in
            VideoPlayer(player: player)
                .overlay(
                    GeometryReader { inner in
                        Color.clear
                            .onChange(of: inner.frame(in: .global)) { _ in
                                updateVisibility(container: geo.frame(in: .global), content: inner.frame(in: .global))
                            }
                            .onAppear { updateVisibility(container: geo.frame(in: .global), content: inner.frame(in: .global)) }
                    }
                )
        }
        .clipped()
    }

    private func updateVisibility(container: CGRect, content: CGRect) {
        let intersection = container.intersection(content)
        let visible = max(0, intersection.height * intersection.width)
        let total = max(1, content.height * content.width)
        let fraction = visible / total
        isVisibleEnough = fraction >= 0.6
    }
}

// MARK: - Route card

fileprivate struct RouteCard: View {
    let item: FeedItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                thumb(url: item.thumbURL)
                    .frame(width: 120, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let sub = item.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(format: NSLocalizedString("Route: %@", comment: ""), item.title)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Spot card

fileprivate struct SpotCard: View {
    let item: FeedItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                thumb(url: item.thumbURL)
                    .frame(width: 120, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let sub = item.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(format: NSLocalizedString("Spot: %@", comment: ""), item.title)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared UI

fileprivate func thumb(url: URL?) -> some View {
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
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
}

// MARK: - Convenience builder

public extension FeedView {
    static func make(feed: FeedPagingProviding, analytics: AnalyticsLogging? = nil) -> FeedView {
        FeedView(viewModel: .init(feed: feed, analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
private final class FeedFake: FeedPagingProviding {
    private var pages: [[FeedItem]] = []
    private var nextIndex = 0

    init() {
        let now = Date()
        func mk(id: Int, kind: FeedKind) -> FeedItem {
            switch kind {
            case .video:
                return FeedItem(id: "v\(id)", kind: .video,
                                title: "Session \(id)",
                                subtitle: "Seawall • chill cruise",
                                thumbURL: URL(string: "https://picsum.photos/seed/v\(id)/600/338"),
                                mediaURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"),
                                createdAt: now.addingTimeInterval(Double(-id) * 1800))
            case .route:
                return FeedItem(id: "r\(id)", kind: .route,
                                title: "Route \(id) – False Creek",
                                subtitle: String(format: "%.1f km • %d min", Double(3 + id % 5), 18 + id % 15),
                                thumbURL: URL(string: "https://picsum.photos/seed/r\(id)/400/260"),
                                mediaURL: nil,
                                createdAt: now.addingTimeInterval(Double(-id) * 1900))
            case .spot:
                return FeedItem(id: "s\(id)", kind: .spot,
                                title: "Spot \(id) – Plaza",
                                subtitle: "Ledges • Smooth",
                                thumbURL: URL(string: "https://picsum.photos/seed/s\(id)/400/260"),
                                mediaURL: nil,
                                createdAt: now.addingTimeInterval(Double(-id) * 2000))
            }
        }
        let all = (0..<60).map { i -> FeedItem in
            let kind = [FeedKind.video, .route, .spot][i % 3]
            return mk(id: i, kind: kind)
        }
        // Chunk into pages of 15
        pages = stride(from: 0, to: all.count, by: 15).map { Array(all[$0..<min($0+15, all.count)]) }
    }

    func fetchFirstPage(limit: Int) async throws -> (items: [FeedItem], next: String?) {
        nextIndex = 1
        return (pages.first ?? [], pages.count > 1 ? "1" : nil)
    }

    func fetchNextPage(token: String, limit: Int) async throws -> (items: [FeedItem], next: String?) {
        guard let idx = Int(token), idx < pages.count else { return ([], nil) }
        let items = pages[idx]
        let next = (idx + 1) < pages.count ? String(idx + 1) : nil
        return (items, next)
    }

    func refresh(since itemId: String) async throws -> [FeedItem] {
        // Prepend two fake “new” items
        let now = Date()
        return [
            FeedItem(id: "new1", kind: .video, title: "Fresh Session", subtitle: "OG spot", thumbURL: URL(string: "https://picsum.photos/seed/new1/600/338"), mediaURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"), createdAt: now),
            FeedItem(id: "new2", kind: .spot, title: "New Plaza", subtitle: "Rails • Ledges", thumbURL: URL(string: "https://picsum.photos/seed/new2/400/260"), mediaURL: nil, createdAt: now.addingTimeInterval(-60))
        ]
    }
}

struct FeedView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            FeedView.make(feed: FeedFake(), analytics: nil)
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            FeedView.make(feed: FeedFake(), analytics: nil)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • Wire to Services/Feed/FeedService.swift implementing `FeedPagingProviding` using your paged “since” API and local cache.
// • Coordinator routes: onTap for .video → Player; .route → Route detail; .spot → Spot detail.
// • Auto-play policy: muted always; visible threshold 60%. Captions enabled by default via legible media selection.
// • Pull-to-refresh calls `refresh(since:firstItemId)`; infinite scroll triggers within 5 rows of the end.
// • Test hooks: accessibility IDs per row; preview with FeedFake supports quick UI checks.
// • Performance: AsyncImage for thumbs; VideoPlayer is torn down when off-screen to save battery.

// MARK: - Test plan (UI/unit)
// • Infinite scroll: ensure `loadMoreIfNeeded` triggers once as last rows appear; de-dupe verified.
// • Pull-to-refresh: first page present → refresh prepends; empty state falls back to initial load.
// • Video behavior: becomes ≥60% visible → player.play(); scrolled off → pause. Always muted; captions visible when available.


