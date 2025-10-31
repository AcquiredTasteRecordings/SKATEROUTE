// Features/UX/HapticCue.swift
import UIKit

/// Enum representing different types of haptic feedback.
public enum HapticType {
    /// Light impact feedback.
    case light
    /// Medium impact feedback.
    case medium
    /// Heavy impact feedback.
    case heavy
    /// Success notification feedback.
    case success
    /// Error notification feedback.
    case error
}

/// Triggers haptic feedback based on the specified `HapticType`.
/// - Parameter type: The type of haptic feedback to trigger.
public func triggerHaptic(_ type: HapticType) {
    DispatchQueue.main.async {
        switch type {
        case .light:
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
        case .medium:
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.prepare()
            feedback.impactOccurred()
        case .heavy:
            let feedback = UIImpactFeedbackGenerator(style: .heavy)
            feedback.prepare()
            feedback.impactOccurred()
        case .success:
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.success)
        case .error:
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.error)
        }
    }
}

/// Medium impact haptic for upcoming turns.
/// Calls `triggerHaptic(.medium)` internally for consistency and safe execution.
public func triggerTurnHaptic() {
    triggerHaptic(.medium)
}
