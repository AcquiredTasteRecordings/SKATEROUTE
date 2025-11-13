// Features/Map/SurfaceLegendView.swift
// Bottom-pinned, Dynamic-Type-ready legend explaining grade/surface overlay colors.
// - Two modes: .grade (elevation %) and .surface (skateability / surface quality).
// - Compact collapsed chip (one tap expands). Big hit targets, VO friendly.
// - Colors match SmoothOverlayRenderer + Route scoring palette (adapter here keeps Views decoupled).
// - No tracking, no location reads. Pure UI; inputs via DI.

import SwiftUI
import UIKit

// MARK: - Legend domain

public enum OverlayLegendKind: Equatable, Sendable {
    case grade       // elevation slope buckets, e.g. 0–2%, 2–5%, 5–8%, 8%+
    case surface     // surface quality buckets, e.g. A/B/C/D/F
}

public struct LegendSwatch: Equatable, Sendable, Identifiable {
    public enum Fill: Equatable, Sendable {
        case color(Color)
        case gradient(LinearGradient)
        case pattern(Color, Color) // fallback stripe for special states
    }
    public var id: String { key }
    public let key: String
    public let title: String
    public let subtitle: String?
    public let fill: Fill
    public init(key: String, title: String, subtitle: String? = nil, fill: Fill) {
        self.key = key; self.title = title; self.subtitle = subtitle; self.fill = fill
    }
}

// MARK: - DI seam

public protocol LegendProviding: AnyObject {
    func legend(for kind: OverlayLegendKind) -> [LegendSwatch]
}

// Default adapter that mirrors our renderer palettes.
// Keep in Features to avoid tight coupling to Services/Renderers.
public final class DefaultLegendProvider: LegendProviding {
    public init() {}
    public func legend(for kind: OverlayLegendKind) -> [LegendSwatch] {
        switch kind {
        case .grade:
            // Gentle → Brutal. Mirrors polyline segments coloring in SmoothOverlayRenderer.
            return [
                LegendSwatch(key: "g0", title: "0–2%", subtitle: NSLocalizedString("Flat / easy push", comment: ""),
                             fill: .color(Color.green.opacity(0.9))),
                LegendSwatch(key: "g1", title: "2–5%", subtitle: NSLocalizedString("Mellow climb/roll", comment: ""),
                             fill: .color(Color.yellow.opacity(0.95))),
                LegendSwatch(key: "g2", title: "5–8%", subtitle: NSLocalizedString("Steep—mind speed", comment: ""),
                             fill: .color(Color.orange)),
                LegendSwatch(key: "g3", title: "8%+", subtitle: NSLocalizedString("Spicy / brake ready", comment: ""),
                             fill: .color(Color.red))
            ]
        case .surface:
            // A → F quality buckets used in surface overlay + spot detail cards.
            return [
                LegendSwatch(key: "sA", title: "A", subtitle: NSLocalizedString("Glass-smooth", comment: ""),
                             fill: .color(Color.green.opacity(0.9))),
                LegendSwatch(key: "sB", title: "B", subtitle: NSLocalizedString("Good concrete", comment: ""),
                             fill: .color(Color.teal)),
                LegendSwatch(key: "sC", title: "C", subtitle: NSLocalizedString("OK with cracks", comment: ""),
                             fill: .color(Color.yellow)),
                LegendSwatch(key: "sD", title: "D", subtitle: NSLocalizedString("Rough / patchy", comment: ""),
                             fill: .color(Color.orange)),
                LegendSwatch(key: "sF", title: "F", subtitle: NSLocalizedString("Sketchy / avoid", comment: ""),
                             fill: .color(Color.red)),
                LegendSwatch(key: "sU", title: NSLocalizedString("No data", comment: ""), subtitle: nil,
                             fill: .pattern(Color.gray.opacity(0.35), Color.gray.opacity(0.1)))
            ]
        }
    }
}

// MARK: - ViewModel

@MainActor
public final class SurfaceLegendViewModel: ObservableObject {
    @Published public private(set) var items: [LegendSwatch] = []
    @Published public var isExpanded: Bool = false
    @Published public var kind: OverlayLegendKind {
        didSet { reload() }
    }

    private let provider: LegendProviding

    public init(kind: OverlayLegendKind, provider: LegendProviding) {
        self.kind = kind
        self.provider = provider
        reload()
    }

    public func toggle() {
        isExpanded.toggle()
        UIAccessibility.post(notification: .announcement, argument:
            isExpanded
            ? NSLocalizedString("Legend expanded", comment: "")
            : NSLocalizedString("Legend collapsed", comment: ""))
    }

    public func setKind(_ k: OverlayLegendKind) {
        guard kind != k else { return }
        kind = k
    }

    private func reload() {
        items = provider.legend(for: kind)
    }
}

// MARK: - View

public struct SurfaceLegendView: View {
    @ObservedObject private var vm: SurfaceLegendViewModel
    private let showsKindToggle: Bool

    /// - Parameters:
    ///   - viewModel: Inject with AppDI DefaultLegendProvider unless overridden.
    ///   - showsKindToggle: Show pill to switch between Grade/Surface when available on HUD.
    public init(viewModel: SurfaceLegendViewModel, showsKindToggle: Bool = true) {
        self.vm = viewModel
        self.showsKindToggle = showsKindToggle
    }

    public var body: some View {
        HStack(spacing: 8) {
            if showsKindToggle { kindToggle }
            if vm.isExpanded {
                list
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            collapseButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .compositingGroup()
        .shadow(radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Map legend", comment: "")))
    }

    // MARK: Kind toggle

    private var kindToggle: some View {
        Menu {
            Button {
                vm.setKind(.grade)
            } label: {
                Label(NSLocalizedString("Grade", comment: ""), systemImage: "triangle.lefthalf.filled")
            }
            Button {
                vm.setKind(.surface)
            } label: {
                Label(NSLocalizedString("Surface", comment: ""), systemImage: "square.grid.3x1.below.line.grid.1x2")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.kind == .grade ? "triangle.lefthalf.filled" : "square.grid.3x1.below.line.grid.1x2")
                    .imageScale(.medium)
                Text(vm.kind == .grade ? NSLocalizedString("Grade", comment: "") : NSLocalizedString("Surface", comment: ""))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("legend_kind_toggle")
    }

    // MARK: List

    private var list: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(vm.items) { item in
                    LegendChip(item: item)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(height: 44) // stable tap target
        .accessibilityIdentifier("legend_items")
    }

    // MARK: Expand/Collapse

    private var collapseButton: some View {
        Button(action: vm.toggle) {
            Image(systemName: vm.isExpanded ? "chevron.down.circle.fill" : "info.circle.fill")
                .imageScale(.large)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(vm.isExpanded ? .gray.opacity(0.35) : .accentColor)
        .accessibilityLabel(Text(NSLocalizedString("Legend", comment: "")))
        .accessibilityValue(Text(vm.isExpanded ? NSLocalizedString("Expanded", comment: "") : NSLocalizedString("Collapsed", comment: "")))
        .accessibilityHint(Text(NSLocalizedString("Double tap to toggle.", comment: "")))
        .accessibilityIdentifier("legend_toggle")
    }
}

// MARK: - Chip

fileprivate struct LegendChip: View {
    let item: LegendSwatch

    var body: some View {
        HStack(spacing: 8) {
            swatch
                .frame(width: 22, height: 10)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.footnote.weight(.semibold))
                if let sub = item.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.title)\(item.subtitle != nil ? ", \(item.subtitle!)" : "")"))
        .accessibilityHint(Text(NSLocalizedString("Legend item", comment: "")))
    }

    @ViewBuilder
    private var swatch: some View {
        switch item.fill {
        case .color(let c): c
        case .gradient(let g): g
        case .pattern(let a, let b):
            ZStack {
                b
                DiagonalStripes(foreground: a)
            }
        }
    }
}

// MARK: - Pattern helper

fileprivate struct DiagonalStripes: View {
    let foreground: Color
    var body: some View {
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height)
            Path { path in
                var x: CGFloat = -size
                while x < size * 2 {
                    path.addRect(CGRect(x: x, y: 0, width: 6, height: geo.size.height))
                    x += 12
                }
            }
            .rotation(Angle(degrees: 45))
            .fill(foreground.opacity(0.6))
        }
        .clipped()
    }
}

// MARK: - Convenience builders

public extension SurfaceLegendView {
    /// Bottom-pins the legend using safe-area inset; call from any screen with a Map.
    static func pinned(kind: OverlayLegendKind,
                       provider: LegendProviding = DefaultLegendProvider(),
                       showsKindToggle: Bool = true) -> some View {
        let vm = SurfaceLegendViewModel(kind: kind, provider: provider)
        return SurfaceLegendView(viewModel: vm, showsKindToggle: showsKindToggle)
            .safeAreaPadding(.horizontal, 12)
            .safeAreaInset(edge: .bottom, spacing: 8) {
                HStack { Spacer(); SurfaceLegendView(viewModel: vm, showsKindToggle: showsKindToggle) }
                    .padding(.bottom, 8)
            }
    }
}

// MARK: - DEBUG preview

#if DEBUG
struct SurfaceLegendView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()
            SurfaceLegendView.pinned(kind: .grade)
        }
        .background(
            LinearGradient(colors: [.black, .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        .previewDisplayName("Grade Legend")
    }
}
#endif

// MARK: - Integration notes
// • Place with .safeAreaInset(edge: .bottom) on MapScreen; keep outside Map’s annotation layer for perf.
// • Keep color buckets aligned with SmoothOverlayRenderer + Skateability score mapping.
// • When overlay mode switches (e.g., user toggles Surface vs Grade), call viewModel.setKind(_:) or create with correct kind.
// • UITests: tap “legend_toggle” to expand/collapse; verify “legend_items” exists when expanded; toggle kind via “legend_kind_toggle”.

// MARK: - Test plan (unit/UI)
// • Accessibility: VoiceOver reads “Map legend, Expanded/Collapsed”; chips expose concise labels.
// • Dynamic Type XXL: layout remains readable; chips wrap horizontally; button hit targets stay ≥44pt.
// • State: toggling kind refreshes items deterministically; collapsed state persists while navigating.
// • Dark/Light: swatches maintain contrast; “No data” pattern visible on both themes.


