// Features/Map/Views/LayerToggleBar.swift
// Compact, accessible toggle bar for planner layers (grade, hazards, offline, etc.).
// Multi-select, haptic-confirmed, VoiceOver-friendly, and motion-aware.

import SwiftUI
import UIKit

public struct LayerToggleBar: View {
    public let layers: [RoutePlannerViewModel.PlannerLayer]
    @Binding public var selection: Set<RoutePlannerViewModel.PlannerLayer>

    // Optional polish
    private let enableHaptics: Bool
    private let showsOutlineWhenActive: Bool
    private let compressesTextInCompact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var hSize

    /// Primary initializer (kept source-compatible with existing call sites).
    public init(
        layers: [RoutePlannerViewModel.PlannerLayer],
        selection: Binding<Set<RoutePlannerViewModel.PlannerLayer>>,
        enableHaptics: Bool = true,
        showsOutlineWhenActive: Bool = true,
        compressesTextInCompact: Bool = true
    ) {
        self.layers = layers
        self._selection = selection
        self.enableHaptics = enableHaptics
        self.showsOutlineWhenActive = showsOutlineWhenActive
        self.compressesTextInCompact = compressesTextInCompact
    }

    public var body: some View {
        // Horizontal scroller so chips don’t get squished; wraps nicely on iPad with .regular width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(layers) { layer in
                    let isActive = selection.contains(layer)
                    chip(for: layer, isActive: isActive)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(layer.accessibilityLabel ?? layer.title)
                        .accessibilityHint(layer.accessibilityHint ?? "Toggle layer")
                        .accessibilityAddTraits(isActive ? [.isSelected, .updatesFrequently] : [])
                        .accessibilityValue(isActive ? "On" : "Off")
                }
            }
            .padding(.horizontal, 2)
            .contentMargins(0, for: .scrollContent)
        }
        .accessibilityIdentifier("LayerToggleBar.Scroll")
    }

    // MARK: - Chip

    @ViewBuilder
    private func chip(for layer: RoutePlannerViewModel.PlannerLayer, isActive: Bool) -> some View {
        Button {
            withAppropriateAnimation {
                toggle(layer)
            }
            if enableHaptics { HapticCue.selection() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: layer.icon)
                    .font(.system(size: 14, weight: .semibold))
                if !shouldHideText {
                    Text(layer.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 34) // larger hit target
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.16)
                                   : Color(UIColor.secondarySystemBackground))
            )
            .overlay {
                if showsOutlineWhenActive {
                    Capsule(style: .continuous)
                        .stroke(isActive ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("LayerToggleBar.Chip.\(layer.id)")
        .contextMenu {
            // Quick actions (idempotent)
            Button(isActive ? "Turn Off" : "Turn On") { toggle(layer) }
            Button("Only This") {
                withAppropriateAnimation {
                    selection = [layer]
                }
                if enableHaptics { HapticCue.firm() }
            }
            Button("Turn All Off") {
                withAppropriateAnimation { selection.removeAll() }
                if enableHaptics { HapticCue.light() }
            }
        }
    }

    // MARK: - Logic

    private func toggle(_ layer: RoutePlannerViewModel.PlannerLayer) {
        if selection.contains(layer) {
            selection.remove(layer)
        } else {
            selection.insert(layer)
        }
    }

    // Hide text on very compact layouts to keep chips readable
    private var shouldHideText: Bool {
        compressesTextInCompact && hSize == .compact
    }

    private func withAppropriateAnimation(_ changes: @escaping () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { changes() }
        }
    }
}

// MARK: - Preview

#if DEBUG
private struct _LayerToggleBar_Previews: PreviewProvider {
    struct Host: View {
        @State var selection: Set<RoutePlannerViewModel.PlannerLayer> = []
        let layers: [RoutePlannerViewModel.PlannerLayer] = [
            .grade, .surface, .hazards, .offline, .satellite
        ]
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                LayerToggleBar(layers: layers, selection: $selection)
                Text("Active: \(selection.map { $0.title }.joined(separator: ", "))")                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
        }
    }
    static var previews: some View { Host() }
}
#endif


