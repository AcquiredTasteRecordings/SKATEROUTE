// Features/Map/Views/LayerToggleBar.swift
// Compact, accessible toggle bar for planner layers (grade, hazards, offline, etc.).
// Multi-select, haptic-confirmed, VoiceOver-friendly, and motion-aware.

import SwiftUI
import UIKit

public struct LayerToggleBar: View {
    public struct Option: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let icon: String
        public let accessibilityLabel: String?
        public let accessibilityHint: String?

        public init(id: String,
                    title: String,
                    icon: String,
                    accessibilityLabel: String? = nil,
                    accessibilityHint: String? = nil) {
            self.id = id
            self.title = title
            self.icon = icon
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityHint = accessibilityHint
        }
    }

    public let options: [Option]
    @Binding public var selection: Set<Option>

    // Optional polish
    private let enableHaptics: Bool
    private let showsOutlineWhenActive: Bool
    private let compressesTextInCompact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var hSize

    /// Primary initializer (kept source-compatible with existing call sites).
    public init(
        options: [Option],
        selection: Binding<Set<Option>>,
        enableHaptics: Bool = true,
        showsOutlineWhenActive: Bool = true,
        compressesTextInCompact: Bool = true
    ) {
        self.options = options
        self._selection = selection
        self.enableHaptics = enableHaptics
        self.showsOutlineWhenActive = showsOutlineWhenActive
        self.compressesTextInCompact = compressesTextInCompact
    }

    public var body: some View {
        // Horizontal scroller so chips don’t get squished; wraps nicely on iPad with .regular width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options) { option in
                    let isActive = selection.contains(option)
                    chip(for: option, isActive: isActive)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(option.accessibilityLabel ?? option.title)
                        .accessibilityHint(option.accessibilityHint ?? "Toggle layer")
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
    private func chip(for option: Option, isActive: Bool) -> some View {
        Button {
            withAppropriateAnimation {
                toggle(option)
            }
            if enableHaptics { HapticCue.selection() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 14, weight: .semibold))
                if !shouldHideText {
                    Text(option.title)
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
        .accessibilityIdentifier("LayerToggleBar.Chip.\(option.id)")
        .contextMenu {
            // Quick actions (idempotent)
            Button(isActive ? "Turn Off" : "Turn On") { toggle(option) }
            Button("Only This") {
                withAppropriateAnimation {
                    selection = [option]
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

    private func toggle(_ option: Option) {
        if selection.contains(option) {
            selection.remove(option)
        } else {
            selection.insert(option)
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
        @State var selection: Set<LayerToggleBar.Option> = []
        let layers: [LayerToggleBar.Option] = [
            .init(id: "grade", title: "Grade", icon: "chart.xyaxis.line"),
            .init(id: "surface", title: "Surface", icon: "square.grid.3x3.fill"),
            .init(id: "hazards", title: "Hazards", icon: "exclamationmark.triangle"),
            .init(id: "offline", title: "Offline", icon: "tray.and.arrow.down"),
            .init(id: "satellite", title: "Satellite", icon: "globe")
        ]
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                LayerToggleBar(options: layers, selection: $selection)
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


