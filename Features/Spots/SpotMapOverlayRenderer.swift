// Features/Spots/SpotMapOverlayRenderer.swift
// Clustered spot pins with category-aware styling (MapKit-first).
// - Uses MKMapView clustering for perf; stable reuse identifiers; zero layout thrash.
// - Category colors/icons align with Resources/SpotCategories.json (see `SpotCategory` mapping shim).
// - SwiftUI wrapper with diffed annotation updates and optional selection callback.
// - A11y: VO labels summarize name + category; large hit targets; high-contrast glyphs.
// - Privacy: no tracking; no reverse geocoding here. Coordinates are what SpotStore supplies.

import SwiftUI
import MapKit
import Combine

// MARK: - Category model (align with your canonical SpotCategories.json)

public enum SpotCategory: String, CaseIterable, Codable, Sendable {
    case park, plaza, ledge, rail, bowl, DIY, shop, other

    public var title: String {
        switch self {
        case .park: return NSLocalizedString("Skatepark", comment: "")
        case .plaza: return NSLocalizedString("Plaza", comment: "")
        case .ledge: return NSLocalizedString("Ledges", comment: "")
        case .rail: return NSLocalizedString("Rails", comment: "")
        case .bowl: return NSLocalizedString("Bowls", comment: "")
        case .DIY: return NSLocalizedString("DIY", comment: "")
        case .shop: return NSLocalizedString("Shop", comment: "")
        case .other: return NSLocalizedString("Spot", comment: "")
        }
    }

    // SF Symbol to keep bundle lean; map to your asset set if preferred
    public var symbol: String {
        switch self {
        case .park:  return "figure.skating"
        case .plaza: return "building.2"
        case .ledge: return "rectangle.split.3x1"
        case .rail:  return "line.diagonal"
        case .bowl:  return "circle.grid.2x2"
        case .DIY:   return "hammer"
        case .shop:  return "bag"
        case .other: return "mappin"
        }
    }

    public var color: UIColor {
        switch self {
        case .park:  return UIColor.systemGreen
        case .plaza: return UIColor.systemBlue
        case .ledge: return UIColor.systemTeal
        case .rail:  return UIColor.systemOrange
        case .bowl:  return UIColor.systemPurple
        case .DIY:   return UIColor.systemRed
        case .shop:  return UIColor.systemPink
        case .other: return UIColor.systemGray
        }
    }
}

// MARK: - Annotation model (value from SpotStore)

public struct SpotPin: Identifiable, Hashable, Sendable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let name: String
    public let category: SpotCategory
    public let isVerified: Bool
    public let rating: Int? // 1..5 optional
    public init(id: String, coordinate: CLLocationCoordinate2D, name: String, category: SpotCategory, isVerified: Bool = false, rating: Int? = nil) {
        self.id = id; self.coordinate = coordinate; self.name = name; self.category = category; self.isVerified = isVerified; self.rating = rating
    }
}

// Internal MKAnnotation wrapper (stable identity + reuse)
final class SpotAnno: NSObject, MKAnnotation {
    let pin: SpotPin
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { pin.name }
    var subtitle: String? { pin.category.title }
    init(_ pin: SpotPin) {
        self.pin = pin
        self.coordinate = pin.coordinate
        super.init()
    }
}

// MARK: - SwiftUI wrapper

public struct SpotMapOverlayRenderer: UIViewRepresentable {
    public typealias OnSelect = (SpotPin) -> Void

    private let pins: [SpotPin]
    private let selectedCategoryFilter: Set<SpotCategory>?
    private let showsUserLocation: Bool
    private let onSelect: OnSelect?

    // Tuning
    private let clusterID = "spot.cluster"
    private let markerID  = "spot.marker"

    public init(pins: [SpotPin],
                selectedCategoryFilter: Set<SpotCategory>? = nil,
                showsUserLocation: Bool = true,
                onSelect: OnSelect? = nil) {
        self.pins = pins
        self.selectedCategoryFilter = selectedCategoryFilter
        self.showsUserLocation = showsUserLocation
        self.onSelect = onSelect
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = showsUserLocation
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: markerID)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: clusterID)
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        map.isRotateEnabled = false // free battery + steadier orientation for skating
        context.coordinator.applyAnnotations(on: map, pins: pins, filter: selectedCategoryFilter)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyAnnotations(on: map, pins: pins, filter: selectedCategoryFilter)
        // Keep userLocation visibility as requested
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(markerID: markerID, clusterID: clusterID, onSelect: onSelect)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let markerID: String
        private let clusterID: String
        private let onSelect: OnSelect?
        private var annoIndex: [String: SpotAnno] = [:] // id -> anno

        init(markerID: String, clusterID: String, onSelect: OnSelect?) {
            self.markerID = markerID
            self.clusterID = clusterID
            self.onSelect = onSelect
        }

        // Diff annotations cheaply by id to avoid full clears
        func applyAnnotations(on map: MKMapView, pins: [SpotPin], filter: Set<SpotCategory>?) {
            let filtered = filter == nil ? pins : pins.filter { filter!.contains($0.category) }
            let newIDs = Set(filtered.map { $0.id })
            let oldIDs = Set(annoIndex.keys)

            // Remove stale
            let toRemove = oldIDs.subtracting(newIDs)
            if !toRemove.isEmpty {
                let removeAnnos = toRemove.compactMap { annoIndex[$0] }
                map.removeAnnotations(removeAnnos)
                removeAnnos.forEach { annoIndex.removeValue(forKey: $0.pin.id) }
            }

            // Insert new
            let toInsert = newIDs.subtracting(oldIDs)
            if !toInsert.isEmpty {
                let newAnnos = filtered.filter { toInsert.contains($0.id) }.map { SpotAnno($0) }
                newAnnos.forEach { annoIndex[$0.pin.id] = $0 }
                map.addAnnotations(newAnnos)
            }

            // Update moved pins (rare)
            for pin in filtered {
                if let anno = annoIndex[pin.id], !anno.coordinate.equal(to: pin.coordinate) {
                    anno.coordinate = pin.coordinate
                }
            }
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Skip user location
            if annotation is MKUserLocation { return nil }

            // Cluster view
            if let cluster = annotation as? MKClusterAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: clusterID, for: cluster) as! MKMarkerAnnotationView
                v.clusteringIdentifier = nil // clusters don't re-cluster
                v.displayPriority = .defaultHigh
                v.titleVisibility = .hidden
                v.subtitleVisibility = .hidden
                v.canShowCallout = false

                // Derive mixed-color appearance (dominant category color)
                if let dominant = dominantCategory(in: cluster.memberAnnotations) {
                    v.markerTintColor = dominant.color
                    v.glyphImage = glyph(for: dominant)
                } else {
                    v.markerTintColor = UIColor.systemGray
                    v.glyphImage = UIImage(systemName: "mappin")
                }

                // Count badge
                let count = cluster.memberAnnotations.count
                v.glyphText = count <= 99 ? "\(count)" : "99+"
                v.accessibilityLabel = String(format: NSLocalizedString("%d spots", comment: "cluster a11y"), count)
                v.clusteringIdentifier = nil
                return v
            }

            // Individual spot
            guard let anno = annotation as? SpotAnno else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: markerID, for: anno) as! MKMarkerAnnotationView
            v.clusteringIdentifier = "spot" // enables clustering
            v.displayPriority = .defaultHigh
            v.titleVisibility = .adaptive
            v.subtitleVisibility = .adaptive
            v.canShowCallout = true

            styleMarker(v, for: anno.pin)
            v.accessibilityLabel = "\(anno.pin.name). \(anno.pin.category.title)"
            v.accessibilityHint = NSLocalizedString("Double tap for details.", comment: "spot hint")

            // Callout accessory
            let btn = UIButton(type: .detailDisclosure)
            btn.accessibilityLabel = NSLocalizedString("Open details", comment: "open details")
            v.rightCalloutAccessoryView = btn
            return v
        }

        public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                            calloutAccessoryControlTapped control: UIControl) {
            guard let spot = (view.annotation as? SpotAnno)?.pin else { return }
            onSelect?(spot)
        }

        // Render overlays if you choose to add category corridors later
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            MKOverlayRenderer(overlay: overlay)
        }

        // Helpers

        private func styleMarker(_ v: MKMarkerAnnotationView, for pin: SpotPin) {
            v.markerTintColor = pin.category.color
            v.glyphImage = glyph(for: pin.category)
            v.glyphTintColor = UIColor.white
            v.animatesWhenAdded = false
            v.zPriority = .max
            if pin.isVerified {
                v.accentPriority = .defaultHigh
                v.selectedGlyphTintColor = UIColor.white
                v.selectedMarkerTintColor = pin.category.color
                v.leftCalloutAccessoryView = UIImageView(image:
                    UIImage(systemName: "checkmark.seal.fill")?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal))
            } else {
                v.leftCalloutAccessoryView = nil
            }
        }

        private func dominantCategory(in members: [MKAnnotation]) -> SpotCategory? {
            var freq: [SpotCategory: Int] = [:]
            for m in members {
                if let s = (m as? SpotAnno)?.pin.category { freq[s, default: 0] += 1 }
            }
            return freq.max(by: { $0.value < $1.value })?.key
        }
    }
}

// MARK: - Small helpers

fileprivate extension CLLocationCoordinate2D {
    func equal(to other: CLLocationCoordinate2D, epsilon: CLLocationDegrees = 0.000001) -> Bool {
        abs(latitude - other.latitude) < epsilon && abs(longitude - other.longitude) < epsilon
    }
}

// MARK: - Convenience builder for SwiftUI Map screen

public extension SpotMapOverlayRenderer {
    static func make(pins: [SpotPin],
                     filter: Set<SpotCategory>? = nil,
                     showsUserLocation: Bool = true,
                     onSelect: OnSelect? = nil) -> SpotMapOverlayRenderer {
        SpotMapOverlayRenderer(pins: pins, selectedCategoryFilter: filter, showsUserLocation: showsUserLocation, onSelect: onSelect)
    }
}

// MARK: - DEBUG Preview

#if DEBUG
struct SpotMapOverlayRenderer_Previews: PreviewProvider {
    static var previews: some View {
        let base = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207) // Vancouver
        let pins: [SpotPin] = (0..<80).map { i in
            let jitterLat = Double.random(in: -0.02...0.02)
            let jitterLon = Double.random(in: -0.02...0.02)
            let coord = CLLocationCoordinate2D(latitude: base.latitude + jitterLat,
                                               longitude: base.longitude + jitterLon)
            return SpotPin(id: "s\(i)",
                           coordinate: coord,
                           name: "Spot \(i)",
                           category: SpotCategory.allCases[i % SpotCategory.allCases.count],
                           isVerified: i % 7 == 0,
                           rating: [3,4,5].randomElement())
        }
        NavigationView {
            ZStack {
                SpotMapContainer(initialRegion: .init(center: base, span: .init(latitudeDelta: 0.15, longitudeDelta: 0.15))) {
                    SpotMapOverlayRenderer.make(pins: pins) { _ in }
                        .ignoresSafeArea()
                }
                .navigationTitle("Spots")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Simple container that hosts MKMapView + overlay renderer (for preview/demo)

public struct SpotMapContainer<Overlay: View>: View {
    public var initialRegion: MKCoordinateRegion
    @ViewBuilder public var overlay: () -> Overlay
    public init(initialRegion: MKCoordinateRegion, @ViewBuilder overlay: @escaping () -> Overlay) {
        self.initialRegion = initialRegion
        self.overlay = overlay
    }
    public var body: some View {
        MapRepresentable(region: initialRegion, overlay: overlay)
    }

    private struct MapRepresentable<Overlay: View>: UIViewRepresentable {
        var region: MKCoordinateRegion
        @ViewBuilder var overlay: () -> Overlay
        func makeUIView(context: Context) -> MKMapView {
            let map = MKMapView(frame: .zero)
            map.setRegion(region, animated: false)
            map.showsCompass = true
            return map
        }
        func updateUIView(_ uiView: MKMapView, context: Context) {}
        func overlayUIView() -> some UIView { UIHostingController(rootView: overlay()).view }
        static func dismantleUIView(_ uiView: MKMapView, coordinator: ()) { }
    }
}

// MARK: - Integration notes
// • Feed SpotMapOverlayRenderer with live pins from Services/Spots/SpotStore via Combine/AsyncStream.
// • For large datasets, load by visible map rect + geo-queries in SpotStore; pass only current window’s pins.
// • Cluster tuning: rely on MK clusteringIdentifier "spot". To customize cluster icon further, switch to MKAnnotationView subclass.
// • Selection: `onSelect` hands SpotPin to coordinator → AppCoordinator pushes SpotDetailView.
// • A11y: marker’s `accessibilityLabel` includes name + category; cluster view reads “N spots”.
// • Performance: diff annotations by id; avoid full `removeAnnotations(map.annotations)` churn; disable re-clustering for cluster views.
// • Colors/icons: centralize in Resources/SpotCategories.json; keep this enum as adapter to prevent view from parsing JSON.

// MARK: - Test plan (UI/unit)
// • Cluster density: drop 1k synthetic pins → map stays responsive (scroll/zoom under 16ms on A14+).
// • Category filter: set filter = [.park,.plaza] → only those render; toggling diff removes/insert correctly.
// • Selection: tapping marker → onSelect fires with correct id; callout accessory routes to detail.
// • Movement: updating a pin’s coordinate updates the MKAnnotation (no flicker).
// • Accessibility: VO on a cluster reads “N spots”; on a marker reads “Name. Category.” Buttons have ≥44pt targets.
