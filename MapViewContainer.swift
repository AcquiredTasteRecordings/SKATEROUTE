// Features/Map/MapViewContainer.swift
import SwiftUI
import MapKit

public struct MapViewContainer: UIViewRepresentable {
    public let route: MKRoute?
    public let gradeSummary: GradeSummary?
    public let stepContexts: [StepContext]
    public let routeScore: Double
    public let overlays: [MKOverlay]
    private let scorer: SkateRouteScoring
    private let mode: RideMode

    public init(route: MKRoute?,
                routeScore: Double,
                gradeSummary: GradeSummary?,
                stepContexts: [StepContext],
                overlays: [MKOverlay] = [],
                scorer: SkateRouteScoring,
                rideMode: RideMode) {
        self.route = route
        self.gradeSummary = gradeSummary
        self.stepContexts = stepContexts
        self.routeScore = routeScore
        self.overlays = overlays
        self.scorer = scorer
        self.mode = rideMode
    }

    public func makeCoordinator() -> MapPatternsCoordinator {
        MapPatternsCoordinator(scorer: scorer)
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator

        // Map view configuration
        map.showsCompass = true
        map.showsScale = true
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.pointOfInterestFilter = .includingAll
        if #available(iOS 13.0, *) {
            map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 100, maxCenterCoordinateDistance: 1_000_000)
        }
        return map
    }

    public func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.currentRouteScore = routeScore

        // Remove existing overlays
        let existing = mapView.overlays
        if !existing.isEmpty { mapView.removeOverlays(existing) }

        var overlaysToAdd: [MKOverlay] = []

                if let route, !stepContexts.isEmpty {
                    let brakingMask = gradeSummary?.brakingMask ?? stepContexts.map { $0.brakingZone }
                    let colored = SmoothOverlayBuilder.build(route: route,
                                                             contexts: stepContexts,
                                                             colorProvider: { scorer.color(for: $0, mode: mode) },
                                                             brakingMask: brakingMask)
                    overlaysToAdd.append(contentsOf: colored)
                } else if let route {
                    overlaysToAdd.append(route.polyline)
                }

                overlaysToAdd.append(contentsOf: overlays)

                if !overlaysToAdd.isEmpty {
                    mapView.addOverlays(overlaysToAdd)
                    let rect = overlaysToAdd.reduce(MKMapRect.null) { partial, overlay in
                        partial.union(overlay.boundingMapRect)
            }
            if !rect.isNull {
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 96, left: 24, bottom: 128, right: 24), animated: true)
            }
        }
    }
}

@MainActor
public final class MapPatternsCoordinator: NSObject, MKMapViewDelegate {
    public var currentRouteScore: Double = 0
    private let scorer: SkateRouteScoring
    
    public init(scorer: SkateRouteScoring) {
        self.scorer = scorer
    }
    
    public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let colored = overlay as? ColoredPolyline {
                   let renderer = ColoredPolylineRenderer(polyline: colored)
                   return renderer
               }
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
                        renderer.strokeColor = scorer.color(for: currentRouteScore)
                        renderer.lineWidth = 5
                        renderer.lineJoin = .round
                        renderer.lineCap = .round
                        return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
    
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard !(annotation is MKUserLocation) else { return nil }
        let id = "poi-marker"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.clusteringIdentifier = "poi-cluster"
    }
}
