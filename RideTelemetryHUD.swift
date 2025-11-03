// Features/UX/RideTelemetryHUD.swift
import SwiftUI

/// A heads-up display showing real-time ride telemetry including speed and surface roughness.
/// 
/// - `RMS` (Root Mean Square) represents the roughness of the riding surface, where lower values indicate smoother terrain.
/// - `speedKPH` is the current speed of the rider in kilometers per hour.
///
/// The HUD provides color-coded feedback and icons to visually communicate the surface condition:
/// - Butter (RMS < 0.08): 🧈 Very smooth surface
/// - Smooth (RMS < 0.16): 😎 Smooth surface
/// - Meh (RMS < 0.28): 😐 Moderate roughness
/// - Crusty (RMS >= 0.28): 💀 Very rough/crusty surface
struct RideTelemetryHUD: View {
    @ObservedObject var recorder: RideRecorder
    @State private var labelOpacity = 1.0
    @State private var labelScale = 1.0

    private func bg(for rms: Double) -> Color {
        switch rms {
        case ..<0.08: return Color.green.opacity(0.35)     // butter
        case ..<0.16: return Color.yellow.opacity(0.35)    // meh
        case ..<0.28: return Color.orange.opacity(0.35)    // rough
        default:       return Color.red.opacity(0.35)       // crusty
        }
    }

    private func label(for rms: Double) -> String {
        switch rms {
        case ..<0.08: return "BUTTER"
        case ..<0.16: return "SMOOTH"
        case ..<0.28: return "MEH"
        default:       return "CRUSTY"
        }
    }
    
    private func icon(for rms: Double) -> String {
        switch rms {
        case ..<0.08: return "🧈"
        case ..<0.16: return "😎"
        case ..<0.28: return "😐"
        default:       return "💀"
        }
    }
    
    private func adaptiveTextColor(for rms: Double) -> Color {
        // Use black text for light backgrounds, white text for dark backgrounds for contrast
        let bgColor = bg(for: rms)
        // Approximate luminance check
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(bgColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? Color.black : Color.white
    }

    var body: some View {
        let rms = recorder.lastRMS
        let speed = recorder.speedKPH
        let currentLabel = label(for: rms)
        let currentIcon = icon(for: rms)
        let textColor = adaptiveTextColor(for: rms)
        
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f km/h", speed))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(textColor)
                Text(String(format: "RMS %.2f", rms))
                    .font(.caption)
                    .opacity(0.8)
                    .foregroundColor(textColor)
            }
            
            HStack(spacing: 6) {
                Text(currentIcon)
                Text(currentLabel)
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.4))
            .clipShape(Capsule())
            .foregroundColor(.white)
            .opacity(labelOpacity)
            .scaleEffect(labelScale)
            .animation(.easeInOut(duration: 0.3), value: currentLabel)
            .onChange(of: currentLabel) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    labelOpacity = 0.5
                    labelScale = 1.1
                }
                withAnimation(.easeInOut(duration: 0.15).delay(0.15)) {
                    labelOpacity = 1.0
                    labelScale = 1.0
                }
            }
        }
        .padding(12)
        .background(
            bg(for: rms)
                .blur(radius: 16)
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Surface condition \(currentLabel.lowercased()), speed \(Int(speed)) kilometers per hour")
    }
}
