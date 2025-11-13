// Features/Hazards/HazardListView.swift
// Nearby hazards list with distance & recency; acknowledge/resolve actions.
// - Pulls live pins from HazardStore (already de-duped via HazardRules).
// - Sorts by (distance ASC, recency DESC); sections by severity for quick scanning.
// - Swipe actions: Acknowledge (mutes local alerts for this hazard for N hours), Resolve (request resolve).
// - A11y: Dynamic Type, clear VO labels (“High pothole, 120 meters, 5 minutes ago.”); ≥44pt tap targets.
// - Privacy: uses caller-provided user location; no background location queries here.
// - Offline: actions queue via store; optimistic UI with rollback on failure.
//
// Consistency notes:
// • Matches overlay renderer’s HazardType/HazardSeverity to ensure one source of truth for labels/colors.
// • Hooks into HazardAlertService by acknowledging to dampen further VO/notification spam locally.

import SwiftUI
import Combine
import CoreLocation

// MARK: - Domain adapters (mirror Services/Hazards)

public struct NearbyHazard: Identifiable, Equatable, Sendable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let type: HazardType
    public let severity: HazardSeverity
    public let updatedAt: Date
    public let distanceMeters: Double
    public let count: Int
    public var isAcknowledged: Bool
    public init(id: String,
                coordinate: CLLocationCoordinate2D,
                type: HazardType,
                severity: HazardSeverity,
                updatedAt: Date,
                distanceMeters: Double,
                count: Int,
                isAcknowledged: Bool) {
        self.id = id
        self.coordinate = coordinate
        self.type = type
        self.severity = severity
        self.updatedAt = updatedAt
        self.distanceMeters = distanceMeters
        self.count = count
        self.isAcknowledged = isAcknowledged
    }
}

// MARK: - DI seams

public protocol HazardReading: AnyObject {
    /// Emits a stream of nearby hazards already processed by HazardRules (de-duped/bucketed).
    /// Caller supplies the current user location; implementation may throttle/coalesce.
    func nearbyHazardsPublisher(userLocation: AnyPublisher<CLLocation, Never>,
                                radiusMeters: Double) -> AnyPublisher<[NearbyHazard], Never>
}

public protocol HazardActing: AnyObject {
    /// Marks a hazard acknowledged locally (mute for a time window). Must be idempotent/offline-safe.
    func acknowledge(hazardId: String, muteForHours: Int) async throws
    /// Requests resolve (verified downrank/TTL fast-forward). Moderation may later confirm.
    func requestResolve(hazardId: String) async throws
}

public protocol LocationProviding {
    var locationPublisher: AnyPublisher<CLLocation, Never> { get }
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case hazards }
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
public final class HazardListViewModel: ObservableObject {
    @Published public private(set) var items: [NearbyHazard] = []
    @Published public private(set) var isLoading = true
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    private let reader: HazardReading
    private let actor: HazardActing
    private let locator: LocationProviding
    private let analytics: AnalyticsLogging?
    private let radiusMeters: Double

    private var cancellables = Set<AnyCancellable>()

    public init(reader: HazardReading,
                actor: HazardActing,
                locator: LocationProviding,
                radiusMeters: Double = 1_000,
                analytics: AnalyticsLogging? = nil) {
        self.reader = reader
        self.actor = actor
        self.locator = locator
        self.radiusMeters = radiusMeters
        self.analytics = analytics
    }

    public func onAppear() {
        guard items.isEmpty else { return }
        let stream = reader.nearbyHazardsPublisher(userLocation: locator.locationPublisher, radiusMeters: radiusMeters)
            .map { hazards in
                hazards.sorted { (a, b) in
                    if a.distanceMeters == b.distanceMeters {
                        return a.updatedAt > b.updatedAt
                    }
                    return a.distanceMeters < b.distanceMeters
                }
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)

        stream.sink { [weak self] list in
            self?.items = list
            self?.isLoading = false
        }
        .store(in: &cancellables)
    }

    public func acknowledge(_ hazard: NearbyHazard, muteHours: Int = 6) {
        // Optimistic flip
        flipAckLocally(hazard.id, to: true)
        analytics?.log(.init(name: "hazard_acknowledge", category: .hazards,
                             params: ["id": .string(hazard.id), "severity": .int(hazard.severity.rawValue)]))
        Task {
            do {
                try await actor.acknowledge(hazardId: hazard.id, muteForHours: muteHours)
                infoMessage = NSLocalizedString("Got it. We’ll keep it down for a bit.", comment: "ack ok")
            } catch {
                // Rollback on failure
                flipAckLocally(hazard.id, to: false)
                errorMessage = NSLocalizedString("Couldn’t acknowledge right now.", comment: "ack fail")
            }
        }
    }

    public func requestResolve(_ hazard: NearbyHazard) {
        analytics?.log(.init(name: "hazard_resolve_request", category: .hazards,
                             params: ["id": .string(hazard.id), "severity": .int(hazard.severity.rawValue)]))
        Task {
            do {
                try await actor.requestResolve(hazardId: hazard.id)
                infoMessage = NSLocalizedString("Noted. We’ll verify and update soon.", comment: "resolve ok")
            } catch {
                errorMessage = NSLocalizedString("Resolve request failed. Try later.", comment: "resolve fail")
            }
        }
    }

    private func flipAckLocally(_ id: String, to on: Bool) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            var m = items[idx]
            m.isAcknowledged = on
            items[idx] = m
        }
    }

    // Group by severity for sectioned UI
    public var grouped: [(severity: HazardSeverity, items: [NearbyHazard])] {
        let buckets = Dictionary(grouping: items, by: { $0.severity })
        return HazardSeverity.allCases.reversed().compactMap { sev in
            guard let arr = buckets[sev], !arr.isEmpty else { return nil }
            return (sev, arr)
        }
    }
}

// MARK: - View

public struct HazardListView: View {
    @ObservedObject private var vm: HazardListViewModel

    public init(viewModel: HazardListViewModel) { self.vm = viewModel }

    public var body: some View {
        Group {
            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(NSLocalizedString("Loading hazards", comment: "")))
            } else if vm.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle(Text(NSLocalizedString("Nearby Hazards", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.onAppear() }
        .overlay(toasts)
        .accessibilityElement(children: .contain)
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(vm.grouped, id: \.severity) { group in
                Section(header: sectionHeader(for: group.severity)) {
                    ForEach(group.items) { h in
                        HazardRow(h: h,
                                  acknowledge: { vm.acknowledge(h) },
                                  resolve: { vm.requestResolve(h) })
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("hazard_list")
    }

    private func sectionHeader(for s: HazardSeverity) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(uiColor: s.color)).frame(width: 10, height: 10)
            Text(s.title).font(.subheadline.weight(.semibold))
        }.accessibilityHidden(true)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield").imageScale(.large)
            Text(NSLocalizedString("All clear nearby.", comment: "empty"))
                .font(.headline)
            Text(NSLocalizedString("We’ll ping you if something pops up.", comment: "empty sub"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("hazard_empty")
    }

    // MARK: - Toasts

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
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }
}

// MARK: - Row

fileprivate struct HazardRow: View {
    let h: NearbyHazard
    let acknowledge: () -> Void
    let resolve: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if h.count > 1 {
                        Text("×\(h.count)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .accessibilityLabel(Text(String(format: NSLocalizedString("%d reports", comment: ""), h.count)))
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(distanceString(meters: h.distanceMeters)).font(.caption).foregroundStyle(.secondary)
                    Text("•").font(.caption).foregroundStyle(.secondary)
                    Text(relative(h.updatedAt)).font(.caption).foregroundStyle(.secondary)
                }
            }

            if h.isAcknowledged {
                Spacer()
                Label(NSLocalizedString("Muted", comment: "ack"), systemImage: "bell.slash.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .accessibilityLabel(Text(NSLocalizedString("Acknowledged", comment: "")))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !h.isAcknowledged {
                Button(acknowledge) { Label(NSLocalizedString("Acknowledge (6h)", comment: "ack"), systemImage: "bell.slash") }
            }
            Button(role: .destructive, action: resolve) {
                Label(NSLocalizedString("Request resolve", comment: "resolve"), systemImage: "checkmark.seal")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: resolve) { Label(NSLocalizedString("Resolve", comment: "resolve"), systemImage: "checkmark.seal") }
            if !h.isAcknowledged {
                Button(action: acknowledge) { Label(NSLocalizedString("Acknowledge", comment: "ack"), systemImage: "bell.slash") }
                    .tint(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(h.severity.title) \(h.type.title), \(distanceString(meters: h.distanceMeters)), \(relative(h.updatedAt))"))
        .frame(minHeight: 56)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(Color(uiColor: h.severity.color)).frame(width: 28, height: 28)
            Image(systemName: h.type.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
    private var title: String { "\(h.type.title)" }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func distanceString(meters: Double) -> String {
        if meters < 1000 {
            return String(format: NSLocalizedString("%.0f m", comment: "meters"), meters)
        } else {
            return String(format: NSLocalizedString("%.1f km", comment: "km"), meters/1000.0)
        }
    }
}

// MARK: - Convenience builder

public extension HazardListView {
    static func make(reader: HazardReading,
                     actor: HazardActing,
                     locator: LocationProviding,
                     radiusMeters: Double = 1_000,
                     analytics: AnalyticsLogging? = nil) -> HazardListView {
        HazardListView(viewModel: .init(reader: reader,
                                        actor: actor,
                                        locator: locator,
                                        radiusMeters: radiusMeters,
                                        analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
import MapKit
import UIKit
private final class LocatorFake: LocationProviding {
    let subj = CurrentValueSubject<CLLocation, Never>(CLLocation(latitude: 49.2827, longitude: -123.1207))
    var locationPublisher: AnyPublisher<CLLocation, Never> { subj.eraseToAnyPublisher() }
}
private final class ReaderFake: HazardReading {
    func nearbyHazardsPublisher(userLocation: AnyPublisher<CLLocation, Never>, radiusMeters: Double) -> AnyPublisher<[NearbyHazard], Never> {
        userLocation
            .map { loc in
                let c = loc.coordinate
                return (0..<16).map { i -> NearbyHazard in
                    let offset = Double(i) * 0.001
                    let sev = HazardSeverity.allCases.randomElement() ?? .medium
                    return NearbyHazard(
                        id: "h\(i)",
                        coordinate: .init(latitude: c.latitude + offset, longitude: c.longitude + offset),
                        type: HazardType.allCases.randomElement() ?? .other,
                        severity: sev,
                        updatedAt: Date().addingTimeInterval(-Double(Int.random(in: 1...7200))),
                        distanceMeters: Double(Int.random(in: 20...1500)),
                        count: Int.random(in: 1...4),
                        isAcknowledged: Bool.random() && i % 3 == 0
                    )
                }
            }
            .eraseToAnyPublisher()
    }
}
private final class ActorFake: HazardActing {
    func acknowledge(hazardId: String, muteForHours: Int) async throws { }
    func requestResolve(hazardId: String) async throws { }
}

struct HazardListView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HazardListView.make(reader: ReaderFake(), actor: ActorFake(), locator: LocatorFake())
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `HazardReading` to Services/Hazards/HazardStore.nearbyPublisher(location:radius:) after HazardRules merge/bucket.
// • `acknowledge` should:
//    - Write-through to local cache with muteUntil timestamp,
//    - Notify HazardAlertService to suppress VO/notifications within the mute window for that hazard id,
//    - Attempt remote sync (idempotent).
// • `requestResolve` should enqueue a resolve ticket; if a moderator/city partner confirms, HazardStore will publish a
//   downgraded/expired item and it falls out of this list naturally via TTL.
// • Keep UI cheap during navigation: the list subscribes to a throttled publisher; do not do geocoding here.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Ordering: Same distance → newer first; different distance → nearer first.
// 2) Acknowledge optimistic update → failure rolls back; success sets “Muted” badge.
// 3) Resolve request triggers actor; message toast appears; errors show error toast.
// 4) Grouping: all severities sectioned; empty groups omitted; changing items recomputes groups deterministically.
// UI:
// • Swipe to acknowledge/resolve shows correct labels; VO reads “High Pothole, 120 m, 5 min ago.”
// • Empty state renders when publisher emits [].
// • Large text sizes keep row ≥56pt; buttons ≥44pt.
// • UITest IDs: “hazard_list”, “hazard_empty”.


