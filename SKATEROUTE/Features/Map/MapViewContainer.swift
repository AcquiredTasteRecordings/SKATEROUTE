// Features/Map/MapViewContainer.swift
import SwiftUI
import MapKit

public struct MapViewContainer: UIViewRepresentable {
    public let route: MKRoute?
    public let routeScore: Double
    public let overlays: [MKPolyline]
    private let scorer: SkateRouteScoring

    public init(route: MKRoute?,
                routeScore: Double,
                overlays: [MKPolyline] = [],
                scorer: SkateRouteScoring) {
        self.route = route
        self.routeScore = routeScore
        self.overlays = overlays
        self.scorer = scorer
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

        if !overlays.isEmpty {
            mapView.addOverlays(overlays)
            // Fit to all overlays' bounding rects
            let rect = overlays.reduce(MKMapRect.null) { partial, o in
                partial.union(o.boundingMapRect)
            }
            if !rect.isNull {
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 96, left: 24, bottom: 128, right: 24), animated: true)
            }
        } else if let r = route {
            mapView.addOverlay(r.polyline)
            mapView.setVisibleMapRect(r.polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 96, left: 24, bottom: 128, right: 24), animated: true)
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
        if let polyline = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: polyline)
            // Default color from route score if no metadata present
            var stroke = scorer.color(for: currentRouteScore)
            var dash: [NSNumber]? = nil
            if let title = polyline.title, !title.isEmpty {
                // Expect format: "#RRGGBB" or "#RRGGBB|dash"
                let parts = title.split(separator: "|")
                if let hex = parts.first, let parsed = UIColor(hex6: String(hex)) {
                    stroke = parsed
                }
                if parts.count > 1, parts[1] == "dash" { dash = [6, 8] }
            }
            r.strokeColor = stroke
            r.lineWidth = 6
            r.lineJoin = .round
            r.lineCap = .round
            r.lineDashPattern = dash
            return r
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
