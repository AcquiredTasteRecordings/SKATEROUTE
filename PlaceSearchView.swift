// Features/Search/PlaceSearchView.swift
import SwiftUI
import MapKit
import CoreLocation

/// A view that allows users to search for places or addresses and pick a location.
/// Supports using the current device location as well.
public struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlaceSearchViewModel
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    /// The title displayed in the navigation bar.
    public let title: String
    /// Closure called when a place is picked, providing the selected MKMapItem.
    public let onPick: (MKMapItem) -> Void
    /// Flag indicating whether to show the "Use Current Location" button.
    public let showUseCurrentLocation: Bool
    /// Closure providing the current device location coordinate, if available.
    public let currentLocationProvider: () -> CLLocationCoordinate2D?

    /// Initializes the PlaceSearchView.
    /// - Parameters:
    ///   - title: The navigation bar title.
    ///   - region: Optional region to constrain search results.
    ///   - showUseCurrentLocation: Whether to show the "Use Current Location" option.
    ///   - currentLocationProvider: Closure to provide current location coordinate.
    ///   - onPick: Closure called with the selected MKMapItem.
    public init(title: String,
                region: MKCoordinateRegion?,
                showUseCurrentLocation: Bool = true,
                currentLocationProvider: @escaping () -> CLLocationCoordinate2D?,
                onPick: @escaping (MKMapItem) -> Void) {
        _vm = StateObject(wrappedValue: PlaceSearchViewModel(region: region))
        self.title = title
        self.onPick = onPick
        self.showUseCurrentLocation = showUseCurrentLocation
        self.currentLocationProvider = currentLocationProvider
    }

    public var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .accessibilityHidden(true)
                    TextField("Search address or place", text: $vm.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                        .accessibilityLabel("Search address or place")
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding([.horizontal, .top])

                if showUseCurrentLocation {
                    Button {
                        if let c = currentLocationProvider() {
                            feedbackGenerator.impactOccurred()
                            let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
                            onPick(item)
                            dismiss()
                        }
                    } label: {
                        Label("Use Current Location", systemImage: "location.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityLabel("Use Current Location")
                }

                if vm.isSearching {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.top, 8)
                        .accessibilityLabel("Searching")
                }

                List {
                    ForEach(vm.suggestions, id: \.self) { s in
                        Button {
                            Task {
                                feedbackGenerator.impactOccurred()
                                let items = await vm.search(for: s)
                                if let first = items.first {
                                    onPick(first)
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                    .font(.body)
                                    .foregroundColor(Color.primary)
                                Text(s.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("\(s.title), \(s.subtitle)")
                    }
                    .animation(.default, value: vm.suggestions)
                }
                .listStyle(.plain)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityLabel("Cancel")
                }
            }
        }
    }
}
