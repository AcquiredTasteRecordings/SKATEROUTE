// Features/Map/MapViewContainer.swift
// Reusable MKMapView wrapper with colored-step overlays, hazards, and follow-user camera.

import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Public API

/// Lightweight hazard model for map pins. Extend as needed (e.g., severity).
public struct HazardPin: Identifiable, Hashable {
    public let id: UUID
    public let coordinate: CLLocationCoordinate2D
    public let title: String?
    public let subtitle: String?

    public init(id: UUID = UUID(),
                coordinate: CLLocationCoordinate2D,
                title: String? = nil,
                subtitle: String? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

/// Paint for a route step. If you already have `StepPaint` elsewhere, you can pass a mapped array.
public struct StepPaint: Hashable {
    public let stepIndex: Int
    public let color: UIColor
    public init(stepIndex: Int, color: UIColor) {
        self.stepIndex = stepIndex
        self.color = color
    }
}

/// A drop-in MapKit container optimized for our routing UI.
public struct MapViewContainer: UIViewRepresentable {
    // Data
    public var selectedRoute: MKRoute?
    public var stepPaints: [StepPaint] = []
    public var hazards: [HazardPin] = []
    public var showsUserLocation: Bool = true

    // Camera behavior
    @Binding public var followUser: Bool
    public var focusOnRouteChange: Bool = true

    // Callbacks
    public var onMapReady: (() -> Void)?
    public var onRegionDidChange: ((_ center: CLLocationCoordinate2D, _ reason: MKMapView.CameraChangeReason) -> Void)?

    public init(selectedRoute: MKRoute?,
                stepPaints: [StepPaint] = [],
                hazards: [HazardPin] = [],
                showsUserLocation: Bool = true,
                followUser: Binding<Bool>,
                focusOnRouteChange: Bool = true,
                onMapReady: (() -> Void)? = nil,
                onRegionDidChange: ((_ center: CLLocationCoordinate2D, _ reason: MKMapView.CameraChangeReason) -> Void)? = nil) {
        self.selectedRoute = selectedRoute
        self.stepPaints = stepPaints
        self.hazards = hazards
        self.showsUserLocation = showsUserLocation
        self._followUser = followUser
        self.focusOnRouteChange = focusOnRouteChange
        self.onMapReady = onMapReady
        self.onRegionDidChange = onRegionDidChange
    }

    public func makeCoordinator() -> Coord { Coord(parent: self) }

    public func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView(frame: .zero)
        mv.delegate = context.coordinator
        mv.mapType = .standard
        mv.isRotateEnabled = true
        mv.isPitchEnabled = true
        mv.showsCompass = false
        mv.showsScale = false
        mv.showsUserLocation = showsUserLocation
        mv.pointOfInterestFilter = .includingAll
        mv.accessibilityIdentifier = "MapViewContainer.MKMapView"

        // Tweak performance defaults for smoother overlay rendering
        mv.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)

        context.coordinator.installInitialContent(on: mv,
                                                  route: selectedRoute,
                                                  paints: stepPaints,
                                                  hazards: hazards,
                                                  focus: focusOnRouteChange)
        onMapReady?()
        return mv
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        // User location visibility
        if map.showsUserLocation != showsUserLocation {
            map.showsUserLocation = showsUserLocation
        }
        // Follow-user camera
        context.coordinator.updateFollowUser(followUser, on: map)

        // Diff overlays/annotations rather than wipe-and-readd everything.
        context.coordinator.apply(route: selectedRoute,
                                  paints: stepPaints,
                                  hazards: hazards,
                                  on: map,
                                  focus: focusOnRouteChange)
    }

    // MARK: - Coordinator

    public final class Coord: NSObject, MKMapViewDelegate {
        private weak var mapView: MKMapView?
        private var currentRouteObjectId: ObjectIdentifier?
        private var overlayBag: [MKOverlay] = []
        private var hazardBag: [MKPointAnnotation] = []
        private var pendingInitialFocus = true

        private var isFollowingUser = false
        private var headingEnabled = false

        private let polylineLineWidth: CGFloat = 6

        private let parent: MapViewContainer
        init(parent: MapViewContainer) { self.parent = parent }

        // First-time install to avoid map “pop-in”
        func installInitialContent(on map: MKMapView,
                                   route: MKRoute?,
                                   paints: [StepPaint],
                                   hazards: [HazardPin],
                                   focus: Bool) {
            self.mapView = map
            apply(route: route, paints: paints, hazards: hazards, on: map, focus: focus)
        }

        func updateFollowUser(_ follow: Bool, on map: MKMapView) {
            guard isFollowingUser != follow else { return }
            isFollowingUser = follow
            if follow {
                // Engage a gentle camera lock; don’t force heading unless we add a toggle.
                let cam = MKMapCamera(lookingAtCenter: map.userLocation.coordinate,
                                      fromDistance: 700,
                                      pitch: 45,
                                      heading: map.camera.heading)
                map.setCamera(cam, animated: true)
            }
        }

        // MARK: Overlay/Annotation Diffing

        func apply(route: MKRoute?,
                   paints: [StepPaint],
                   hazards: [HazardPin],
                   on map: MKMapView,
                   focus: Bool) {
            // Route change?
            let routeId = route.map { ObjectIdentifier($0) }
            let routeChanged = routeId != currentRouteObjectId

            if routeChanged {
                // Remove old overlays and rebuild
                if !overlayBag.isEmpty { map.removeOverlays(overlayBag); overlayBag.removeAll() }
                if !hazardBag.isEmpty { map.removeAnnotations(hazardBag); hazardBag.removeAll() }

                guard let route else { return }
                currentRouteObjectId = routeId

                // Build new step overlays
                let colorByStep = Dictionary(uniqueKeysWithValues: paints.map { ($0.stepIndex, $0.color) })
                var newOverlays: [MKOverlay] = []
                for (i, step) in route.steps.enumerated() {
                    guard step.polyline.pointCount > 1 else { continue }
                    if let c = colorByStep[i] {
                        let cp = PaintedPolyline(points: step.polyline)
                        cp.stepIndex = i
                        cp.color = c
                        newOverlays.append(cp)
                    } else {
                        newOverlays.append(step.polyline)
                    }
                }
                map.addOverlays(newOverlays)
                overlayBag = newOverlays

                // Add hazards
                if !hazards.isEmpty {
                    let anns = hazards.map { pin -> MKPointAnnotation in
                        let a = MKPointAnnotation()
                        a.coordinate = pin.coordinate
                        a.title = pin.title
                        a.subtitle = pin.subtitle
                        return a
                    }
                    map.addAnnotations(anns)
                    hazardBag = anns
                }

                // Initial camera
                if focus || pendingInitialFocus {
                    pendingInitialFocus = false
                    let rect = route.polyline.boundingMapRect.insetBy(dx: -180, dy: -180)
                    map.setVisibleMapRect(rect,
                                          edgePadding: UIEdgeInsets(top: 48, left: 32, bottom: 200, right: 32),
                                          animated: true)
                }
            } else {
                // Same route object — live repaint only
                refreshPaints(paints, on: map)
                // Diff hazard annotations: remove old missing ones, add new
                syncHazards(hazards, on: map)
            }
        }

        private func refreshPaints(_ paints: [StepPaint], on map: MKMapView) {
            guard !overlayBag.isEmpty else { return }
            let byIndex = Dictionary(uniqueKeysWithValues: paints.map { ($0.stepIndex, $0.color) })
            var dirty: [MKOverlay] = []
            for overlay in overlayBag {
                guard let pp = overlay as? PaintedPolyline, let idx = pp.stepIndex else { continue }
                if let newColor = byIndex[idx], newColor != pp.color {
                    pp.color = newColor
                    dirty.append(pp)
                }
            }
            // Refresh renderers for dirtied overlays
            if !dirty.isEmpty {
                map.removeOverlays(dirty)
                map.addOverlays(dirty, level: .aboveLabels)
            }
        }

        private func syncHazards(_ desired: [HazardPin], on map: MKMapView) {
            // Simple O(n) diff keyed by coordinate string.
            let key: (HazardPin) -> String = { "\($0.coordinate.latitude.rounded(to: 6)),\($0.coordinate.longitude.rounded(to: 6))" }
            let desiredKeys = Set(desired.map(key))
            let currentKeys = Set(hazardBag.map { "\($0.coordinate.latitude.rounded(to: 6)),\($0.coordinate.longitude.rounded(to: 6))" })

            // Remove missing
            let toRemove = hazardBag.filter { !desiredKeys.contains("\($0.coordinate.latitude.rounded(to: 6)),\($0.coordinate.longitude.rounded(to: 6))") }
            if !toRemove.isEmpty {
                map.removeAnnotations(toRemove)
                hazardBag.removeAll(where: { toRemove.contains($0) })
            }

            // Add new
            let toAdd = desired.filter { !currentKeys.contains(key($0)) }
            if !toAdd.isEmpty {
                let anns = toAdd.map { pin -> MKPointAnnotation in
                    let a = MKPointAnnotation()
                    a.coordinate = pin.coordinate
                    a.title = pin.title
                    a.subtitle = pin.subtitle
                    return a
                }
                map.addAnnotations(anns)
                hazardBag.append(contentsOf: anns)
            }
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let pp = overlay as? PaintedPolyline {
                let r = MKPolylineRenderer(polyline: pp)
                r.strokeColor = pp.color.withAlphaComponent(0.94)
                r.lineWidth = polylineLineWidth
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            if let pl = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: pl)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.75)
                r.lineWidth = polylineLineWidth - 1
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionDidChange?(mapView.centerCoordinate, mapView.cameraChangeReason)
            // If user panned/zoomed manually, disable follow until toggled again.
            if mapView.cameraChangeReason.contains(.gesturePan) || mapView.cameraChangeReason.contains(.gestureZoom) {
                if isFollowingUser { isFollowingUser = false }
            }
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = "hazard.pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView) ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.displayPriority = .required
            view.animatesWhenAdded = true
            view.canShowCallout = true
            view.markerTintColor = UIColor.systemRed
            view.glyphImage = UIImage(systemName: "exclamationmark.triangle.fill")
            view.accessibilityLabel = (annotation.title ?? nil) ?? "Hazard"
            return view
        }
    }
}

// MARK: - Private Types

/// In-memory colored polyline for per-step rendering.
private final class PaintedPolyline: MKPolyline {
    fileprivate var color: UIColor = .systemBlue
    fileprivate var stepIndex: Int?
    convenience init(points: MKPolyline) {
        var buf = [MKMapPoint](repeating: .init(), count: points.pointCount)
        points.getPoints(&buf, range: NSRange(location: 0, length: points.pointCount))
        self.init(points: buf, count: buf.count)
    }
}

// MARK: - Utilities

private extension Double {
    func rounded(to places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}


