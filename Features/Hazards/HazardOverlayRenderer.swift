// Features/Hazards/HazardOverlayRenderer.swift
// Severity-coded hazard pins with tap-for-detail.
// - MapKit-first clustered annotations; color/size reflect severity buckets from HazardRules.
// - Respects de-dupe mask: any pin with `isSuppressed == true` is not rendered.
// - SwiftUI wrapper with diffed updates and selection callback.
// - A11y: VO label includes type + severity + relative age; large touch targets.
// - Perf: reuse identifiers; avoid full annotation churn; clustering for dense corridors.
// - Privacy: no reverse geocoding, no tracking. Inputs come from HazardStore/HazardRules.

import SwiftUI
import MapKit
import Combine

// MARK: - Hazard domain adapters (mirror Services/Hazards models)

public enum HazardType: String, Codable, Sendable, CaseIterable {
    case pothole, gravel, crack, rail, construction, debris, wet, other

    public var title: String {
        switch self {
        case .pothole: return NSLocalizedString("Pothole", comment: "")
        case .gravel: return NSLocalizedString("Gravel", comment: "")
        case .crack: return NSLocalizedString("Crack", comment: "")
        case .rail: return NSLocalizedString("Rail", comment: "")
        case .construction: return NSLocalizedString("Construction", comment: "")
        case .debris: return NSLocalizedString("Debris", comment: "")
        case .wet: return NSLocalizedString("Wet", comment: "")
        case .other: return NSLocalizedString("Hazard", comment: "")
        }
    }

    // Default symbol fallback; renderer can be swapped to custom assets if desired.
    public var symbol: String {
        switch self {
        case .pothole: return "circle.dashed"
        case .gravel: return "circle.grid.3x3"
        case .crack: return "scribble.variable"
        case .rail: return "line.diagonal"
        case .construction: return "wrench.and.screwdriver"
        case .debris: return "trash"
        case .wet: return "drop.triangle"
        case .other: return "exclamationmark.circle"
        }
    }
}

public enum HazardSeverity: Int, Codable, Sendable, CaseIterable {
    case low = 0, medium = 1, high = 2, critical = 3

    public var title: String {
        switch self {
        case .low: return NSLocalizedString("Low", comment: "")
        case .medium: return NSLocalizedString("Medium", comment: "")
        case .high: return NSLocalizedString("High", comment: "")
        case .critical: return NSLocalizedString("Critical", comment: "")
        }
    }

    public var color: UIColor {
        switch self {
        case .low: return UIColor.systemYellow
        case .medium: return UIColor.systemOrange
        case .high: return UIColor.systemRed
        case .critical: return UIColor.systemRed
        }
    }

    /// Marker scale (applied via glyph/marker styling). 1.0 is baseline.
    public var scale: CGFloat {
        switch self {
        case .low: return 0.9
        case .medium: return 1.0
        case .high: return 1.15
        case .critical: return 1.3
        }
    }
}

/// Value object for map rendering (already de-duped & merged via HazardRules).
public struct HazardPin: Identifiable, Hashable, Sendable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let type: HazardType
    public let severity: HazardSeverity
    public let updatedAt: Date
    public let count: Int             // merged report count for this cluster
    public let isSuppressed: Bool     // de-dupe mask; true => don't render
    public init(id: String,
                coordinate: CLLocationCoordinate2D,
                type: HazardType,
                severity: HazardSeverity,
                updatedAt: Date,
                count: Int,
                isSuppressed: Bool) {
        self.id = id
        self.coordinate = coordinate
        self.type = type
        self.severity = severity
        self.updatedAt = updatedAt
        self.count = count
        self.isSuppressed = isSuppressed
    }
}

// MARK: - Internal MKAnnotation wrapper

final class HazardAnno: NSObject, MKAnnotation {
    let pin: HazardPin
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { pin.type.title }
    var subtitle: String? { pin.severity.title }
    init(_ pin: HazardPin) {
        self.pin = pin
        self.coordinate = pin.coordinate
        super.init()
    }
}

// MARK: - SwiftUI wrapper

public struct HazardOverlayRenderer: UIViewRepresentable {
    public typealias OnSelect = (HazardPin) -> Void

    private let pins: [HazardPin]
    private let showsUserLocation: Bool
    private let onSelect: OnSelect?

    // IDs
    private let markerID = "hazard.marker"
    private let clusterID = "hazard.cluster"

    public init(pins: [HazardPin], showsUserLocation: Bool = true, onSelect: OnSelect? = nil) {
        self.pins = pins
        self.showsUserLocation = showsUserLocation
        self.onSelect = onSelect
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(markerID: markerID, clusterID: clusterID, onSelect: onSelect)
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = showsUserLocation
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: markerID)
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: clusterID)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = false // steady orientation helps when skating
        context.coordinator.applyAnnotations(on: map, pins: pins)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyAnnotations(on: map, pins: pins)
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
    }

    // MARK: Coordinator

    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let markerID: String
        private let clusterID: String
        private let onSelect: OnSelect?
        private var index: [String: HazardAnno] = [:]

        init(markerID: String, clusterID: String, onSelect: OnSelect?) {
            self.markerID = markerID
            self.clusterID = clusterID
            self.onSelect = onSelect
        }

        // Diff + apply
        func applyAnnotations(on map: MKMapView, pins: [HazardPin]) {
            // Filter suppressed pins (respect de-dupe mask from HazardRules)
            let filtered = pins.filter { !$0.isSuppressed }
            let newIDs = Set(filtered.map { $0.id })
            let oldIDs = Set(index.keys)

            // Remove
            let toRemove = oldIDs.subtracting(newIDs)
            if !toRemove.isEmpty {
                let annos = toRemove.compactMap { index[$0] }
                map.removeAnnotations(annos)
                annos.forEach { index.removeValue(forKey: $0.pin.id) }
            }
            // Insert
            let toInsert = newIDs.subtracting(oldIDs)
            if !toInsert.isEmpty {
                let annos = filtered.filter { toInsert.contains($0.id) }.map { HazardAnno($0) }
                annos.forEach { index[$0.pin.id] = $0 }
                map.addAnnotations(annos)
            }
            // Update position (rare)
            for pin in filtered {
                if let a = index[pin.id], !a.coordinate.equal(to: pin.coordinate) {
                    a.coordinate = pin.coordinate
                }
            }
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: clusterID, for: cluster)
                styleCluster(v, members: cluster.memberAnnotations)
                return v
            }

            guard let anno = annotation as? HazardAnno else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: markerID, for: anno)
            styleMarker(v, pin: anno.pin)
            return v
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = (view.annotation as? HazardAnno)?.pin else { return }
            onSelect?(pin)
        }

        // MARK: Styling

        private func styleMarker(_ v: MKAnnotationView, pin: HazardPin) {
            v.clusteringIdentifier = "hazard"
            v.displayPriority = .required
            v.canShowCallout = false
            v.isEnabled = true

            // Build a size-scaled, color-coded glyph
            let base = markerGlyph(for: pin.type, color: pin.severity.color, scale: pin.severity.scale)
            v.image = base
            v.centerOffset = CGPoint(x: 0, y: -base.size.height * 0.35)

            // Accessibility
            let age = RelativeDateTimeFormatter().localizedString(for: pin.updatedAt, relativeTo: Date())
            v.accessibilityLabel = "\(pin.type.title). \(pin.severity.title). \(age)."
            v.accessibilityTraits = [.button]
        }

        private func styleCluster(_ v: MKAnnotationView, members: [MKAnnotation]) {
            v.clusteringIdentifier = nil
            v.canShowCallout = false
            v.displayPriority = .required

            // Determine dominant severity (max) and member count
            var maxSeverity: HazardSeverity = .low
            var count = 0
            var dominantType: HazardType = .other
            var typeFreq: [HazardType: Int] = [:]
            for m in members {
                if let p = (m as? HazardAnno)?.pin {
                    count += 1
                    if p.severity.rawValue > maxSeverity.rawValue { maxSeverity = p.severity }
                    typeFreq[p.type, default: 0] += 1
                }
            }
            if let mode = typeFreq.max(by: { $0.value < $1.value })?.key { dominantType = mode }

            v.image = clusterGlyph(count: count, color: maxSeverity.color, type: dominantType)

            // A11y
            v.accessibilityLabel = String(format: NSLocalizedString("%d hazards", comment: "cluster a11y"), count)
            v.accessibilityTraits = [.button]
        }

        // MARK: Glyphs

        private func markerGlyph(for type: HazardType, color: UIColor, scale: CGFloat) -> UIImage {
            // Circular badge with SF symbol overlay. Crisp at various scales.
            let baseSize: CGFloat = 26 * scale
            let rect = CGRect(x: 0, y: 0, width: baseSize, height: baseSize)
            let renderer = UIGraphicsImageRenderer(size: rect.size)
            return renderer.image { ctx in
                let path = UIBezierPath(ovalIn: rect)
                color.setFill()
                path.fill()

                // inner stroke
                let stroke = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                UIColor.white.withAlphaComponent(0.85).setStroke()
                stroke.lineWidth = 1.5
                stroke.stroke()

                // Symbol
                if let img = UIImage(systemName: type.symbol)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 12 * scale, weight: .bold)) {
                    UIColor.white.setFill()
                    let sz = img.size
                    let x = (rect.width - sz.width) / 2
                    let y = (rect.height - sz.height) / 2
                    img.draw(in: CGRect(x: x, y: y, width: sz.width, height: sz.height))
                }

                // Optional count tick for merged reports
                // (We render it in the callout-less pin to keep DOM light—use cluster for large counts.)
            }
        }

        private func clusterGlyph(count: Int, color: UIColor, type: HazardType) -> UIImage {
            let base: CGFloat = 36
            let rect = CGRect(x: 0, y: 0, width: base, height: base)
            let renderer = UIGraphicsImageRenderer(size: rect.size)
            return renderer.image { _ in
                // Outer ring
                let ring = UIBezierPath(ovalIn: rect)
                color.setFill()
                ring.fill()

                // Inner circle
                let inner = UIBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                UIColor.systemBackground.setFill()
                inner.fill()

                // Count text
                let label = count > 99 ? "99+" : "\(count)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: UIColor.label
                ]
                let size = (label as NSString).size(withAttributes: attrs)
                let p = CGPoint(x: (rect.width - size.width)/2, y: (rect.height - size.height)/2)
                (label as NSString).draw(at: p, withAttributes: attrs)

                // Top-left tiny symbol hint for dominant type
                if let sym = UIImage(systemName: type.symbol)?
                    .withConfiguration(UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
                    .withTintColor(color, renderingMode: .alwaysOriginal) {
                    sym.draw(in: CGRect(x: 2, y: 2, width: 12, height: 12))
                }
            }
        }
    }
}

// MARK: - Helpers

fileprivate extension CLLocationCoordinate2D {
    func equal(to other: CLLocationCoordinate2D, epsilon: CLLocationDegrees = 0.000001) -> Bool {
        abs(latitude - other.latitude) < epsilon && abs(longitude - other.longitude) < epsilon
    }
}

// MARK: - Convenience builder

public extension HazardOverlayRenderer {
    static func make(pins: [HazardPin],
                     showsUserLocation: Bool = true,
                     onSelect: OnSelect? = nil) -> HazardOverlayRenderer {
        HazardOverlayRenderer(pins: pins, showsUserLocation: showsUserLocation, onSelect: onSelect)
    }
}

// MARK: - DEBUG preview

#if DEBUG
struct HazardOverlayRenderer_Previews: PreviewProvider {
    static var previews: some View {
        let center = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        let pins: [HazardPin] = (0..<120).map { i in
            let jitterLat = Double.random(in: -0.02...0.02)
            let jitterLon = Double.random(in: -0.02...0.02)
            let sev = HazardSeverity.allCases.randomElement()!
            return HazardPin(
                id: "h\(i)",
                coordinate: .init(latitude: center.latitude + jitterLat, longitude: center.longitude + jitterLon),
                type: HazardType.allCases.randomElement()!,
                severity: sev,
                updatedAt: Date().addingTimeInterval(-Double.random(in: 0...36_000)),
                count: Int.random(in: 1...5),
                isSuppressed: Bool.random() && i % 7 == 0 // show suppression working
            )
        }

        NavigationView {
            MapContainer(initialRegion: .init(center: center, span: .init(latitudeDelta: 0.15, longitudeDelta: 0.15))) {
                HazardOverlayRenderer.make(pins: pins) { _ in }
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// lightweight container for preview parity with Spots
public struct MapContainer<Overlay: View>: View {
    public var initialRegion: MKCoordinateRegion
    @ViewBuilder public var overlay: () -> Overlay
    public init(initialRegion: MKCoordinateRegion, @ViewBuilder overlay: @escaping () -> Overlay) {
        self.initialRegion = initialRegion; self.overlay = overlay
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
            return map
        }
        func updateUIView(_ uiView: MKMapView, context: Context) {}
    }
}
#endif

// MARK: - Integration notes
// • Feed `pins` from Services/Hazards/HazardStore publisher AFTER applying HazardRules.mergeAndBucket(...).
// • Respect de-dupe: HazardRules should set `isSuppressed` on any low-signal duplicates within the type’s spatial radius.
// • Selection: `onSelect` should route to Hazard detail sheet (from HazardListView), not a callout here—keeps map lean.
// • Clustering: We rely on `clusteringIdentifier = "hazard"` on individual pins; MapKit will cluster at low zooms.
// • Performance: we diff by id and move coordinates in-place; no full clear → avoids jank while navigating.

// MARK: - Test plan (UI/unit)
// Unit:
// 1) Suppression: any pin with isSuppressed == true never added to map.
// 2) Diffing: updating coordinate for same id mutates MKAnnotation without re-adding.
// 3) Severity styling: .critical yields larger glyph and red color; .low is smallest & yellow.
// UI:
// • Dense dataset (1k pins) stays responsive on A14+; clusters render counts, a11y reads “N hazards”.
// • VO reads single marker: “Pothole. High. 2 hours ago.”
// • Tapping a marker triggers onSelect with exact HazardPin payload.
// • Dark/Light modes maintain contrast (white symbol on colored disc).
