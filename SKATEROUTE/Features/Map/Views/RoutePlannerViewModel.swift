// Features/Map/ViewModels/RoutePlannerViewModel.swift
import Foundation
import Combine
import MapKit
import CoreLocation

@MainActor
public final class RoutePlannerViewModel: ObservableObject {
    public enum PlannerLayer: String, CaseIterable, Identifiable {
        case slope
        case surface
        case safety

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .slope: return "triangle.fill"
            case .surface: return "square.grid.2x2"
            case .safety: return "exclamationmark.octagon"
            }
        }

        public var title: String {
            switch self {
            case .slope: return "Slope"
            case .surface: return "Surface"
            case .safety: return "Safety"
            }
        }
    }

    @Published public private(set) var options: [RouteOptionModel] = []
    @Published public var selectedOptionID: UUID? {
        didSet { rebuildOverlays() }
    }
    @Published public private(set) var overlays: [MKPolyline] = []
    @Published public private(set) var downloadState: OfflineTileManager.DownloadState = .idle
    @Published public var activeLayers: Set<PlannerLayer> = [.surface] {
        didSet { rebuildOverlays() }
    }
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    public var selectedOption: RouteOptionModel? {
        guard let id = selectedOptionID else { return options.first }
        return options.first(where: { $0.id == id }) ?? options.first
    }

    public var selectedRoute: MKRoute? { selectedOption?.mkRoute }
    public var selectedPolyline: MKPolyline? { selectedOption?.polyline }
    public var slopeSummary: GradeSummary? { selectedOption?.metadata.grade }
    public var etaString: String { selectedOption?.etaString ?? "--" }
    public var scoreLabel: String? { selectedOption?.scoreLabel }

    private let routeService: RouteService
    private let reducer: RouteOptionsReducer
    private let offlineTiles: OfflineTileManager
    private let offlineStore: OfflineRouteStore
    private var cancellables: Set<AnyCancellable> = []

    private var requestKey: OfflineRouteStore.RequestKey?
    private var source: CLLocationCoordinate2D?
    private var destination: CLLocationCoordinate2D?
    private var mode: RideMode?

    public init(routeService: RouteService = AppDI.shared.routeService,
                reducer: RouteOptionsReducer = AppDI.shared.routeOptionsReducer,
                offlineTiles: OfflineTileManager = AppDI.shared.offlineTileManager,
                offlineStore: OfflineRouteStore = AppDI.shared.offlineRouteStore) {
        self.routeService = routeService
        self.reducer = reducer
        self.offlineTiles = offlineTiles
        self.offlineStore = offlineStore

        offlineTiles.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.downloadState = state
            }
            .store(in: &cancellables)
    }

    public func planRoutes(source: CLLocationCoordinate2D,
                           destination: CLLocationCoordinate2D,
                           mode: RideMode) {
        self.source = source
        self.destination = destination
        self.mode = mode
        let key = OfflineRouteStore.RequestKey(source: source, destination: destination, mode: mode)
        self.requestKey = key

        loadCachedOptions(for: key)
        Task { await fetchRoutes(for: key) }
    }

    public func reroute(from newSource: CLLocationCoordinate2D) {
        guard let destination, let mode else { return }
        planRoutes(source: newSource, destination: destination, mode: mode)
    }

    public func select(option: RouteOptionModel) {
        selectedOptionID = option.id
    }

    public func downloadSelectedForOffline() {
        guard let option = selectedOption, let key = requestKey else { return }
        Task { [weak self] in
            await self?.performOfflineDownload(option: option, key: key)
        }
    }

    // MARK: - Private helpers

    private func loadCachedOptions(for key: OfflineRouteStore.RequestKey) {
        guard let snapshots = offlineStore.load(for: key) else {
            self.options = []
            self.selectedOptionID = nil
            self.downloadState = offlineTiles.hasTiles(for: tileIdentifier(for: key)) ? .cached : .idle
            return
        }

        let models = snapshots.map(RouteOptionModel.init(snapshot:))
        self.options = models
        if let first = models.first { self.selectedOptionID = first.id }
        self.downloadState = offlineTiles.hasTiles(for: tileIdentifier(for: key)) ? .cached : .idle
        rebuildOverlays()
    }

    private func fetchRoutes(for key: OfflineRouteStore.RequestKey) async {
        guard let source, let destination, let mode else { return }
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }

        do {
            let candidates = try await routeService.routeOptions(from: source, to: destination)
            let presentations = reducer.evaluate(candidates: candidates, mode: mode)
            let models = candidates.compactMap { candidate -> RouteOptionModel? in
                guard let presentation = presentations[candidate.id] else { return nil }
                return RouteOptionModel(candidate: candidate, presentation: presentation)
            }

            await MainActor.run {
                self.options = models
                if let current = self.selectedOptionID,
                   models.contains(where: { $0.id == current }) == false {
                    self.selectedOptionID = models.first?.id
                } else if self.selectedOptionID == nil {
                    self.selectedOptionID = models.first?.id
                }
                self.isLoading = false
                self.errorMessage = nil
                self.rebuildOverlays()
            }

            let snapshots = models.map { $0.makeSnapshot() }
            offlineStore.store(snapshots, for: key)
            if offlineTiles.hasTiles(for: tileIdentifier(for: key)) {
                await MainActor.run { self.downloadState = .cached }
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func performOfflineDownload(option: RouteOptionModel,
                                         key: OfflineRouteStore.RequestKey) async {
        await offlineTiles.ensureTiles(for: option.polyline, identifier: tileIdentifier(for: key))
        let snapshots = options.map { $0.makeSnapshot() }
        offlineStore.store(snapshots, for: key)
        if let index = options.firstIndex(where: { $0.id == option.id }) {
            options[index].markCached()
        }
    }

    private func rebuildOverlays() {
        guard let option = selectedOption else {
            overlays = []
            return
        }

        var result: [MKPolyline] = []
        if option.mkRoute == nil {
            result.append(option.polyline)
        }

        if let route = option.mkRoute {
            if activeLayers.contains(.slope) {
                result.append(contentsOf: slopeOverlays(for: route, metadata: option.metadata))
            }
            if activeLayers.contains(.surface) {
                result.append(contentsOf: surfaceOverlays(for: route, metadata: option.metadata))
            }
            if activeLayers.contains(.safety) {
                result.append(contentsOf: safetyOverlays(for: route, metadata: option.metadata))
            }
        }

        overlays = result
    }

    private func slopeOverlays(for route: MKRoute,
                               metadata: RouteService.RouteCandidateMetadata) -> [MKPolyline] {
        let steps = route.steps
        let mask = metadata.grade.brakingMask
        guard !steps.isEmpty else { return [] }
        var overlays: [MKPolyline] = []
        for (idx, step) in steps.enumerated() where idx < mask.count && mask[idx] {
            let coords = step.polyline.coordinates()
            guard coords.count > 1 else { continue }
            let poly = MKPolyline(coordinates: coords, count: coords.count)
            poly.title = "#FF3B30"
            overlays.append(poly)
        }
        return overlays
    }

    private func surfaceOverlays(for route: MKRoute,
                                 metadata: RouteService.RouteCandidateMetadata) -> [MKPolyline] {
        let steps = route.steps
        guard !steps.isEmpty else { return [] }
        var overlays: [MKPolyline] = []
        for (idx, step) in steps.enumerated() where idx < metadata.stepContexts.count {
            let ctx = metadata.stepContexts[idx]
            let coords = step.polyline.coordinates()
            guard coords.count > 1 else { continue }
            if ctx.tags.surfaceRough {
                let poly = MKPolyline(coordinates: coords, count: coords.count)
                poly.title = "#FF9F0A"
                overlays.append(poly)
            } else if ctx.tags.hasProtectedLane {
                let poly = MKPolyline(coordinates: coords, count: coords.count)
                poly.title = "#34C759"
                overlays.append(poly)
            }
        }
        return overlays
    }

    private func safetyOverlays(for route: MKRoute,
                                metadata: RouteService.RouteCandidateMetadata) -> [MKPolyline] {
        let steps = route.steps
        guard !steps.isEmpty else { return [] }
        var overlays: [MKPolyline] = []
        for (idx, step) in steps.enumerated() where idx < metadata.stepContexts.count {
            let ctx = metadata.stepContexts[idx]
            guard ctx.tags.hazardCount > 0 else { continue }
            let coords = step.polyline.coordinates()
            guard coords.count > 1 else { continue }
            let poly = MKPolyline(coordinates: coords, count: coords.count)
            poly.title = "#FFD60A|dash"
            overlays.append(poly)
        }
        return overlays
    }

    private func tileIdentifier(for key: OfflineRouteStore.RequestKey) -> String {
        key.cacheKey
    }
}

// MARK: - RouteOptionModel

public struct RouteOptionModel: Identifiable, Codable {
    public struct Coordinate: Codable {
        public let latitude: Double
        public let longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        public init(coordinate: CLLocationCoordinate2D) {
            self.latitude = coordinate.latitude
            self.longitude = coordinate.longitude
        }

        public var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    public let id: UUID
    public let candidateID: String
    public let title: String
    public let detail: String
    public let score: Double
    public let scoreLabel: String
    public let roughnessEstimate: Double
    public let distance: Double
    public let travelTime: Double
    public let metadata: RouteService.RouteCandidateMetadata
    public let polylineCoordinates: [Coordinate]
    public var cachedAt: Date

    public var mkRoute: MKRoute?

    enum CodingKeys: String, CodingKey {
        case id
        case candidateID
        case title
        case detail
        case score
        case scoreLabel
        case roughnessEstimate
        case distance
        case travelTime
        case metadata
        case polylineCoordinates
        case cachedAt
    }

    public init(candidate: RouteService.RouteCandidate, presentation: RouteOptionsReducer.Presentation) {
        self.id = UUID()
        self.candidateID = candidate.id
        self.title = presentation.title
        self.detail = presentation.detail
        self.score = presentation.score
        self.scoreLabel = presentation.scoreLabel
        self.roughnessEstimate = presentation.roughnessEstimate
        self.distance = candidate.route.distance
        self.travelTime = candidate.route.expectedTravelTime
        self.metadata = candidate.metadata
        self.polylineCoordinates = candidate.route.polyline.coordinates().map(Coordinate.init(coordinate:))
        self.cachedAt = Date()
        self.mkRoute = candidate.route
    }

    public init(snapshot: OfflineRouteStore.Snapshot) {
        self.id = snapshot.id
        self.candidateID = snapshot.candidateID
        self.title = snapshot.title
        self.detail = snapshot.detail
        self.score = snapshot.score
        self.scoreLabel = snapshot.scoreLabel
        self.roughnessEstimate = snapshot.roughnessEstimate
        self.distance = snapshot.distance
        self.travelTime = snapshot.travelTime
        self.metadata = snapshot.metadata
        self.polylineCoordinates = snapshot.polyline.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        self.cachedAt = snapshot.cachedAt
        self.mkRoute = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.candidateID = try container.decode(String.self, forKey: .candidateID)
        self.title = try container.decode(String.self, forKey: .title)
        self.detail = try container.decode(String.self, forKey: .detail)
        self.score = try container.decode(Double.self, forKey: .score)
        self.scoreLabel = try container.decode(String.self, forKey: .scoreLabel)
        self.roughnessEstimate = try container.decode(Double.self, forKey: .roughnessEstimate)
        self.distance = try container.decode(Double.self, forKey: .distance)
        self.travelTime = try container.decode(Double.self, forKey: .travelTime)
        self.metadata = try container.decode(RouteService.RouteCandidateMetadata.self, forKey: .metadata)
        self.polylineCoordinates = try container.decode([Coordinate].self, forKey: .polylineCoordinates)
        self.cachedAt = try container.decode(Date.self, forKey: .cachedAt)
        self.mkRoute = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(candidateID, forKey: .candidateID)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(score, forKey: .score)
        try container.encode(scoreLabel, forKey: .scoreLabel)
        try container.encode(roughnessEstimate, forKey: .roughnessEstimate)
        try container.encode(distance, forKey: .distance)
        try container.encode(travelTime, forKey: .travelTime)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(polylineCoordinates, forKey: .polylineCoordinates)
        try container.encode(cachedAt, forKey: .cachedAt)
    }

    public var polyline: MKPolyline {
        let coords = polylineCoordinates.map { $0.clCoordinate }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    public var etaString: String {
        let minutes = max(1, Int(round(travelTime / 60)))
        return "\(minutes) min"
    }

    public var distanceString: String {
        let km = distance / 1000.0
        return String(format: "%.1f km", km)
    }

    public mutating func markCached() {
        cachedAt = Date()
    }

    public func makeSnapshot() -> OfflineRouteStore.Snapshot {
        let coords = polylineCoordinates.map { OfflineRouteStore.Snapshot.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        return OfflineRouteStore.Snapshot(id: id,
                                          candidateID: candidateID,
                                          title: title,
                                          detail: detail,
                                          score: score,
                                          scoreLabel: scoreLabel,
                                          roughnessEstimate: roughnessEstimate,
                                          distance: distance,
                                          travelTime: travelTime,
                                          metadata: metadata,
                                          polyline: coords,
                                          cachedAt: cachedAt)
    }
}       
