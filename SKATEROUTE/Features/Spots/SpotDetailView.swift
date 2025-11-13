// Features/Spots/SpotDetailView.swift
// Detail UI for a skate spot: photos, tips, “skateability” meter, actions.
// - Primary CTA “Skate here” → hands destination to RouteService (grade/surface-aware).
// - Secondary: Apple Maps directions (fallback), Share (OG image + deep link), Save, Report.
// - Pulls live spot updates from SpotStore; comments sheet entry point.
// - A11y: Dynamic Type, ≥44pt targets, clear VO labels; high-contrast safe.
// - Privacy: no location read here; uses provided coordinates only.

import SwiftUI
import Combine
import MapKit
import UIKit

// MARK: - Models (adapter from Services/Spots layer)

public struct SpotDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let categoryTitle: String
    public let coordinate: CLLocationCoordinate2D
    public let isVerified: Bool
    public let skateability: Int        // 0…100
    public let surfaceNote: String?     // e.g., Smooth concrete; beware gravel at NE corner
    public let tips: [String]           // short bullet tips
    public let photoURLs: [URL]         // remote thumbnails; full-size handled by viewer
    public let createdAt: Date
    public let updatedAt: Date
}

// MARK: - DI seams

public protocol SpotReading: AnyObject {
    /// Live updates for a spot; emits immediately then on each change.
    func spotPublisher(id: String) -> AnyPublisher<SpotDetail, Error>
}

public protocol RouteStarting: AnyObject {
    /// Kick off planning to coordinate; source is current user location (owned elsewhere).
    func startSkateTo(_ destination: CLLocationCoordinate2D, name: String)
    /// Optional: open native Apple Maps directions for fallback.
    func openInAppleMaps(to destination: CLLocationCoordinate2D, name: String)
}

public protocol FavoritesManaging: AnyObject {
    func isFavorited(spotId: String) -> Bool
    func setFavorited(_ on: Bool, spot: SpotDetail)
}

public protocol SharePayloadBuilding: AnyObject {
    struct SharePayload {
        public let url: URL
        public let image: UIImage?
        public let text: String
        public init(url: URL, image: UIImage?, text: String) { self.url = url; self.image = image; self.text = text }
    }
    func buildSpotShare(spot: SpotDetail) async -> SharePayload
}

public protocol ModerationReporting {
    enum ReportReason: String, Sendable { case safety, spam, inaccurate, offensive, other }
    func reportSpot(spotId: String, reason: ReportReason, message: String?) async throws
}

public protocol CommentsPresenting {
    func presentComments(for itemId: String, scope: CommentScope)
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case spots }
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
public final class SpotDetailViewModel: ObservableObject {
    @Published public private(set) var spot: SpotDetail?
    @Published public private(set) var isFavorited = false
    @Published public private(set) var loading = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var showReportSheet = false

    private let spotId: String
    private let reader: SpotReading
    private let router: RouteStarting
    private let favorites: FavoritesManaging
    private let shareBuilder: SharePayloadBuilding
    private let moderation: ModerationReporting
    private let commentsPresenter: CommentsPresenting
    private let analytics: AnalyticsLogging?

    private var cancellables = Set<AnyCancellable>()

    public init(spotId: String,
                reader: SpotReading,
                router: RouteStarting,
                favorites: FavoritesManaging,
                shareBuilder: SharePayloadBuilding,
                moderation: ModerationReporting,
                commentsPresenter: CommentsPresenting,
                analytics: AnalyticsLogging? = nil) {
        self.spotId = spotId
        self.reader = reader
        self.router = router
        self.favorites = favorites
        self.shareBuilder = shareBuilder
        self.moderation = moderation
        self.commentsPresenter = commentsPresenter
        self.analytics = analytics
    }

    public func onAppear() {
        guard spot == nil else { return }
        loading = true
        reader.spotPublisher(id: spotId)
            .receive(on: RunLoop.main)
            .sink { [weak self] completion in
                self?.loading = false
                if case .failure = completion {
                    self?.errorMessage = NSLocalizedString("Couldn’t load this spot.", comment: "load fail")
                }
            } receiveValue: { [weak self] s in
                guard let self else { return }
                self.spot = s
                self.isFavorited = self.favorites.isFavorited(spotId: s.id)
                self.loading = false
            }
            .store(in: &cancellables)
    }

    public func skateHere() {
        guard let s = spot else { return }
        analytics?.log(.init(name: "spot_skate_here", category: .spots, params: ["id": .string(s.id)]))
        router.startSkateTo(s.coordinate, name: s.name)
        infoMessage = NSLocalizedString("Planning your line…", comment: "planning")
    }

    public func openMaps() {
        guard let s = spot else { return }
        router.openInAppleMaps(to: s.coordinate, name: s.name)
    }

    public func toggleFavorite() {
        guard let s = spot else { return }
        let next = !isFavorited
        isFavorited = next
        favorites.setFavorited(next, spot: s)
        analytics?.log(.init(name: "spot_favorite", category: .spots, params: ["id": .string(s.id), "on": .bool(next)]))
    }

    public func share() {
        guard let s = spot else { return }
        Task {
            let payload = await shareBuilder.buildSpotShare(spot: s)
            await MainActor.run { SharePresenter.shared.present(items: [payload.text, payload.url, payload.image as Any].compactMap { $0 }) }
        }
    }

    public func openComments() {
        guard let s = spot else { return }
        commentsPresenter.presentComments(for: s.id, scope: .spot)
    }

    public func report(reason: ModerationReporting.ReportReason, notes: String?) {
        guard let s = spot else { return }
        Task {
            do {
                try await moderation.reportSpot(spotId: s.id, reason: reason, message: notes)
                infoMessage = NSLocalizedString("Report received. Thanks for keeping the community solid.", comment: "report ok")
            } catch {
                errorMessage = NSLocalizedString("Report failed. Try later.", comment: "report fail")
            }
        }
    }
}

// MARK: - View

public struct SpotDetailView: View {
    @ObservedObject private var vm: SpotDetailViewModel

    public init(viewModel: SpotDetailViewModel) { self.vm = viewModel }

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                infoCards
                actionRow
                tipsSection
                photosGrid
                commentsButton
            }
            .padding(.horizontal, 12)
        }
        .navigationTitle(vm.spot?.name ?? NSLocalizedString("Spot", comment: "title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.onAppear() }
        .overlay(toastOverlay)
        .sheet(isPresented: $vm.showReportSheet) { reportSheet }
    }

    // MARK: Header (photos pager + labels)

    @ViewBuilder
    private var header: some View {
        if let urls = vm.spot?.photoURLs, !urls.isEmpty {
            TabView {
                ForEach(urls, id: \.self) { u in
                    AsyncImage(url: u) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            ProgressView()
                        }
                    }
                    .frame(height: 260)
                    .clipped()
                    .accessibilityLabel(Text(NSLocalizedString("Spot photo", comment: "photo a11y")))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .overlay(alignment: .topLeading) { categoryBadge.padding(10) }
        } else {
            // Map-styled placeholder if no photos
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12))
                    .frame(height: 200)
                categoryBadge.padding(10)
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.secondary).imageScale(.large)
            }
        }
    }

    private var categoryBadge: some View {
        let cat = vm.spot?.categoryTitle ?? ""
        return HStack(spacing: 8) {
            if vm.spot?.isVerified == true {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            }
            Text(cat).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityLabel(Text("\(vm.spot?.isVerified == true ? NSLocalizedString("Verified", comment: "") + ". " : "")\(cat)"))
    }

    // MARK: Info cards (skateability + surface)

    @ViewBuilder
    private var infoCards: some View {
        if let s = vm.spot {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("Skateability", comment: "skateability")).font(.subheadline.weight(.semibold))
                    SkateabilityMeter(score: s.skateability)
                        .frame(height: 14)
                        .accessibilityLabel(Text(String(format: NSLocalizedString("Skateability %d out of 100", comment: "a11y"), s.skateability)))
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Surface", comment: "surface")).font(.subheadline.weight(.semibold))
                    Text(s.surfaceNote ?? NSLocalizedString("Unknown", comment: "unknown"))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: vm.skateHere) {
                Label(NSLocalizedString("Skate here", comment: "skate cta"), systemImage: "figure.skating")
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 54)
            .accessibilityIdentifier("spot_skate_here")

            Menu {
                Button {
                    vm.openMaps()
                } label: {
                    Label(NSLocalizedString("Open in Apple Maps", comment: "maps"), systemImage: "map")
                }
                Button {
                    vm.share()
                } label: {
                    Label(NSLocalizedString("Share", comment: "share"), systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    vm.showReportSheet = true
                } label: {
                    Label(NSLocalizedString("Report spot", comment: "report"), systemImage: "flag")
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(NSLocalizedString("More actions", comment: "more actions")))

            Toggle(isOn: Binding(get: { vm.isFavorited }, set: { _ in vm.toggleFavorite() })) {
                Image(systemName: vm.isFavorited ? "bookmark.fill" : "bookmark")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .frame(width: 54, height: 54)
            .accessibilityLabel(Text(vm.isFavorited ? NSLocalizedString("Saved", comment: "saved") : NSLocalizedString("Save", comment: "save")))
        }
    }

    // MARK: Tips

    @ViewBuilder
    private var tipsSection: some View {
        if let tips = vm.spot?.tips, !tips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Tips", comment: "tips")).font(.headline)
                ForEach(tips.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb").foregroundStyle(.yellow).imageScale(.small)
                        Text(tips[i]).font(.body)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Photos grid (thumbnails)

    @ViewBuilder
    private var photosGrid: some View {
        if let urls = vm.spot?.photoURLs, urls.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(urls, id: \.self) { u in
                    AsyncImage(url: u) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    .accessibilityLabel(Text(NSLocalizedString("Spot photo", comment: "")))
                }
            }
        }
    }

    // MARK: Comments entry

    private var commentsButton: some View {
        Button {
            vm.openComments()
        } label: {
            Label(NSLocalizedString("Comments", comment: "comments"), systemImage: "text.bubble")
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .padding(.vertical, 6)
        .accessibilityIdentifier("spot_comments")
    }

    // MARK: Report sheet

    private var reportSheet: some View {
        NavigationView {
            ReportSpotView { reason, notes in
                vm.report(reason: reason, notes: notes)
                vm.showReportSheet = false
            } onCancel: {
                vm.showReportSheet = false
            }
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

// MARK: - Subviews

fileprivate struct SkateabilityMeter: View {
    let score: Int // 0…100
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(gradient(for: score))
                    .frame(width: w * CGFloat(min(max(Double(score)/100.0, 0), 1)))
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .trailing) {
            Text("\(score)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        }
    }
    private func gradient(for s: Int) -> LinearGradient {
        let c: Color = s < 40 ? .red : (s < 70 ? .yellow : .green)
        return LinearGradient(colors: [c.opacity(0.9), c], startPoint: .leading, endPoint: .trailing)
    }
}

// Simple report form
fileprivate struct ReportSpotView: View {
    @State private var reason: ModerationReporting.ReportReason = .safety
    @State private var notes: String = ""
    let onSubmit: (ModerationReporting.ReportReason, String?) -> Void
    let onCancel: () -> Void
    var body: some View {
        Form {
            Picker(NSLocalizedString("Reason", comment: "reason"), selection: $reason) {
                Text(NSLocalizedString("Safety hazard", comment: "")).tag(ModerationReporting.ReportReason.safety)
                Text(NSLocalizedString("Spam/advertising", comment: "")).tag(ModerationReporting.ReportReason.spam)
                Text(NSLocalizedString("Inaccurate info", comment: "")).tag(ModerationReporting.ReportReason.inaccurate)
                Text(NSLocalizedString("Offensive content", comment: "")).tag(ModerationReporting.ReportReason.offensive)
                Text(NSLocalizedString("Other", comment: "")).tag(ModerationReporting.ReportReason.other)
            }
            Section(header: Text(NSLocalizedString("Notes (optional)", comment: ""))) {
                TextField(NSLocalizedString("Add context for moderators", comment: ""), text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section {
                Button(role: .destructive) {
                    onSubmit(reason, notes.trimmedOrNil())
                } label: {
                    Label(NSLocalizedString("Submit Report", comment: "submit"), systemImage: "flag.fill")
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 44)
            }
        }
        .navigationTitle(Text(NSLocalizedString("Report Spot", comment: "report title")))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("Close", comment: "close"), action: onCancel)
            }
        }
    }
}

// MARK: - Share presenter (UIKit bridge)

fileprivate final class SharePresenter {
    static let shared = SharePresenter()
    private init() {}
    func present(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = root.view
        root.present(vc, animated: true)
    }
}
fileprivate extension UIWindowScene { var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } } }
fileprivate extension String {
    func trimmedOrNil() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Convenience builder

public extension SpotDetailView {
    static func make(spotId: String,
                     reader: SpotReading,
                     router: RouteStarting,
                     favorites: FavoritesManaging,
                     shareBuilder: SharePayloadBuilding,
                     moderation: ModerationReporting,
                     commentsPresenter: CommentsPresenting,
                     analytics: AnalyticsLogging? = nil) -> SpotDetailView {
        SpotDetailView(viewModel: .init(spotId: spotId,
                                        reader: reader,
                                        router: router,
                                        favorites: favorites,
                                        shareBuilder: shareBuilder,
                                        moderation: moderation,
                                        commentsPresenter: commentsPresenter,
                                        analytics: analytics))
    }
}

// MARK: - DEBUG preview

#if DEBUG
private final class ReaderFake: SpotReading {
    func spotPublisher(id: String) -> AnyPublisher<SpotDetail, Error> {
        let s = SpotDetail(id: id,
                           name: "Chinatown Plaza",
                           categoryTitle: "Plaza",
                           coordinate: .init(latitude: 49.2819, longitude: -123.1086),
                           isVerified: true,
                           skateability: 82,
                           surfaceNote: "Smooth concrete; slight downhill. Mind the morning market.",
                           tips: ["Best after 6pm.", "Security is chill if you’re respectful.", "Watch for wet patches after rain."],
                           photoURLs: [
                               URL(string: "https://picsum.photos/seed/spot1/1200/800")!,
                               URL(string: "https://picsum.photos/seed/spot2/1200/800")!,
                               URL(string: "https://picsum.photos/seed/spot3/1200/800")!
                           ],
                           createdAt: Date().addingTimeInterval(-86400 * 20),
                           updatedAt: Date())
        return Just(s).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
}
private final class RouterFake: RouteStarting {
    func startSkateTo(_ destination: CLLocationCoordinate2D, name: String) {}
    func openInAppleMaps(to destination: CLLocationCoordinate2D, name: String) {}
}
private final class FavsFake: FavoritesManaging {
    private var set: Set<String> = []
    func isFavorited(spotId: String) -> Bool { set.contains(spotId) }
    func setFavorited(_ on: Bool, spot: SpotDetail) { if on { set.insert(spot.id) } else { set.remove(spot.id) } }
}
private final class ShareFake: SharePayloadBuilding {
    func buildSpotShare(spot: SpotDetail) async -> SharePayload {
        .init(url: URL(string: "https://skateroute.app/spot/\(spot.id)")!, image: nil, text: "Pull up: \(spot.name)")
    }
}
private final class ModFake: ModerationReporting {
    func reportSpot(spotId: String, reason: ReportReason, message: String?) async throws {}
}
private final class CommentsPresenterFake: CommentsPresenting {
    func presentComments(for itemId: String, scope: CommentScope) {}
}
struct SpotDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SpotDetailView.make(spotId: "s123",
                                reader: ReaderFake(),
                                router: RouterFake(),
                                favorites: FavsFake(),
                                shareBuilder: ShareFake(),
                                moderation: ModFake(),
                                commentsPresenter: CommentsPresenterFake(),
                                analytics: nil)
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `SpotReading` to Services/Spots/SpotStore.publisher(for:) (geo/CRUD already implemented).
// • RouteStarting: implement via RouteService.start(destination:) with grade/surface-aware options; do not request location here.
// • FavoritesManaging: back by RouteFavoritesStore for unified “Saved” surface (spots + routes if desired).
// • SharePayloadBuilding: delegate to Services/Referrals/SharePayloadBuilder for OG image + universal link payload.
// • ModerationReporting: forward to SpotModerationService for role-gated handling and audit logging.
// • CommentsPresenting: push `CommentsSheet.make(itemId:scope:...)` through your coordinator.
// • A11y: “Skate here” is the primary action; VO labels on meter and photos; large targets everywhere.

// MARK: - Test plan (UI/unit)
// Unit:
// 1) Reader emits SpotDetail → title, meter, tips render; favorites state reflects `FavoritesManaging`.
// 2) Toggling favorite calls `setFavorited` with correct model; state flips idempotently.
// 3) Share: invokes builder; presenter shows UIActivityViewController (spy with a hook in tests).
// 4) Skate here: invokes `RouteStarting.startSkateTo` with exact coordinate and name.
// 5) Report: success → info toast; failure → error toast.
// UI:
// • AX sizes: content reflows; action buttons ≥54pt; tab pager accessible; meter reads “Skateability 82 out of 100”.
// • Photos: multiple URLs show pager + grid; single URL shows header only; none shows placeholder.
// • State: while `loading == true`, skeletons can be added (optional) — current version shows spinners in images.


