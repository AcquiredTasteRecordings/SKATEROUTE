// Features/Map/MapScreen.swift
// End-to-end route planning + map render with colored step paints,
// plus lightweight reroute monitoring hooks.

import SwiftUI
import MapKit
import CoreLocation
import Combine
import UIKit

// MARK: - MapScreen

public struct MapScreen: View {
    private let source: CLLocationCoordinate2D
    private let destination: CLLocationCoordinate2D

    @StateObject private var vm: RoutePlannerViewModel
    @StateObject private var rerouteControllerBox: RerouteControllerBox

    @State private var showOptions = false
    @State private var mapInsets = EdgeInsets(top: 0, leading: 0, bottom: 160, trailing: 0)

    public init(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) {
        self.source = source
        self.destination = destination
        // DI wiring at init time keeps this view self-contained.
        let di = AppDI.shared
        _vm = StateObject(wrappedValue: di.makeRoutePlannerViewModel())
        _rerouteControllerBox = StateObject(wrappedValue: RerouteControllerBox(controller: di.makeRerouteController()))
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            InlineMapView(
                selectedRoute: $vm.selectedRoute,
                paints: paintsForSelected(),
                focusOnChange: true
            )
            .ignoresSafeArea(edges: .all)
            .accessibilityIdentifier("MapScreen.MapView")
            .overlay(alignment: .top) {
                if case .loading = vm.state {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                        .accessibilityLabel(Text("Planning route"))
                }
            }

            // Route selector + meta banner
            VStack(spacing: 10) {
                if !vm.orderedCandidateIDs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.orderedCandidateIDs, id: \.self) { id in
                                RouteOptionChip(
                                    isSelected: id == vm.selectedCandidateID,
                                    presentation: vm.presentations[id]
                                )
                                .onTapGesture { vm.selectCandidate(id: id) }
                                .accessibilityHint("Select this route")
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                if let text = vm.bannerText {
                    Text(text)
                        .lineLimit(2)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 12)
                        .accessibilityLabel(Text("Route summary"))
                }

                HStack {
                    Button {
                        showOptions.toggle()
                    } label: {
                        Label("Options", systemImage: "slider.horizontal.3")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("MapScreen.OptionsButton")

                    Spacer()

                    // Offline tile status
                    OfflineStatusPill(state: vm.offlineState)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 8)
        }
        .task {
            // Initial plan once the view hits the foreground
            vm.plan(from: source, to: destination, userInitiated: true)
        }
        .onAppear {
            syncRerouteMonitoring(with: vm.selectedRoute)
        }
        .onChange(of: vm.selectedRoute) { _, newRoute in
            syncRerouteMonitoring(with: newRoute)
        }
        .onDisappear {
            stopRerouteMonitoring()
        }
        .sheet(isPresented: $showOptions) {
            PlannerOptionsSheet(
                mode: $vm.mode,
                preferSkateLegal: $vm.preferSkateLegal,
                onApply: {
                    if let src = vm.source, let dst = vm.destination {
                        vm.plan(from: src, to: dst, userInitiated: true)
                    }
                }
            )
            .presentationDetents([.height(240), .medium])
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Minimal home/back affordance; coordinator can override.
                    // Replace with a binding to AppCoordinator if needed.
                } label: {
                    Image(systemName: "chevron.backward")
                }.accessibilityLabel("Back")
            }
        }
    }

    // Build step paints for the currently selected candidate.
    private func paintsForSelected() -> [StepPaint] {
        guard let id = vm.selectedCandidateID,
              let pres = vm.presentations[id] else { return [] }
        return pres.stepPaints.map { StepPaint(stepIndex: $0.stepIndex, color: $0.color) }
    }

    private func syncRerouteMonitoring(with route: MKRoute?) {
        guard let route else {
            stopRerouteMonitoring()
            return
        }

        if rerouteControllerBox.hasStartedMonitoring {
            rerouteControllerBox.controller.updateRoute(route)
        } else {
            rerouteControllerBox.controller.startMonitoring(route: route) { offCoord in
                vm.plan(from: offCoord, to: destination, userInitiated: false)
            }
            rerouteControllerBox.hasStartedMonitoring = true
        }

        rerouteControllerBox.controller.markRouteStabilized()
    }

    private func stopRerouteMonitoring() {
        guard rerouteControllerBox.hasStartedMonitoring else { return }
        rerouteControllerBox.controller.stopMonitoring()
        rerouteControllerBox.hasStartedMonitoring = false
    }
}

// MARK: - Reroute Controller Wrapper

@MainActor
private final class RerouteControllerBox: ObservableObject {
    let controller: RerouteControlling
    @Published var hasStartedMonitoring = false

    init(controller: RerouteControlling) {
        self.controller = controller
    }
}

// MARK: - Inline Map (MKMapView wrapper)

fileprivate struct InlineMapView: UIViewRepresentable {
    @Binding var selectedRoute: MKRoute?
    var paints: [StepPaint]
    var focusOnChange: Bool

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView(frame: .zero)
        mv.isRotateEnabled = true
        mv.isPitchEnabled = true
        mv.showsCompass = false
        mv.showsUserLocation = true
        mv.pointOfInterestFilter = .includingAll
        mv.delegate = context.coordinator
        mv.accessibilityIdentifier = "InlineMapView.MKMapView"
        return mv
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.apply(route: selectedRoute, paints: paints, on: map, focus: focusOnChange)
    }

    // Coordinator owns overlay lifecycles and rendering.
    final class Coord: NSObject, MKMapViewDelegate {
        private var currentRouteId: ObjectIdentifier?
        private var overlays: [MKOverlay] = []

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let cp = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: cp)
                r.strokeColor = cp.uiColor.withAlphaComponent(0.9)
                r.lineWidth = 6
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            if let pl = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: pl)
                r.strokeColor = UIColor.systemBlue
                r.lineWidth = 5
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func apply(route: MKRoute?, paints: [StepPaint], on map: MKMapView, focus: Bool) {
            // If route object changed identity, rebuild overlays
            let routeId = route.map { ObjectIdentifier($0) }
            guard currentRouteId != routeId || overlays.isEmpty else {
                // Same base route; just refresh paints if needed
                refreshPaints(paints, on: map)
                return
            }

            // Clear previous overlays
            if !overlays.isEmpty {
                map.removeOverlays(overlays)
                overlays.removeAll()
            }

            guard let route else { return }

            // Build colored step overlays
            let stepColors = Dictionary(uniqueKeysWithValues: paints.map { ($0.stepIndex, $0.uiColor) })
            var newOverlays: [MKOverlay] = []

            for (idx, step) in route.steps.enumerated() {
                guard step.polyline.pointCount > 1 else { continue }
                if let color = stepColors[idx] {
                    let cp = ColoredPolyline(points: step.polyline)
                    cp.uiColor = color
                    newOverlays.append(cp)
                } else {
                    newOverlays.append(step.polyline)
                }
            }

            // Add overlays (colored on top)
            map.addOverlays(newOverlays)
            overlays = newOverlays
            currentRouteId = routeId

            if focus {
                let rect = route.polyline.boundingMapRect.insetBy(dx: -200, dy: -200)
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 48, left: 32, bottom: 200, right: 32), animated: true)
            }
        }

        private func refreshPaints(_ paints: [StepPaint], on map: MKMapView) {
            // Reapply colors onto ColoredPolyline instances
            let byIndex = Dictionary(uniqueKeysWithValues: paints.map { ($0.stepIndex, $0.uiColor) })
            for overlay in overlays {
                guard let cp = overlay as? ColoredPolyline, let idx = cp.stepIndex, let color = byIndex[idx] else { continue }
                cp.uiColor = color
                // MKPolylineRenderer pulls color in rendererFor; trigger a refresh:
                map.removeOverlay(cp)
                map.addOverlay(cp)
            }
        }
    }
}

// MARK: - Colored Polyline primitives

fileprivate final class ColoredPolyline: MKPolyline {
    // Stored UI color for renderer; we keep this fileprivate to avoid API surface leak.
    fileprivate var uiColor: UIColor = .systemBlue
    fileprivate var stepIndex: Int?

    convenience init(points: MKPolyline) {
        let mapPoints = points.mapPoints()
        if mapPoints.isEmpty {
            self.init()
        } else {
            mapPoints.withUnsafeBufferPointer { buffer in
                self.init(points: buffer.baseAddress!, count: buffer.count)
            }
        }
    }
}

public struct StepPaint: Hashable {
    public let stepIndex: Int
    public let color: UIColor
    fileprivate var uiColor: UIColor { color }
    public init(stepIndex: Int, color: UIColor) {
        self.stepIndex = stepIndex
        self.color = color
    }
}

// MARK: - Chips & UI Bits

fileprivate struct RouteOptionChip: View {
    let isSelected: Bool
    let presentation: RouteOptionsReducer.Presentation?

    var body: some View {
        let title = presentation?.title ?? "Option"
        let subtitle = presentation?.scoreLabel ?? ""
        let tint = Color(uiColor: presentation?.tintColor ?? .systemBlue)

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout).bold()
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? tint.opacity(0.15) : .thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? tint : Color(.separator), lineWidth: isSelected ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

fileprivate struct OfflineStatusPill: View {
    let state: OfflineTileManager.DownloadState
    var body: some View {
        let label: String
        switch state {
        case .idle:
            label = "Tiles: Idle"
        case .preparing:
            label = "Tiles: Preparing"
        case .downloading(let progress):
            label = "Tiles: Downloading \(Int(progress * 100))%"
        case .cached(let count):
            label = count > 0 ? "Tiles: Ready (\(count))" : "Tiles: Ready"
        case .failed:
            label = "Tiles: Error"
        }
        Text(label)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel(Text(label))
    }
}

fileprivate struct PlannerOptionsSheet: View {
    @Binding var mode: RideMode
    @Binding var preferSkateLegal: Bool
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Routing") {
                    Toggle("Prefer skate-legal paths", isOn: $preferSkateLegal)
                        .accessibilityLabel("Prefer skate-legal paths")
                }
                // Extend here with RideMode cases when defined.
            }
            .navigationTitle("Route Options")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply() }
                        .accessibilityLabel("Apply options")
                }
            }
        }
    }
}


