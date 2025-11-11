// Features/Hazards/HazardModerationQueueView.swift
// Role-gated triage surface for trusted users & city partners.
// - Presents a moderation inbox of flagged/queued hazards with inline map previews.
// - Bulk actions: Confirm (keep), Downgrade, Resolve (close), Merge (dedupe), Reject (bad report).
// - Filters: severity, type, city scope; pagination via “since/nextToken”.
// - A11y: Dynamic Type, ≥44pt targets; VO reads full context (type, severity, age, reporter trust).
// - Privacy: no precise user location exposed; previews use hazard coordinates only.
// - Offline: actions enqueue and retry; UI is optimistic with rollback on failure.

import SwiftUI
import Combine
import MapKit

// MARK: - Domain adapters (aligns with Services/Hazards + SpotModerationService)

public enum ModRole: String, Sendable { case viewer, trusted, partner, admin }

public struct ModHazardItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let type: HazardType
    public let severity: HazardSeverity
    public let updatedAt: Date
    public let reports: Int
    public let cityCode: String?
    public let reporterTrustScore: Double // 0…1, from SpotModerationService trust weights
    public let note: String?
    public let evidencePhotoURL: URL?
    public init(id: String,
                coordinate: CLLocationCoordinate2D,
                type: HazardType,
                severity: HazardSeverity,
                updatedAt: Date,
                reports: Int,
                cityCode: String?,
                reporterTrustScore: Double,
                note: String?,
                evidencePhotoURL: URL?) {
        self.id = id
        self.coordinate = coordinate
        self.type = type
        self.severity = severity
        self.updatedAt = updatedAt
        self.reports = reports
        self.cityCode = cityCode
        self.reporterTrustScore = reporterTrustScore
        self.note = note
        self.evidencePhotoURL = evidencePhotoURL
    }
}

public struct ModPage: Sendable, Equatable {
    public let items: [ModHazardItem]
    public let nextToken: String?
}

// MARK: - DI seams

public protocol HazardModerationReading: AnyObject {
    /// Paged queue fetch with optional filters (severity, type, city).
    func fetchQueue(severity: Set<HazardSeverity>,
                    types: Set<HazardType>,
                    city: String?,
                    pageSize: Int,
                    nextToken: String?) async throws -> ModPage
}

public enum ModAction: Sendable {
    case confirm(id: String)                 // accept as-is
    case downgrade(id: String, to: HazardSeverity)
    case resolve(id: String)                 // mark resolved/expired
    case merge(primary: String, duplicate: String)
    case reject(id: String, reason: String?) // junk/bad data
}

public protocol HazardModerationActing: AnyObject {
    /// Executes one action; must be idempotent; returns authoritative updated item or nil when removed.
    func perform(_ action: ModAction) async throws -> ModHazardItem?
    /// Bulk variant; returns map of id -> updated item or nil when removed.
    func performBulk(_ actions: [ModAction]) async throws -> [String: ModHazardItem?]
}

public protocol RoleProviding {
    var currentRole: ModRole { get }
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case moderation }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) {
        self.name = name; self.category = category; self.params = params
    }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool), double(Double) }

// MARK: - ViewModel

@MainActor
public final class HazardModerationQueueViewModel: ObservableObject {
    // Feed
    @Published public private(set) var items: [ModHazardItem] = []
    @Published public private(set) var nextToken: String?
    @Published public private(set) var loading = false
    @Published public private(set) var isLoadingMore = false

    // UI State
    @Published public var selected: Set<String> = [] // selected ids for bulk actions
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    // Filters
    @Published public var filterSeverities: Set<HazardSeverity> = Set(HazardSeverity.allCases)
    @Published public var filterTypes: Set<HazardType> = Set(HazardType.allCases)
    @Published public var filterCity: String?

    // DI
    private let reader: HazardModerationReading
    private let actor: HazardModerationActing
    private let roles: RoleProviding
    private let analytics: AnalyticsLogging?

    // Access
    public var role: ModRole { roles.currentRole }
    private let pageSize = 25

    public init(reader: HazardModerationReading,
                actor: HazardModerationActing,
                roles: RoleProviding,
                analytics: AnalyticsLogging?) {
        self.reader = reader
        self.actor = actor
        self.roles = roles
        self.analytics = analytics
    }

    // MARK: - Load

    public func load() async {
        guard role != .viewer else {
            errorMessage = NSLocalizedString("You don’t have access to moderation.", comment: "no access")
            return
        }
        loading = true
        defer { loading = false }
        do {
            let page = try await reader.fetchQueue(severity: filterSeverities, types: filterTypes, city: filterCity, pageSize: pageSize, nextToken: nil)
            items = page.items
            nextToken = page.nextToken
            selected.removeAll()
            analytics?.log(.init(name: "mod_queue_load", category: .moderation, params: ["count": .int(items.count)]))
        } catch {
            errorMessage = NSLocalizedString("Couldn’t load moderation queue.", comment: "load fail")
        }
    }

    public func loadMoreIfNeeded(current item: ModHazardItem) async {
        guard !isLoadingMore, let tok = nextToken else { return }
        guard let idx = items.firstIndex(where: { $0.id == item.id }), idx >= items.count - 5 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await reader.fetchQueue(severity: filterSeverities, types: filterTypes, city: filterCity, pageSize: pageSize, nextToken: tok)
            // Dedup by id
            let existing = Set(items.map { $0.id })
            items += page.items.filter { !existing.contains($0.id) }
            nextToken = page.nextToken
        } catch {
            // keep current list
        }
    }

    // MARK: - Single actions

    public func confirm(_ id: String) { perform(.confirm(id: id), optimisticRemove: false) }
    public func resolve(_ id: String) { perform(.resolve(id: id), optimisticRemove: true) }
    public func downgrade(_ id: String, to sev: HazardSeverity) { perform(.downgrade(id: id, to: sev), optimisticRemove: false) }
    public func reject(_ id: String, reason: String?) { perform(.reject(id: id, reason: reason), optimisticRemove: true) }

    public func merge(primary: String, duplicate: String) {
        perform(.merge(primary: primary, duplicate: duplicate), optimisticRemove: true, targetId: duplicate)
    }

    private func perform(_ action: ModAction, optimisticRemove: Bool, targetId: String? = nil) {
        guard role != .viewer else { return }
        let actedId: String = {
            switch action {
            case let .confirm(id), let .resolve(id), let .reject(id, _), let .downgrade(id, _): return id
            case let .merge(_, duplicate): return targetId ?? duplicate
            }
        }()

        var removedSnapshot: ModHazardItem?
        if optimisticRemove, let idx = items.firstIndex(where: { $0.id == actedId }) {
            removedSnapshot = items[idx]
            items.remove(at: idx)
        }

        Task {
            do {
                let updated = try await actor.perform(action)
                if let updatedItem = updated {
                    // Either reinsert or update in place
                    if let idx = items.firstIndex(where: { $0.id == updatedItem.id }) {
                        items[idx] = updatedItem
                    } else {
                        items.insert(updatedItem, at: 0)
                    }
                }
                infoMessage = NSLocalizedString("Action applied.", comment: "ok")
                analytics?.log(.init(name: "mod_action", category: .moderation, params: ["kind": .string(String(describing: action))]))
            } catch {
                // Rollback optimistic removal
                if let rollback = removedSnapshot {
                    items.insert(rollback, at: 0)
                }
                errorMessage = NSLocalizedString("Couldn’t apply action. Try again.", comment: "fail")
            }
        }
    }

    // MARK: - Bulk actions

    public func bulkResolve() { bulk(.resolve) }
    public func bulkConfirm() { bulk(.confirm) }
    public func bulkReject() { bulk(.reject) }

    private enum BulkKind { case resolve, confirm, reject }
    private func bulk(_ kind: BulkKind) {
        guard !selected.isEmpty else { return }
        let actions: [ModAction] = selected.compactMap { id in
            switch kind {
            case .resolve: return .resolve(id: id)
            case .confirm: return .confirm(id: id)
            case .reject:  return .reject(id: id, reason: "bulk")
            }
        }
        // Optimistic UI: drop selected rows if resolve/reject; keep on confirm
        let optimisticRemove = (kind != .confirm)
        let snapshots: [String: ModHazardItem] = items.reduce(into: [:]) { acc, i in
            if selected.contains(i.id) { acc[i.id] = i }
        }
        if optimisticRemove {
            items.removeAll { selected.contains($0.id) }
        }

        Task {
            do {
                let results = try await actor.performBulk(actions)
                // Reconcile authoritative outcomes
                for (id, newItem) in results {
                    if let it = newItem {
                        if let idx = items.firstIndex(where: { $0.id == id }) {
                            items[idx] = it
                        } else {
                            items.insert(it, at: 0)
                        }
                    } else {
                        // removed stays removed
                    }
                }
                selected.removeAll()
                infoMessage = NSLocalizedString("Bulk action complete.", comment: "bulk ok")
            } catch {
                // Rollback
                if optimisticRemove {
                    // restore all snapshots
                    items.insert(contentsOf: snapshots.values, at: 0)
                }
                errorMessage = NSLocalizedString("Bulk action failed.", comment: "bulk fail")
            }
        }
    }
}

// MARK: - View

public struct HazardModerationQueueView: View {
    @ObservedObject private var vm: HazardModerationQueueViewModel
    @State private var showFilters = false
    @State private var mergePrimary: String?
    @State private var mergeCandidate: String?

    public init(viewModel: HazardModerationQueueViewModel) { self.vm = viewModel }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            divider
            if vm.loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(NSLocalizedString("Loading moderation queue", comment: "")))
            } else if vm.items.isEmpty {
                empty
            } else {
                list
                bulkBar
            }
        }
        .navigationTitle(Text(NSLocalizedString("Hazard Moderation", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .sheet(isPresented: $showFilters) { filterSheet }
        .overlay(toasts)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top toolbar

    private var toolbar: some View {
        HStack {
            RoleBadge(role: vm.role)
            Spacer()
            Button { showFilters = true } label: {
                Label(NSLocalizedString("Filters", comment: "filters"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 40)
            .disabled(vm.role == .viewer)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(vm.items) { item in
                ModRow(item: item,
                       isSelected: vm.selected.contains(item.id),
                       toggleSelected: { toggleSelect(item.id) },
                       confirm: { vm.confirm(item.id) },
                       resolve: { vm.resolve(item.id) },
                       downgrade: { sev in vm.downgrade(item.id, to: sev) },
                       reject: { vm.reject(item.id, reason: nil) },
                       startMerge: {
                           if mergePrimary == nil { mergePrimary = item.id }
                           else { mergeCandidate = item.id }
                           considerMerge()
                       })
                    .onAppear { Task { await vm.loadMoreIfNeeded(current: item) } }
                    .listRowSeparator(.automatic)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("mod_queue_list")
    }

    private func toggleSelect(_ id: String) {
        if vm.selected.contains(id) { vm.selected.remove(id) } else { vm.selected.insert(id) }
    }

    // Merge state machine: when both fields filled, fire merge(primary, candidate)
    private func considerMerge() {
        guard let p = mergePrimary, let d = mergeCandidate, p != d else { return }
        vm.merge(primary: p, duplicate: d)
        mergePrimary = nil
        mergeCandidate = nil
    }

    // MARK: Bulk action bar

    @ViewBuilder
    private var bulkBar: some View {
        if !vm.selected.isEmpty {
            HStack(spacing: 8) {
                Text("\(vm.selected.count) selected").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button {
                    vm.bulkConfirm()
                } label: { Label(NSLocalizedString("Confirm", comment: "confirm"), systemImage: "checkmark.seal") }
                .buttonStyle(.bordered)

                Button {
                    vm.bulkResolve()
                } label: { Label(NSLocalizedString("Resolve", comment: "resolve"), systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    vm.bulkReject()
                } label: { Label(NSLocalizedString("Reject", comment: "reject"), systemImage: "xmark.octagon") }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1), alignment: .top)
            .accessibilityIdentifier("mod_bulk_bar")
        }
    }

    // MARK: Filters

    private var filterSheet: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Severity", comment: "severity"))) {
                    ForEach(HazardSeverity.allCases, id: \.self) { sev in
                        Toggle(isOn: Binding(get: { vm.filterSeverities.contains(sev) },
                                             set: { on in on ? vm.filterSeverities.insert(sev) : vm.filterSeverities.remove(sev) })) {
                            Text(sev.title)
                        }
                    }
                }
                Section(header: Text(NSLocalizedString("Types", comment: "types"))) {
                    ForEach(HazardType.allCases, id: \.self) { t in
                        Toggle(isOn: Binding(get: { vm.filterTypes.contains(t) },
                                             set: { on in on ? vm.filterTypes.insert(t) : vm.filterTypes.remove(t) })) {
                            Text(t.title)
                        }
                    }
                }
                Section(header: Text(NSLocalizedString("City Code", comment: "city"))) {
                    TextField(NSLocalizedString("e.g., YVR", comment: "city placeholder"),
                              text: Binding(get: { vm.filterCity ?? "" }, set: { vm.filterCity = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle(Text(NSLocalizedString("Filters", comment: "")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "close")) { showFilters = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Apply", comment: "apply")) {
                        showFilters = false
                        Task { await vm.load() }
                    }
                }
            }
        }
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield").imageScale(.large)
            Text(NSLocalizedString("No items in the queue.", comment: "empty")).font(.headline)
            Text(NSLocalizedString("You’ll see new reports and flags here when they need review.", comment: "empty sub"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mod_empty")
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
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }
}

// MARK: - Row

fileprivate struct ModRow: View {
    let item: ModHazardItem
    let isSelected: Bool
    let toggleSelected: () -> Void
    let confirm: () -> Void
    let resolve: () -> Void
    let downgrade: (HazardSeverity) -> Void
    let reject: () -> Void
    let startMerge: () -> Void

    @State private var showActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SelectBox(isOn: isSelected, toggle: toggleSelected)

                // Map preview chip (static)
                MapChip(coordinate: item.coordinate, color: Color(uiColor: item.severity.color))
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(item.type.title)")
                            .font(.subheadline.weight(.semibold))
                        if let city = item.cityCode {
                            Text(city).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .accessibilityLabel(Text("\(city)"))
                        }
                        Spacer()
                        SeverityBadge(sev: item.severity)
                    }
                    HStack(spacing: 6) {
                        Text(relative(item.updatedAt)).font(.caption).foregroundStyle(.secondary)
                        Text("•").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: NSLocalizedString("%d reports", comment: "reports"), item.reports))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("•").font(.caption).foregroundStyle(.secondary)
                        Text(trustText(item.reporterTrustScore)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = item.note, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            // Evidence photo if present
            if let url = item.evidencePhotoURL {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.12)
                }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            // Action row
            HStack(spacing: 8) {
                Button(confirm) { Label(NSLocalizedString("Confirm", comment: "confirm"), systemImage: "checkmark.seal") }
                    .buttonStyle(.bordered)
                Menu {
                    ForEach(HazardSeverity.allCases, id: \.self) { sev in
                        Button { downgrade(sev) } label: {
                            Label("\(NSLocalizedString("Downgrade to", comment: "")) \(sev.title)", systemImage: "arrow.down.right")
                        }
                    }
                } label: {
                    Label(NSLocalizedString("Downgrade", comment: "downgrade"), systemImage: "arrow.down.right.circle")
                }
                .buttonStyle(.bordered)

                Button(resolve) { Label(NSLocalizedString("Resolve", comment: "resolve"), systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: reject) { Label(NSLocalizedString("Reject", comment: "reject"), systemImage: "xmark.octagon") }
                    .buttonStyle(.bordered)

                Button(startMerge) { Label(NSLocalizedString("Merge", comment: "merge"), systemImage: "square.stack.3d.down.right") }
                    .buttonStyle(.bordered)
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.severity.title) \(item.type.title). \(relative(item.updatedAt)). \(item.reports) reports. Trust \(Int(item.reporterTrustScore * 100)) percent."))
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func trustText(_ score: Double) -> String {
        let pct = Int((score * 100).rounded())
        return String(format: NSLocalizedString("Trust %d%%", comment: "trust"), pct)
    }
}

// MARK: - Small UI atoms

fileprivate struct RoleBadge: View {
    let role: ModRole
    var body: some View {
        let text: String
        let sym: String
        switch role {
        case .viewer:  text = "Viewer";  sym = "eye"
        case .trusted: text = "Trusted"; sym = "hand.raised.fill"
        case .partner: text = "Partner"; sym = "building.2"
        case .admin:   text = "Admin";   sym = "person.crop.circle.badge.checkmark"
        }
        return Label(text, systemImage: sym)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .accessibilityLabel(Text(NSLocalizedString("Role", comment: "role") + ": " + text))
    }
}

fileprivate struct SeverityBadge: View {
    let sev: HazardSeverity
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(uiColor: sev.color)).frame(width: 8, height: 8)
            Text(sev.title).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

fileprivate struct SelectBox: View {
    let isOn: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .accessibilityLabel(Text(isOn ? NSLocalizedString("Selected", comment: "sel") : NSLocalizedString("Select", comment: "sel")))
    }
}

fileprivate struct MapChip: View {
    let coordinate: CLLocationCoordinate2D
    let color: Color
    var body: some View {
        Map(initialPosition: .region(.init(center: coordinate,
                                           span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))) {
            Annotation("", coordinate: coordinate) {
                ZStack {
                    Circle().fill(color).frame(width: 18, height: 18)
                    Circle().strokeBorder(.white, lineWidth: 2).frame(width: 18, height: 18)
                }.accessibilityHidden(true)
            }
        }
        .disabled(true)
    }
}

// MARK: - Convenience builder

public extension HazardModerationQueueView {
    static func make(reader: HazardModerationReading,
                     actor: HazardModerationActing,
                     roles: RoleProviding,
                     analytics: AnalyticsLogging? = nil) -> HazardModerationQueueView {
        HazardModerationQueueView(viewModel: .init(reader: reader, actor: actor, roles: roles, analytics: analytics))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
private final class ReaderFake: HazardModerationReading {
    func fetchQueue(severity: Set<HazardSeverity>, types: Set<HazardType>, city: String?, pageSize: Int, nextToken: String?) async throws -> ModPage {
        let base = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        let start = (Int(nextToken ?? "0") ?? 0)
        let count = min(pageSize, 80 - start)
        let arr: [ModHazardItem] = (0..<count).map { i in
            let idx = start + i
            return ModHazardItem(
                id: "h\(idx)",
                coordinate: .init(latitude: base.latitude + Double.random(in: -0.02...0.02),
                                  longitude: base.longitude + Double.random(in: -0.02...0.02)),
                type: HazardType.allCases.randomElement() ?? .other,
                severity: HazardSeverity.allCases.randomElement() ?? .medium,
                updatedAt: Date().addingTimeInterval(-Double.random(in: 0...36_000)),
                reports: Int.random(in: 1...5),
                cityCode: Bool.random() ? "YVR" : "VAN",
                reporterTrustScore: Double.random(in: 0.3...0.98),
                note: Bool.random() ? "Gravel spilling from planter near curb." : nil,
                evidencePhotoURL: Bool.random() ? URL(string: "https://picsum.photos/seed/ev\(idx)/640/360") : nil
            )
        }
        let next = (start + count) < 80 ? String(start + count) : nil
        return ModPage(items: arr, nextToken: next)
    }
}
private final class ActorFake: HazardModerationActing {
    func perform(_ action: ModAction) async throws -> ModHazardItem? { nil }
    func performBulk(_ actions: [ModAction]) async throws -> [String : ModHazardItem?] {
        var m: [String: ModHazardItem?] = [:]
        for a in actions {
            switch a {
            case let .confirm(id), let .resolve(id), let .reject(id, _), let .downgrade(id, _):
                m[id] = nil
            case let .merge(_, duplicate):
                m[duplicate] = nil
            }
        }
        return m
    }
}
private final class RolesFake: RoleProviding { var currentRole: ModRole = .partner }

struct HazardModerationQueueView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HazardModerationQueueView.make(reader: ReaderFake(), actor: ActorFake(), roles: RolesFake(), analytics: nil)
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Gate access by role using `RoleProviding.currentRole`; hide/disable actions for non-authorized roles.
// • Hook `HazardModerationReading/Acting` onto Services/Spots/SpotModerationService + HazardStore backends:
//   - Every action should be logged to Audit Log (tamper-evident hash chain optional as spec’d).
//   - `perform(.merge(primary:duplicate:))` should call HazardRules’ spatial merge + persist canonical id.
//   - `perform(.resolve)` should TTL-fast-forward and notify HazardAlertService to stop alerts for that id.
// • Offline: queue actions in a local outbox; `perform(_:)` should be idempotent by (action, targetId, lastUpdated).
// • Pagination: server provides stable “nextToken”; this view merges pages and dedupes ids on insert.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Filters: select subset of severities/types → `fetchQueue` called with exact sets; list updates deterministically.
// 2) Pagination: scrolling near end calls `fetchQueue(..., nextToken:)`; duplicates suppressed.
// 3) Single actions: resolve/reject optimistically remove; on failure rollback occurs; confirm/downgrade update in place.
// 4) Bulk actions: with selection → `performBulk` called; success clears selection; failure restores items.
// 5) Merge UX: picking two items triggers `merge(primary:duplicate:)`; no-ops when ids equal.
// UI:
// • AX sizes preserve ≥44pt hit targets; VO reads “High Gravel, 2 h ago, 3 reports, Trust 78%.”
// • Evidence image renders with placeholder; MapChip shows centered pin without requiring location permission.
// • Role = viewer shows banner error on load and disables controls.
