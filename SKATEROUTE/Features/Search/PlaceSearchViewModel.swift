// Features/Search/PlaceSearchViewModel.swift
import Foundation
import MapKit
import CoreLocation
import UIKit
import SwiftUI

@MainActor
/// ViewModel responsible for managing location search suggestions using MKLocalSearchCompleter.
/// It provides live updates of search suggestions based on the user's query and allows performing
/// detailed searches for selected suggestions. It also manages the search region and handles errors gracefully.
public final class PlaceSearchViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    /// The current search query entered by the user. Updates the search completer's query fragment.
    @Published public var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    /// The list of search suggestions returned by the search completer.
    @Published public var suggestions: [MKLocalSearchCompletion] = []
    /// The geographic region to constrain search results.
    @Published public var region: MKCoordinateRegion?
    /// Indicates whether a search operation is currently in progress.
    @Published public var isSearching: Bool = false

    private let completer: MKLocalSearchCompleter

    /// Initializes the view model with an optional search region.
    /// - Parameter region: The geographic region to constrain search results.
    public init(region: MKCoordinateRegion?) {
        self.region = region
        self.completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let region = region {
            completer.region = region
        }
    }

    /// Called when the search completer updates its results.
    /// Updates the published suggestions property.
    /// - Parameter completer: The MKLocalSearchCompleter instance providing updated results.
    public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    /// Called when the search completer encounters an error.
    /// Logs the error and clears suggestions.
    /// - Parameters:
    ///   - completer: The MKLocalSearchCompleter instance reporting the error.
    ///   - error: The error encountered.
    public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Completer error: \(error)")
        suggestions = []
    }

    /// Performs a detailed search for the given search suggestion.
    /// Toggles the `isSearching` state with animation and provides haptic feedback on success or failure.
    /// - Parameter suggestion: The MKLocalSearchCompletion to search for.
    /// - Returns: An array of MKMapItem results matching the suggestion.
    public func search(for suggestion: MKLocalSearchCompletion) async -> [MKMapItem] {
        await MainActor.run {
            withAnimation {
                isSearching = true
            }
        }
        let request = MKLocalSearch.Request(completion: suggestion)
        if let region = region { request.region = region }
        do {
            let response = try await MKLocalSearch(request: request).start()
            await MainActor.run {
                withAnimation {
                    isSearching = false
                }
            }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            return response.mapItems
        } catch {
            await MainActor.run {
                withAnimation {
                    isSearching = false
                }
            }
            print("Search failed. Please try again later.")
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            return []
        }
    }
}
