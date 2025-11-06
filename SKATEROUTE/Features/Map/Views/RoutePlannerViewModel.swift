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
    
    private let routeService: RoutingService
    private let reducer: RouteOptionsReducing
    private let offlineTiles: OfflineTileManaging
    private let offlineStore: OfflineRouteStoring
    private var cancellables: Set<AnyCancellable> = []
    
    private var requestKey: OfflineRouteStore.RequestKey?
    private var source: CLLocationCoordinate2D?
    private var destination: CLLocationCoordinate2D?
    private var mode: RideMode?
    
    public init(routeService: RoutingService,
                reducer: RouteOptionsReducing,
                offlineTiles: OfflineTileManaging,
                offlineStore: OfflineRouteStoring) {
        self.routeService = routeService
        self.reducer = reducer
        self.offlineTiles = offlineTiles
        self.offlineStore = offlineStore
        self.downloadState = offlineTiles.currentState()
        
        offlineTiles.statePublisher
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
}
