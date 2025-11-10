// Features/Search/PlaceSearchView.swift
// SwiftUI search sheet for places (MapKit-first).
// - Debounced, cancel-safe search via PlaceSearchViewModel
// - Optional "Use My Location" affordance
// - Returns MKMapItem via onPick
// - Accessible, Dynamic Type–safe, and lightweight

import SwiftUI
import MapKit
import CoreLocation

public struct PlaceSearchView: View {
    // MARK: - Inputs
    private let title: String
    private let region: MKCoordinateRegion?
    private let showUseCurrentLocation: Bool
    private let currentLocationProviderSync: (() -> CLLocationCoordinate2D?)?
    private let onPick: (MKMapItem) -> Void
    private let onUseCurrentLocationDenied: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Local UI state
    @State private var query: String = ""
    @StateObject private var vm: PlaceSearchViewModel

    // MARK: - Inits

    /// Primary initializer (matches your HomeView usage).
    public init(
        title: String,
        region: MKCoordinateRegion?,
        showUseCurrentLocation: Bool,
        currentLocationProvider: (() -> CLLocationCoordinate2D?)? = nil,
        onPick: @escaping (MKMapItem) -> Void,
        onUseCurrentLocationDenied: (() -> Void)? = nil
    ) {
        self.title = title
        self.region = region
        self.showUseCurrentLocation = showUseCurrentLocation
        self.currentLocationProviderSync = currentLocationProvider
        self.onPick = onPick
        self.onUseCurrentLocationDenied = onUseCurrentLocationDenied

        // Wrap the sync provider in an async CurrentLocationProvider expected by the VM.
        let asyncProvider: CurrentLocationProvider? = {
            guard let sync = currentLocationProvider else { return nil }
            return {
                if let coord = sync() { return coord }
                throw CurrentLocationError.denied
            }
        }()

        _vm = StateObject(wrappedValue: PlaceSearchViewModel(
            geocoder: GeocoderService(),
            presetRegion: region,
            currentLocationProvider: asyncProvider,
            allowUseCurrentLocation: showUseCurrentLocation
        ))
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            vm.cancel()
                            dismiss()
                        }
                        .accessibilityLabel("Cancel search")
                    }
                }
        }
        .onDisappear { vm.cancel() }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, isSearching: vm.isSearching, onSubmit: {
                vm.searchNow()
            })
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .onChange(of: query) { _, newValue in
                vm.query = newValue
            }
            .onAppear {
                // Prime the binding so the VM reflects initial empty state
                vm.query = query
            }

            if let err = vm.errorMessage, !err.isEmpty {
                ErrorBanner(text: err)
            }

            List {
                if vm.canUseCurrentLocation, showUseCurrentLocation {
                    Button {
                        Task {
                            await vm.useCurrentLocation()
                            if let picked = vm.selected {
                                onPick(picked.item)
                                dismiss()
                            } else if vm.errorMessage != nil {
                                // Local hook for denied/unavailable
                                onUseCurrentLocationDenied?()
                            }
                        }
                    } label: {
                        Label("Use My Location", systemImage: "location.fill")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityHint("Select your current location")
                }

                if vm.isSearching && vm.suggestions.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Searching")
                }

                ForEach(vm.suggestions) { suggestion in
                    Button {
                        vm.select(suggestion)
                        onPick(suggestion.item)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.body)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityHint("Use this place")
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Subviews

private struct SearchField: View {
    @Binding var text: String
    var isSearching: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $text)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit { onSubmit() }

            if isSearching {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading")
            } else if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                        .accessibilityLabel("Clear search")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityLabel(text)
    }
}

// MARK: - Previews

#if DEBUG
struct PlaceSearchView_Previews: PreviewProvider {
    static var previews: some View {
        PlaceSearchView(
            title: "Find a Spot",
            region: nil,
            showUseCurrentLocation: true,
            currentLocationProvider: { CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207) },
            onPick: { _ in },
            onUseCurrentLocationDenied: {}
        )
    }
}
#endif
