// Features/Community/Views/QuickReportView.swift
import SwiftUI
import CoreLocation
import SwiftData

/// Quick one-tap reporter for surface quality at a given coordinate.
/// De-duplicates reports in a small tile around the tap to avoid local spam.
public struct QuickReportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinate: CLLocationCoordinate2D
    public var onSaved: (() -> Void)? = nil

    @State private var showConfirmation = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    public init(coordinate: CLLocationCoordinate2D, onSaved: (() -> Void)? = nil) {
        self.coordinate = coordinate
        self.onSaved = onSaved
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ratingButton(value: .butter, emoji: "🧈", label: "Butter")
                ratingButton(value: .okay,   emoji: "🙂", label: "Okay")
                ratingButton(value: .crusty, emoji: "🪨", label: "Crusty")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
            )

            if showConfirmation {
                Text("Saved")
                    .font(.headline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .zIndex(1)
                    .accessibilityLabel("Saved")
            }

            if let msg = errorMessage {
                VStack {
                    Text(msg)
                        .font(.footnote)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .transition(.opacity)
                .zIndex(2)
                .accessibilityLabel(msg)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.0 : 0.35), value: showConfirmation)
        .animation(.easeInOut(duration: 0.25), value: errorMessage)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Report surface quality")
    }

    // MARK: - Button Factory

    private func ratingButton(value: SurfaceValue, emoji: String, label: String) -> some View {
        Button {
            Task { await save(value: value) }
        } label: {
            VStack(spacing: 4) {
                Text(emoji).font(.title2)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 68) // larger hit target
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel("\(label) surface")
        .accessibilityHint("Submit a \(label.lowercased()) rating here")
        .contentShape(Rectangle())
    }

    // MARK: - Save Logic (SwiftData + local de-dupe)

    /// Saves or updates a SurfaceRating near the given coordinate using a small quantized bin.
    @MainActor
    private func save(value: SurfaceValue) {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        do {
            let viewModel = QuickReportViewModel(modelContext: modelContext)
            try viewModel.upsertRating(at: coordinate, value: value)

            // UX: haptics + confirmation + optional callback
            HapticCue.play(.success)
            withAnimation { showConfirmation = true }
            UIAccessibility.post(notification: .announcement, argument: "Surface saved: \(value.description)")

            onSaved?()

            // Auto-hide confirmation and optionally close lightweight sheets
            let delay = reduceMotion ? 0.8 : 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation { showConfirmation = false }
            }
        } catch {
            HapticCue.play(.error)
            errorMessage = "Couldn’t save. Try again."
            // Hide after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { errorMessage = nil } }
        }

        isSaving = false
    }

    // MARK: - Helpers

}

// MARK: - Preview

#if DEBUG
import MapKit
import UIKit
struct QuickReportView_Previews: PreviewProvider {
    static var previews: some View {
        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        QuickReportView(coordinate: coord)
            .padding()
            .background(Color.black.opacity(0.9))
            .previewLayout(.sizeThatFits)
    }
}
#endif


