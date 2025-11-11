// Features/Home/HomeView.swift
import SwiftUI
import MapKit
import CoreLocation
import AVFoundation
import Combine

struct HomeView: View {
    private let dependencies: any AppDependencyContainer

    // ViewModel binding (coordinator bridged via navIntent sink)
    @StateObject private var vm = HomeViewModel(
        geocoder: GeocoderService(),
        currentLocationProvider: {
            // Bridge to one-shot provider
            try await withCheckedThrowingContinuation { cont in
                let provider = OneShotLocationProvider()
                provider.request { status, loc in
                    if (status == .authorizedAlways || status == .authorizedWhenInUse),
                       let c = loc?.coordinate {
                        cont.resume(returning: c)
                    } else {
                        cont.resume(throwing: HomeLocationError.denied)
                    }
                }
            }
        },
        coordinator: nil // we’ll forward with env coordinator via navIntent sink
    )

    @State private var isSearching = false
    @State private var showStats = false
    @State private var asphaltOffset: CGFloat = 0
    @State private var cancellables: Set<AnyCancellable> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.sizeCategory) private var sizeCategory
    @EnvironmentObject private var coordinator: AppCoordinator

    // Timer for parallax asphalt animation (disabled when Reduce Motion is on)
    private let timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

    // System sound ID for soft whoosh
    private let whooshSoundID: SystemSoundID = 1104

    init(dependencies: any AppDependencyContainer) {
        self.dependencies = dependencies
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image("AsphaltTexture")
                .resizable()
                .scaledToFill()
                .opacity(reduceTransparency ? 0.08 : 0.16)
                .blendMode(.overlay)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .offset(x: asphaltOffset)
                .onReceive(timer) { _ in
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 0.02)) {
                        asphaltOffset = (asphaltOffset > 10) ? -10 : asphaltOffset + 0.2
                    }
                }

            VStack(spacing: 28) {
                // Logo + animated glow + shimmering tagline
                VStack(spacing: 14) {
                    ZStack {
                        if !reduceMotion {
                            AnimatedGradientGlow()
                                .frame(width: 280, height: 280)
                                .clipShape(Circle())
                                .blur(radius: 30)
                                .opacity(reduceTransparency ? 0.45 : 0.7)
                                .accessibilityHidden(true)
                        }

                        LogoLockup()
                            .padding(.top, 54)
                    }

                    ShimmeringText("All Downhill From Here", reduceMotion: reduceMotion)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .kerning(0.5)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Tagline: All Downhill From Here")
                }
                .padding(.horizontal, 24)

                // Primary actions
                VStack(spacing: 14) {
                    Button {
                        Haptics.tap()
                        if UIAccessibility.isVoiceOverRunning {
                            UIAccessibility.post(notification: .announcement, argument: "Opening place search")
                        }
                        AudioServicesPlaySystemSound(whooshSoundID)
                        isSearching = true
                    } label: {
                        Text("Find Smooth Line")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white)
                            )
                    }
                    .accessibilityLabel("Find Smooth Line button")

                    // Inline validation message from VM (localized)
                    if let msg = vm.errorMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                            .accessibilityLabel(msg)
                    }

                    Button {
                        Haptics.selection()
                        if UIAccessibility.isVoiceOverRunning {
                            UIAccessibility.post(notification: .announcement, argument: "Drop a spot coming soon")
                        }
                        // TODO: Hook to quick-spot capture or a sheet
                    } label: {
                        Text("Drop a Spot")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                            )
                    }
                    .accessibilityLabel("Drop a Spot button")

                    Button {
                        Haptics.light()
                        if UIAccessibility.isVoiceOverRunning {
                            UIAccessibility.post(notification: .announcement, argument: "Opening session stats")
                        }
                        showStats = true
                    } label: {
                        Text("Session Stats")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Session Stats button")
                    .sheet(isPresented: $showStats) {
                        Text("Stats View Coming Soon")
                            .font(.title)
                            .foregroundColor(.white)
                            .background(Color.black.ignoresSafeArea())
                            .accessibilityAddTraits(.isModal)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                FooterStats()
                    .padding(.bottom, 28)
            }
        }
        // Bind VM lifecycle + navIntent → coordinator
        .onAppear {
            vm.appear()

            // Route when VM emits an intent
            vm.$navIntent
                .compactMap { $0 }
                .sink { intent in
                    coordinator.presentMap(from: intent.from, to: intent.to, mode: intent.mode)
                }
                .store(in: &cancellables)
        }
        .sheet(isPresented: $isSearching) {
            PlaceSearchView(
                title: "Find a Spot",
                region: nil,
                showUseCurrentLocation: true,
                currentLocationProvider: {
                    dependencies.locationManager.currentLocation?.coordinate
                },
                onPick: { item in
                    vm.pickTo(item: item)
                    // Use VM validation + routing; respects localized errors
                    if vm.validate() == nil {
                        vm.go()
                        Haptics.success()
                        isSearching = false
                    } else {
                        // Keep sheet open so the rider can correct input
                        Haptics.warning()
                    }
                },
                onUseCurrentLocationDenied: {
                    Haptics.warning()
                    if UIAccessibility.isVoiceOverRunning {
                        UIAccessibility.post(notification: .announcement, argument: "Location permission needed")
                    }
                }
            )
            .accessibilityAddTraits(.isModal)
        }
    }
}

// MARK: - Supporting Views

private struct ShimmeringText: View {
    let text: String
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    init(_ text: String, reduceMotion: Bool) {
        self.text = text
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        if reduceMotion {
            Text(text)
        } else {
            Text(text)
                .overlay(
                    LinearGradient(
                        gradient: Gradient(colors: [.white.opacity(0.4), .white, .white.opacity(0.4)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .rotationEffect(.degrees(30))
                    .offset(x: phase * 350)
                    .blendMode(.screen)
                )
                .mask(Text(text))
                .onAppear {
                    withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}

private struct AnimatedGradientGlow: View {
    @State private var animateGradient = false

    var body: some View {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 0.98, green: 0.32, blue: 0.18),
                Color(red: 0.94, green: 0.74, blue: 0.23),
                Color(red: 0.18, green: 0.76, blue: 0.54),
                Color(red: 0.17, green: 0.63, blue: 0.91),
                Color(red: 0.98, green: 0.32, blue: 0.18)
            ]),
            center: .center,
            angle: .degrees(animateGradient ? 360 : 0)
        )
        .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: animateGradient)
        .onAppear { animateGradient = true }
    }
}

// MARK: - Components

private struct LogoLockup: View {
    var body: some View {
        Image("SkateRouteLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
            .accessibilityLabel("SkateRoute — All Downhill From Here")
    }
}

private struct FooterStats: View {
    var body: some View {
        HStack(spacing: 14) {
            StatTile(title: "KM", value: "0.0")
            StatTile(title: "Spots", value: "0")
            StatTile(title: "Badges", value: "0")
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.heavy))
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Haptics (local)

enum Haptics {
    private static let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notifyGen = UINotificationFeedbackGenerator()
    private static var lastFire = Date(timeIntervalSince1970: 0)
    private static let minInterval: TimeInterval = 0.08

    private static func guardFire() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= minInterval else { return false }
        lastFire = now
        return true
    }

    static func tap() { guard guardFire() else { return }; impactHeavy.prepare(); impactHeavy.impactOccurred() }
    static func light() { guard guardFire() else { return }; impactLight.prepare(); impactLight.impactOccurred() }
    static func selection() { guard guardFire() else { return }; selectionGen.prepare(); selectionGen.selectionChanged() }
    static func success() { guard guardFire() else { return }; notifyGen.prepare(); notifyGen.notificationOccurred(.success) }
    static func warning() { guard guardFire() else { return }; notifyGen.prepare(); notifyGen.notificationOccurred(.warning) }
    static func error() { guard guardFire() else { return }; notifyGen.prepare(); notifyGen.notificationOccurred(.error) }
}

// MARK: - One-shot location helper

private final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var callback: ((CLAuthorizationStatus, CLLocation?) -> Void)?

    func request(_ callback: @escaping (CLAuthorizationStatus, CLLocation?) -> Void) {
        self.callback = callback
        manager.delegate = self
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            callback?(manager.authorizationStatus, nil)
            callback = nil
        case .notDetermined:
            break
        @unknown default:
            callback?(manager.authorizationStatus, nil); callback = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        callback?(manager.authorizationStatus, locations.last)
        callback = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        callback?(manager.authorizationStatus, nil)
        callback = nil
    }
}

#Preview {
    let container = LiveAppDI()
    HomeView(dependencies: container)
        .environmentObject(AppCoordinator(dependencies: container))
}
