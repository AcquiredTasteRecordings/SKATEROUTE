// Features/Onboarding/PermissionCard.swift
// Reusable permission card with purpose strings, status badge, and CTAs.
// - Honest copy; no nag loops. Presents primary and optional secondary request actions.
// - If denied, shows “Try again” and “Fix in Settings” deep link.
// - A11y: clear labels, ≥44pt targets, Dynamic Type safe. VoiceOver announces status updates.
// - Styling: material background + subtle border; consistent with other onboarding components.

import SwiftUI

// MARK: - Public surface

public struct PermissionCard: View {
    public enum Kind: String, Sendable {
        case location, motion, notifications
        public var icon: String {
            switch self {
            case .location: return "location.circle.fill"
            case .motion: return "figure.walk.motion"
            case .notifications: return "bell.badge.fill"
            }
        }
        public var title: String {
            switch self {
            case .location: return NSLocalizedString("Location", comment: "perm title")
            case .motion: return NSLocalizedString("Motion", comment: "perm title")
            case .notifications: return NSLocalizedString("Notifications", comment: "perm title")
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case notDetermined
        case granted
        case denied
        public var text: String {
            switch self {
            case .notDetermined: return NSLocalizedString("Not set", comment: "perm status")
            case .granted:       return NSLocalizedString("Granted", comment: "perm status")
            case .denied:        return NSLocalizedString("Denied", comment: "perm status")
            }
        }
        public var tint: Color {
            switch self {
            case .granted: return .green
            case .denied: return .red
            case .notDetermined: return .secondary
            }
        }
    }

    // Immutable configuration
    public struct Config: Sendable, Equatable {
        public let kind: Kind
        public let purpose: String          // “Used for turn-by-turn + hazard alerts…”
        public let primaryTitle: String     // “Allow While Using”
        public let secondaryTitle: String?  // e.g., “Allow Always”
        public let showsSettingsWhenDenied: Bool
        public init(kind: Kind,
                    purpose: String,
                    primaryTitle: String,
                    secondaryTitle: String? = nil,
                    showsSettingsWhenDenied: Bool = true) {
            self.kind = kind
            self.purpose = purpose
            self.primaryTitle = primaryTitle
            self.secondaryTitle = secondaryTitle
            self.showsSettingsWhenDenied = showsSettingsWhenDenied
        }
    }

    // Inputs
    private let config: Config
    private let status: Status

    // Callbacks
    private let onPrimary: () -> Void
    private let onSecondary: (() -> Void)?
    private let onOpenSettings: (() -> Void)?

    // MARK: - Init

    public init(config: Config,
                status: Status,
                onPrimary: @escaping () -> Void,
                onSecondary: (() -> Void)? = nil,
                onOpenSettings: (() -> Void)? = { // sensible default to Settings.app
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
        self.config = config
        self.status = status
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(config.purpose)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            buttons
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission_card_\(config.kind.rawValue)")
        .onChange(of: status) { newValue in
            UIAccessibility.post(notification: .announcement,
                                 argument: "\(config.kind.title) \(newValue.text)")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: config.kind.icon)
                .imageScale(.large)
                .accessibilityHidden(true)

            Text(config.kind.title)
                .font(.headline)

            Spacer()

            StatusBadge(text: status.text, tint: status.tint)
                .accessibilityLabel(Text("\(config.kind.title) status \(status.text)"))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            if status == .denied {
                Button(action: onPrimary) {
                    Label(NSLocalizedString("Try again", comment: "retry"), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            } else {
                Button(action: onPrimary) {
                    Text(config.primaryTitle)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(status == .granted)
            }

            if let secondary = config.secondaryTitle, let onSecondary {
                Button(action: onSecondary) { Text(secondary) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(status == .granted)
            }

            Spacer()

            if status == .denied, config.showsSettingsWhenDenied, let onOpenSettings {
                Button(action: onOpenSettings) {
                    Label(NSLocalizedString("Fix in Settings", comment: "open settings"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint(Text(NSLocalizedString("Opens iOS Settings to change permission.", comment: "settings hint")))
            }
        }
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundColor(tint)
            .accessibilityHidden(true)
    }
}

// MARK: - Convenience helpers for external callers

public extension PermissionCard.Status {
    static func fromBool(_ granted: Bool?, deniedWhenNil: Bool = false) -> Self {
        guard let granted else { return deniedWhenNil ? .denied : .notDetermined }
        return granted ? .granted : .denied
    }
}

// MARK: - DEBUG previews

#if DEBUG
struct PermissionCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            PermissionCard(
                config: .init(kind: .location,
                              purpose: "Needed for turn-by-turn guidance and hazard alerts. “Always” lets us keep you safe during lock screen; “While Using” also works.",
                              primaryTitle: "Allow While Using",
                              secondaryTitle: "Allow Always"),
                status: .notDetermined,
                onPrimary: {},
                onSecondary: {}
            )

            PermissionCard(
                config: .init(kind: .motion,
                              purpose: "Used to estimate speed and smoothness. No fitness tracking.",
                              primaryTitle: "Allow Motion"),
                status: .denied,
                onPrimary: {},
                onSecondary: nil
            )

            PermissionCard(
                config: .init(kind: .notifications,
                              purpose: "For hazard warnings and ride status. We’ll be quiet otherwise.",
                              primaryTitle: "Enable Alerts"),
                status: .granted,
                onPrimary: {}
            )
        }
        .padding()
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Drop this card into OnboardingFlowView (replace the inline version). Keep the same copy tone.
// • Wire buttons to your permission request functions; after the system sheet resolves, update status to re-render the badge.
// • If you use custom coordinators for Settings navigation, inject `onOpenSettings` to route through your AppCoordinator.
// • UI tests: assert presence by `permission_card_<kind>`, tap “Try again” when denied → request called, Settings button present when denied.
