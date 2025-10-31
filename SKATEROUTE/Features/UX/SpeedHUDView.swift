// Features/UX/SpeedHUDView.swift
import SwiftUI
import Combine

/// A view that displays the current speed in kilometers per hour with color-coded states and animations.
///
/// Use `SpeedHUDView` to provide a clear and accessible visual representation of speed. The speed is color-coded:
/// - Green for cruising speeds below 10 km/h.
/// - Yellow for moderate speeds between 10 and 25 km/h.
/// - Red for fast speeds above 25 km/h, with a pulsing animation to indicate high velocity.
///
/// The view adapts its colors for both light and dark modes to ensure clear contrast. It also provides accessibility
/// labels and triggers haptic feedback when transitioning between speed states.
public struct SpeedHUDView: View {
    @Binding public var speed: Double
    
    @State private var isPulsing = false
    @State private var previousSpeedState: SpeedState = .cruising
    
    private enum SpeedState {
        case cruising, moderate, fast
    }
    
    public init(speed: Binding<Double>) {
        self._speed = speed
    }
    
    private var speedState: SpeedState {
        if speed > 25 {
            return .fast
        } else if speed >= 10 {
            return .moderate
        } else {
            return .cruising
        }
    }
    
    private var speedColor: Color {
        switch speedState {
        case .cruising:
            return Color.green
        case .moderate:
            return Color.yellow
        case .fast:
            return Color.red
        }
    }
    
    private func provideHapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        switch speedState {
        case .cruising:
            generator.notificationOccurred(.success)
        case .moderate:
            generator.notificationOccurred(.warning)
        case .fast:
            generator.notificationOccurred(.error)
        }
    }
    
    public var body: some View {
        Text(String(format: "%.1f km/h", speed))
            .font(.system(size: 48, weight: .bold))
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(speedColor, lineWidth: 3)
                    )
            )
            .foregroundColor(speedColor)
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .animation(speedState == .fast ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
            .accessibilityLabel("Current speed \(Int(speed)) kilometers per hour")
            .accessibilityAddTraits(.isStaticText)
            .onChange(of: speedState) { newState in
                if newState != previousSpeedState {
                    provideHapticFeedback()
                    previousSpeedState = newState
                }
                isPulsing = (newState == .fast)
            }
            .onAppear {
                isPulsing = (speedState == .fast)
                previousSpeedState = speedState
            }
    }
}
