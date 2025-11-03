// Features/Community/Views/QuickReportView.swift
import SwiftUI
import CoreLocation
import SwiftData

/// A view that allows users to quickly report a surface rating at a specific coordinate.
/// Displays three rating buttons representing different surface conditions.
public struct QuickReportView: View {
    @Environment(\.modelContext) private var modelContext
    public let coordinate: CLLocationCoordinate2D
    
    @State private var showConfirmation = false

    /// Initializes the view with a coordinate where the surface rating will be reported.
    /// - Parameter coordinate: The geographical coordinate for the surface rating.
    public init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Button { save(value: 2) } label: { makeLabel("🧈", "Butter") }
                Button { save(value: 1) } label: { makeLabel("🙂", "Okay") }
                Button { save(value: 0) } label: { makeLabel("🪨", "Crusty") }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            
            if showConfirmation {
                Text("✓ Saved!")
                    .font(.headline)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: showConfirmation)
    }

    /// Creates a label view with an emoji and descriptive text.
    /// - Parameters:
    ///   - emoji: The emoji string to display.
    ///   - text: The descriptive text below the emoji.
    /// - Returns: A vertically stacked view with the emoji and text.
    private func makeLabel(_ emoji: String, _ text: String) -> some View {
        VStack {
            Text(emoji).font(.title2)
            Text(text).font(.caption2)
        }
        .padding(.vertical, 4)
    }

    /// Saves a surface rating with the given value at the current coordinate.
    /// Triggers haptic feedback and shows a temporary confirmation overlay.
    /// - Parameter value: The integer value representing the surface rating.
    private func save(value: Int) {
        let r = SurfaceRating(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            value: value
        )
        modelContext.insert(r)
        try? modelContext.save()
        
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        showConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showConfirmation = false
            }
        }
    }
}
