// Features/Onboarding/OnboardingFlowView.swift
// Three-step onboarding with honest permission prompts, safety tips, and community norms.
// - Step 1: Location (Always/WhenInUse), Motion, Notifications — phrased plainly; requests are user-driven.
// - Step 2: Safety tips (helmets, awareness, respectful riding). Quick summary, no finger-wagging.
// - Step 3: Community norms. One-tap “I agree” → completes onboarding via coordinator hook.
// - If denied, “Fix in Settings” deep links to Settings.app. Never nags during active nav.
// - A11y: Large hit targets, Dynamic Type ready, VoiceOver labels. No tracking.
//
// Integration:
// • Uses DI seams for permission services (Location/Motion/Notifications) that follow our CoreLocation patterns.
// • AppCoordinator should set a persisted onboarding-complete flag and advance to Home.
//
// Tests (UI/E2E targets reference):
// • Denied → Settings button visible & working, state label updates.
// • Notifications request async completes and updates UI.
// • Finish button only enabled after user acknowledges norms checkbox.

import SwiftUI
import Combine
import CoreLocation
import CoreMotion
import UserNotifications
import UIKit

// MARK: - DI seams

public enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied           // includes restricted/limited states (we message honestly)
}

public protocol LocationPermissioning: AnyObject {
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { get }
    func requestWhenInUse() async
    func requestAlways() async
}

public protocol MotionPermissioning: AnyObject {
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { get }
    func request() async
}

public protocol NotificationPermissioning: AnyObject {
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { get }
    func request() async
}

public protocol OnboardingRouting: AnyObject {
    func completeOnboarding() // AppCoordinator flips persisted flag and routes to main app
}

// MARK: - ViewModel

@MainActor
public final class OnboardingFlowViewModel: ObservableObject {
    enum Step: Int, CaseIterable { case permissions = 0, safety, norms }

    // step must be writable for TabView(selection:) binding, and internal
    @Published var step: Step = .permissions

    @Published private(set) var locStatus: PermissionStatus = .notDetermined
    @Published private(set) var motionStatus: PermissionStatus = .notDetermined
    @Published private(set) var notifStatus: PermissionStatus = .notDetermined
    @Published public var acceptedNorms: Bool = false
    @Published public var errorMessage: String?

    private let location: LocationPermissioning
    private let motion: MotionPermissioning
    private let notifications: NotificationPermissioning
    private let router: OnboardingRouting

    private var cancellables = Set<AnyCancellable>()

    public init(location: LocationPermissioning,
                motion: MotionPermissioning,
                notifications: NotificationPermissioning,
                router: OnboardingRouting) {
        self.location = location
        self.motion = motion
        self.notifications = notifications
        self.router = router
        bind()
    }

    private func bind() {
        location.statusPublisher
            .receive(on: RunLoop.main)
            .assign(to: &self.$locStatus)
        motion.statusPublisher
            .receive(on: RunLoop.main)
            .assign(to: &self.$motionStatus)
        notifications.statusPublisher
            .receive(on: RunLoop.main)
            .assign(to: &self.$notifStatus)
    }

    // MARK: - Actions

    public func requestLocationWhenInUse() {
        Task { await location.requestWhenInUse() }
    }

    public func requestLocationAlways() {
        Task { await location.requestAlways() }
    }

    public func requestMotion() {
        Task { await motion.request() }
    }

    public func requestNotifications() {
        Task { await notifications.request() }
    }

    public func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    public func next() {
        switch step {
        case .permissions:
            step = .safety
        case .safety:
            step = .norms
        case .norms:
            finish()
        }
    }

    public func back() {
        switch step {
        case .permissions:
            break
        case .safety:
            step = .permissions
        case .norms:
            step = .safety
        }
    }

    public func finish() {
        guard acceptedNorms else {
            errorMessage = NSLocalizedString("Please accept our community norms to continue.", comment: "norms needed")
            return
        }
        router.completeOnboarding()
    }

    // MARK: - Helpers

    public func canProceedFromPermissions() -> Bool {
        // We do not force “Always”; When In Use + Motion is acceptable; Notifications optional but encouraged.
        locStatus != .notDetermined && motionStatus != .notDetermined
    }

    public func text(for status: PermissionStatus) -> String {
        switch status {
        case .notDetermined: return NSLocalizedString("Not set", comment: "not set")
        case .granted: return NSLocalizedString("Granted", comment: "granted")
        case .denied: return NSLocalizedString("Denied", comment: "denied")
        }
    }
}

// MARK: - View

public struct OnboardingFlowView: View {
    @ObservedObject private var vm: OnboardingFlowViewModel

    public init(viewModel: OnboardingFlowViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            progressDots

            TabView(selection: $vm.step) {
                permissionsStep.tag(OnboardingFlowViewModel.Step.permissions)
                safetyStep.tag(OnboardingFlowViewModel.Step.safety)
                normsStep.tag(OnboardingFlowViewModel.Step.norms)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: vm.step)

            footerBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(Text(NSLocalizedString("Welcome", comment: "title")))
        .overlay(toast, alignment: .bottom)
        .accessibilityIdentifier("onboarding_flow_root")
    }

    // MARK: Progress

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(OnboardingFlowViewModel.Step.allCases.enumerated()), id: \.offset) { _, s in
                Circle()
                    .fill(vm.step == s ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Steps

    private var permissionsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Let’s set things up", comment: "perm title"))
                    .font(.title2.weight(.bold))
                Text(NSLocalizedString("We use your location and motion to guide you safely. Notifications help with hazard alerts. You’re always in control.", comment: "perm body"))
                    .font(.body)
                    .foregroundStyle(.secondary)

                OnboardingPermissionCard(
                    title: NSLocalizedString("Location", comment: "loc"),
                    description: NSLocalizedString("Needed for turn-by-turn guidance and hazard alerts. “Always” lets us keep you safe during lock screen, but “While Using” also works.", comment: "loc desc"),
                    statusText: vm.text(for: vm.locStatus),
                    statusColor: color(for: vm.locStatus),
                    primaryTitle: NSLocalizedString("Allow While Using", comment: "wiu"),
                    secondaryTitle: NSLocalizedString("Allow Always", comment: "always"),
                    primaryAction: vm.requestLocationWhenInUse,
                    secondaryAction: vm.requestLocationAlways,
                    showSettings: vm.locStatus == .denied,
                    openSettings: vm.openSettings
                )

                OnboardingPermissionCard(
                    title: NSLocalizedString("Motion", comment: "motion"),
                    description: NSLocalizedString("Used to estimate speed and smoothness. We don’t track your fitness profile; just enough to keep rides accurate.", comment: "motion desc"),
                    statusText: vm.text(for: vm.motionStatus),
                    statusColor: color(for: vm.motionStatus),
                    primaryTitle: NSLocalizedString("Allow Motion", comment: "motion btn"),
                    primaryAction: vm.requestMotion,
                    showSettings: vm.motionStatus == .denied,
                    openSettings: vm.openSettings
                )

                OnboardingPermissionCard(
                    title: NSLocalizedString("Notifications", comment: "notif"),
                    description: NSLocalizedString("For hazard warnings and ride status. We’ll be quiet otherwise.", comment: "notif desc"),
                    statusText: vm.text(for: vm.notifStatus),
                    statusColor: color(for: vm.notifStatus),
                    primaryTitle: NSLocalizedString("Enable Alerts", comment: "notif btn"),
                    primaryAction: vm.requestNotifications,
                    showSettings: vm.notifStatus == .denied,
                    openSettings: vm.openSettings
                )

                Spacer(minLength: 20)
            }
            .padding(16)
        }
        .accessibilityIdentifier("onboarding_permissions")
    }

    private var safetyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Safety tips", comment: "safety title"))
                    .font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: 12) {
                    tip("Look ahead for cracks, rails, and gravel.")
                    tip("Brake early on steep hills; obey traffic signals.")
                    tip("Headphones low, one ear free preferred.")
                    tip("Helmet/guards recommended. Style points for being intact.")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                Text(NSLocalizedString("You can tweak alerts anytime in Settings.", comment: "safety foot"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 20)
            }
            .padding(16)
        }
        .accessibilityIdentifier("onboarding_safety")
    }

    private var normsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Community norms", comment: "norms title"))
                    .font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 10) {
                    norm("Respect people and places. Don’t film where it’s not welcome.")
                    norm("Share accurate spot details and honest hazard reports.")
                    norm("No hate, harassment, or sketchy promos. Keep it fun.")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                Toggle(isOn: $vm.acceptedNorms) {
                    Text(NSLocalizedString("I agree to play by these norms.", comment: "agree"))
                        .font(.body.weight(.semibold))
                }
                .toggleStyle(.switch)
                .padding(.top, 6)
                .accessibilityIdentifier("norms_accept_toggle")

                Spacer(minLength: 20)
            }
            .padding(16)
        }
        .accessibilityIdentifier("onboarding_norms")
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if vm.step != .permissions {
                Button(action: vm.back) {
                    Label(NSLocalizedString("Back", comment: "back"), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }

            Spacer()

            switch vm.step {
            case .permissions:
                Button(action: vm.next) {
                    Label(NSLocalizedString("Continue", comment: "next"), systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!vm.canProceedFromPermissions())
                .accessibilityHint(Text(NSLocalizedString("Enable at least Location and Motion to continue.", comment: "perm hint")))
            case .safety:
                Button(action: vm.next) {
                    Label(NSLocalizedString("Continue", comment: "next"), systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            case .norms:
                Button(action: vm.finish) {
                    Label(NSLocalizedString("Finish", comment: "finish"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!vm.acceptedNorms)
                .accessibilityHint(Text(NSLocalizedString("Accept the norms to finish.", comment: "norms hint")))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Helpers

    private func tip(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "light.max").imageScale(.small)
            Text(s).font(.body)
        }
        .accessibilityElement(children: .combine)
    }

    private func norm(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised").imageScale(.small)
            Text(s).font(.body)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }

    // Toast

    @ViewBuilder
    private var toast: some View {
        if let msg = vm.errorMessage {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").imageScale(.large).accessibilityHidden(true)
                Text(msg).font(.callout)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
            .foregroundColor(.white)
            .padding(.bottom, 12)
            .onAppear {
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    await MainActor.run { vm.errorMessage = nil }
                }
            }
        }
    }
}

// MARK: - Minimal Permission card used only in onboarding

fileprivate struct OnboardingPermissionCard: View {
    let title: String
    let description: String
    let statusText: String
    let statusColor: Color
    let primaryTitle: String
    var secondaryTitle: String? = nil
    let primaryAction: () -> Void
    var secondaryAction: (() -> Void)? = nil
    let showSettings: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundColor(statusColor)
                    .accessibilityLabel(Text("\(title) status: \(statusText)"))
            }
            Text(description).font(.footnote).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: primaryAction) { Text(primaryTitle) }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)

                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) { Text(secondaryTitle) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }

                Spacer()

                if showSettings {
                    Button(action: openSettings) {
                        Label(NSLocalizedString("Fix in Settings", comment: "settings"), systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityHint(Text(NSLocalizedString("Opens iOS Settings to change permission.", comment: "settings hint")))
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - DEBUG fakes

#if DEBUG
// Simple fakes that simulate state changes; great for previews and UI tests.
final class LocationPermFake: LocationPermissioning {
    private let subj = CurrentValueSubject<PermissionStatus, Never>(.notDetermined)
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { subj.eraseToAnyPublisher() }
    func requestWhenInUse() async { subj.send(.granted) }
    func requestAlways() async { subj.send(.granted) }
}
final class MotionPermFake: MotionPermissioning {
    private let subj = CurrentValueSubject<PermissionStatus, Never>(.notDetermined)
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { subj.eraseToAnyPublisher() }
    func request() async { subj.send(.granted) }
}
final class NotifPermFake: NotificationPermissioning {
    private let subj = CurrentValueSubject<PermissionStatus, Never>(.notDetermined)
    var statusPublisher: AnyPublisher<PermissionStatus, Never> { subj.eraseToAnyPublisher() }
    func request() async { subj.send(.granted) }
}
final class RouterFake: OnboardingRouting { func completeOnboarding() {} }

struct OnboardingFlowView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            OnboardingFlowView(
                viewModel: .init(location: LocationPermFake(),
                                 motion: MotionPermFake(),
                                 notifications: NotifPermFake(),
                                 router: RouterFake())
            )
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `LocationPermissioning` to your LocationManagerService wrapper:
//   - Publish `granted` when authStatus is .authorizedAlways/.authorizedWhenInUse; map .denied/.restricted to .denied.
//   - `requestAlways()` should sequence WhenInUse → Always (per Apple guidelines) with clear rationale in UI.
// • `MotionPermissioning` can be backed by CMMotionActivityManager or CoreMotion authorization query; never store raw samples here.
// • `NotificationPermissioning` wraps UNUserNotificationCenter.current().requestAuthorization(...) and publishes status changes.
// • On finish, AppCoordinator flips a persisted flag (e.g., UserDefaults/SwiftData) and routes to HomeView.
// • Respect PaywallRules: onboarding never shows paywall, and hazard/reroute features remain available regardless of purchase state.
