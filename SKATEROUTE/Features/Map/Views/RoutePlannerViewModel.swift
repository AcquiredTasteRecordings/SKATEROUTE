// Features/Map/Views/RoutePlannerViewModel.swift
// Plans routes, ranks options, and exposes UI-ready presentations.
// MapKit-first, async/await, cancel-safe, and offline-tiles aware.

import Foundation
import Combine
import CoreLocation
import MapKit
import UIKit

@MainActor
public final class RoutePlannerViewModel: ObservableObject {

    // MARK: - Inputs (DI)
    private let routeService: RoutingService
    private let reducer: RouteOptionsReducing
    private let offlineTiles: OfflineTileManaging
    private let offlineStore: OfflineRouteStoring

    // MARK: - Planning Parameters
    @Published public var source: CLLocationCoordinate2D?
    @Published public var destination: CLLocationCoordinate2D?
    @Published public var mode: RideMode = .init() // keep generic; your RideMode can be a struct/enum
    @Published public var preferSkateLegal: Bool = true

    // MARK: - Output (UI State)
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }
    @Published public private(set) var state: LoadState = .idle

    // Candidate presentations keyed by candidate id
    @Published public private(set) var presentations: [String: RouteOptionsReducer.Presentation] = [:]
    // Stable order of candidates (ids) to render in UI
    @Published public private(set) var orderedCandidateIDs: [String] = []
    // Selected candidate id
    @Published public private(set) var selectedCandidateID: String?

    // Selected route exposure for map
    @Published public private(set) var selectedRoute: MKRoute?

    // Offline tile state passthrough
    @Published public private(set) var offlineState: OfflineTileManager.DownloadState

    // Human-friendly banner copy
    @Published public private(set) var bannerText: String?

    // MARK: - Internals
    private var cancellables = Set<AnyCancellable>()
    private var planTask: Task<Void, Never>?
    private var ensureTilesTask: Task<Void, Never>?

    // MARK: - Init

    public init(routeService: RoutingService,
                reducer: RouteOptionsReducing,
                offlineTiles: OfflineTileManaging,
                offlineStore: OfflineRouteStoring) {

        self.routeService = routeService
        self.reducer = reducer
        self.offlineTiles = offlineTiles
        self.offlineStore = offlineStore
        self.offlineState = offlineTiles.currentState()

        // Pipe tile state to @Published
        offlineTiles.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.offlineState = $0 }
            .store(in: &cancellables)

        // If source/destination change, we can auto-plan with debounce (UX choice).
        Publishers.CombineLatest($source, $destination)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] src, dst in
                guard let self, let src, let dst else { return }
                if case .loading = self.state { return }
                self.plan(from: src, to: dst, userInitiated: false)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Commands

    /// Main entry point: plan + rank + present.
    public func plan(from src: CLLocationCoordinate2D, to dst: CLLocationCoordinate2D, userInitiated: Bool = true) {
        source = src; destination = dst
        // Cancel any in-flight plan to prevent races and UI flicker.
        planTask?.cancel()
        state = .loading
        bannerText = userInitiated ? NSLocalizedString("Planning route…", comment: "route planning in progress") : nil

        planTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await routeService.routeOptions(
                    from: src,
                    to: dst,
                    mode: mode,
                    preferSkateLegal: preferSkateLegal
                )

                // Reduce to UI-ready cards/paints
                let map = reducer.evaluate(candidates: candidates, mode: mode)

                // Order: Fastest ETA first, stable fallback by id
                let ordered = candidates
                    .map(\.id)
                    .sorted { lhs, rhs in
                        let lETA = candidates.first(where: { $0.id == lhs })!.route.expectedTravelTime
                        let rETA = candidates.first(where: { $0.id == rhs })!.route.expectedTravelTime
                        return lETA < rETA || (lETA == rETA && lhs < rhs)
                    }

                // Choose the initial selection: best score if present, else fastest (ordered[0])
                let bestId = RoutePlannerViewModel.bestCandidateID(candidates: candidates, presentations: map) ?? ordered.first

                // Commit to UI
                self.presentations = map
                self.orderedCandidateIDs = ordered
                self.selectedCandidateID = bestId
                self.selectedRoute = if let id = bestId {
                    candidates.first(where: { $0.id == id })?.route
                } else { nil }
                self.state = .loaded
                self.bannerText = self.makeBanner(for: bestId)

                // Opportunistically ensure tiles for the chosen route (non-blocking).
                if let route = self.selectedRoute, let id = bestId {
                    self.ensureTilesTask?.cancel()
                    self.ensureTilesTask = Task { [weak self] in
                        await self?.ensureTiles(for: route, identifier: id)
                    }
                }
            } catch is CancellationError {
                // Ignore — replaced by a newer plan
            } catch {
                self.presentations = [:]
                self.orderedCandidateIDs = []
                self.selectedCandidateID = nil
                self.selectedRoute = nil
                self.state = .error(Self.format(error))
                self.bannerText = NSLocalizedString("Routing failed. Try again.", comment: "routing failed")
            }
        }
    }

    /// User tapped a card — switch the active route and ensure tiles.
    public func selectCandidate(id: String) {
        guard let currentIDs = orderedCandidateIDs.firstIndex(of: id) else { return }
        selectedCandidateID = id
        // Try to find a route by id from current presentations — we need the MKRoute again.
        // We can re-request directions for precision but that would be wasteful;
        // instead, we compute a light hash and ask RouteService again only if necessary.
        Task { [weak self] in
            guard let self, let src = self.source, let dst = self.destination else { return }
            do {
                let candidates = try await routeService.routeOptions(from: src, to: dst, mode: mode, preferSkateLegal: preferSkateLegal)
                if let route = candidates.first(where: { $0.id == id })?.route {
                    self.selectedRoute = route
                    await self.ensureTiles(for: route, identifier: id)
                    self.bannerText = self.makeBanner(for: id)
                }
            } catch {
                // Soft fail: keep previous selection if present.
            }
        }
        _ = currentIDs // silence unused if not needed in future
    }

    /// Clears current results (used when user resets planner UI).
    public func clear() {
        planTask?.cancel(); ensureTilesTask?.cancel()
        presentations = [:]
        orderedCandidateIDs = []
        selectedCandidateID = nil
        selectedRoute = nil
        state = .idle
        bannerText = nil
    }

    // MARK: - Offline Tiles

    private func ensureTiles(for route: MKRoute, identifier: String) async {
        // Dedup by id — if tiles already exist, skip download.
        guard !offlineTiles.hasTiles(for: identifier) else { return }
        await offlineTiles.ensureTiles(for: route.polyline, identifier: identifier)
    }

    // MARK: - Helpers

    private func makeBanner(for candidateID: String?) -> String? {
        guard
            let id = candidateID,
            let p = presentations[id]
        else { return nil }
        // Example: “Best Route · 4.2 km • 18 min · Friendly”
        let title = p.title
        return "\(title) · \(p.distanceText) • \(p.etaText) · \(p.scoreLabel)"
    }

    private static func bestCandidateID(
        candidates: [RouteService.RouteCandidate],
        presentations: [String: RouteOptionsReducer.Presentation]
    ) -> String? {
        // Pick highest score, break ties by shortest ETA.
        let scored: [(id: String, score: Double, eta: TimeInterval)] = candidates.compactMap { cand in
            guard let p = presentations[cand.id] else { return nil }
            return (id: cand.id, score: p.score, eta: cand.route.expectedTravelTime)
        }
        return scored.max { lhs, rhs in
            if lhs.score == rhs.score { return lhs.eta > rhs.eta }
            return lhs.score < rhs.score
        }?.id
    }

    private static func format(_ error: Error) -> String {
        // Keep user-facing copy minimal; details go to logs if you instrument.
        let ns = error as NSError
        // Localized fallback
        let generic = NSLocalizedString("Something went sideways while planning.", comment: "generic routing error")
        if ns.domain == NSURLErrorDomain { return NSLocalizedString("Network issue. Check your connection.", comment: "network error") }
        return generic
    }
}
