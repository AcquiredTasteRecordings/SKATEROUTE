// Features/Home/HomeView.swift
import AVFoundation
import CoreLocation
import MapKit
import AVFoundation
import SwiftUI

/// The main view for the home screen of the SkateRoute app.
/// Displays the logo, tagline, primary actions, and footer stats with custom styling and animations.
struct HomeView: View {
    private let dependencies: any AppDependencyContainer

    @State private var isSearching = false
    @State private var showStats = false
    @State private var asphaltOffset: CGFloat = 0

    @EnvironmentObject private var coordinator: AppCoordinator

    // Timer for parallax asphalt animation
    private let timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    

    // System sound ID for soft whoosh
    private let whooshSoundID: SystemSoundID = 1104
    

    init(dependencies: any AppDependencyContainer) {
        self.dependencies = dependencies
    }

    var body: some View {
        ZStack {
            // Matte grip-tape black background
            Color.black.ignoresSafeArea()

            // Asphalt / grunge overlay with subtle parallax effect for depth
            Image("AsphaltTexture")
                .resizable()
                .scaledToFill()
                .opacity(0.16)
                .blendMode(.overlay)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .offset(x: asphaltOffset)
                .onReceive(timer) { _ in
                    // Animate horizontal offset for subtle parallax effect
                    withAnimation(.linear(duration: 0.02)) {
                        asphaltOffset = (asphaltOffset > 10) ? -10 : asphaltOffset + 0.2
                    }
                }

            VStack(spacing: 28) {
                // Logo + animated skateboard-inspired gradient glow + shimmering tagline
                VStack(spacing: 14) {
                    ZStack {
                        // Animated gradient glow behind logo
                        AnimatedGradientGlow()
                            .frame(width: 280, height: 280)
                            .clipShape(Circle())
                            .blur(radius: 30)
                            .opacity(0.7)
                            .accessibilityHidden(true)

                        LogoLockup()
                            .padding(.top, 54)
                    }
                    
                    ShimmeringText("All Downhill From Here")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .kerning(0.5)
                        .accessibilityLabel("Tagline: All Downhill From Here")
                }
                .padding(.horizontal, 24)
                
                // Primary actions: Find Smooth Line, Drop a Spot, and Session Stats
                VStack(spacing: 14) {
                    Button {
                        Haptic.tap()
                        AudioServicesPlaySystemSound(whooshSoundID) // Play soft whoosh sound
                        isSearching = true
                    } label: {
                        Text("Find Smooth Line")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white)
                            )
                    }
                    .accessibilityLabel("Find Smooth Line button")
                    
                    Button {
                        Haptic.light()
                        // TODO: Hook to quick-spot capture or a sheet
                    } label: {
                        Text("Drop a Spot")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                            )
                    }
                    .accessibilityLabel("Drop a Spot button")
                    
                    Button {
                        Haptic.light()
                        showStats = true
                    } label: {
                        Text("Session Stats")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Session Stats button")
                    .sheet(isPresented: $showStats) {
                        // Placeholder for future StatsView
                        Text("Stats View Coming Soon")
                            .font(.title)
                            .foregroundColor(.white)
                            .background(Color.black.ignoresSafeArea())
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Minimal footer stats (white on black)
                FooterStats()
                    .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $isSearching) {
            PlaceSearchView(
                title: "Find a Spot",
                region: nil,
                showUseCurrentLocation: true,
                currentLocationProvider: {
                    dependencies.locationManager.currentLocation?.coordinate
                },
                onPick: { place in
                    RouteMode.smoothest)
                    let destination = place.placemark.coordinate
                    let source = dependencies.locationManager.currentLocation?.coordinate ?? destination
                    coordinator.presentMap(from: source, to: destination, mode: .smoothest)
                    isSearching = false
                }
            )
        }
    }
}

// MARK: - Supporting Views

/// A view modifier that applies a shimmering animation effect to text.
private struct ShimmeringText: View {
    let text: String
    @State private var phase: CGFloat = 0
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
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

/// A view that displays an animated skateboard-inspired gradient glow.
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
        .onAppear {
            animateGradient = true
        }
    }
}

// MARK: - Components

/// Displays the SkateRoute logo with shadow and accessibility label.
private struct LogoLockup: View {
    var body: some View {
        Image("SkateRouteLogo") // already in Assets
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
            .accessibilityLabel("SkateRoute — All Downhill From Here")
    }
}

/// Displays footer statistics such as KM, Spots, and Badges.
private struct FooterStats: View {
    var body: some View {
        HStack(spacing: 14) {
            StatTile(title: "KM", value: "0.0")
            StatTile(title: "Spots", value: "0")
            StatTile(title: "Badges", value: "0")
        }
        .padding(.horizontal, 20)
    }
}

/// A single stat tile with a title and a value.
private struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.heavy))
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Haptics

/// Provides haptic feedback for user interactions.
enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

#Preview {
    let container = LiveAppDI()
    HomeView(dependencies: container)
        .environmentObject(AppCoordinator(dependencies: container))
}
