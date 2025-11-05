// Features/Map/Views/LayerToggleBar.swift
import SwiftUI

public struct LayerToggleBar: View {
    public let layers: [RoutePlannerViewModel.PlannerLayer]
    @Binding public var selection: Set<RoutePlannerViewModel.PlannerLayer>

    public init(layers: [RoutePlannerViewModel.PlannerLayer],
                selection: Binding<Set<RoutePlannerViewModel.PlannerLayer>>) {
        self.layers = layers
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(layers) { layer in
                let isActive = selection.contains(layer)
                Button {
                    toggle(layer)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: layer.icon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(layer.title)
                            .font(.footnote)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isActive ? Color.accentColor.opacity(0.18) : Color(UIColor.secondarySystemBackground))
                    .foregroundColor(isActive ? .accentColor : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ layer: RoutePlannerViewModel.PlannerLayer) {
        if selection.contains(layer) {
            selection.remove(layer)
        } else {
            selection.insert(layer)
        }
    }
}
