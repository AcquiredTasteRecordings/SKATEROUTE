// Features/Settings/SettingsView.swift
// Units, defaults, privacy controls, and data export.
// - Powers users with obvious, ethical controls. No dark patterns.
// - Units: Metric / Imperial. Surface/grade colors legend toggle is here too.
// - Defaults: start with voice guidance ON, haptics cadence, auto-pause on stop.
// - Privacy: hide city/routes (reads/writes UserProfileStore), analytics sampling opt-out.
// - Data export: GPX + GeoJSON of your rides via Services/Export/GPXExporter.
// - A11y: ≥44pt targets, clear labels, Dynamic Type safe.
// - No tracking; analytics calls (optional) are purpose-labeled and PII-free.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

// MARK: - Domain adapters

public enum UnitsSetting: String, CaseIterable, Sendable, Identifiable {
    case metric, imperial
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .metric: return NSLocalizedString("Metric (km, m)", comment: "units")
        case .imperial: return NSLocalizedString("Imperial (mi, ft)", comment: "units")
        }
    }
}

public protocol SettingsPersisting: AnyObject {
    var units: UnitsSetting { get set }
    var voiceGuidanceEnabled: Bool { get set }
    var hapticsEnabled: Bool { get set }
    var autoPauseEnabled: Bool { get set }
    var showSurfaceLegend: Bool { get set }
    var analyticsEnabled: Bool { get set }  // default true, user may opt out
}

public protocol ProfilePrivacyEditing: AnyObject {
    var hideCity: Bool { get async }
    var hideRoutes: Bool { get async }
    func setHideCity(_ on: Bool) async
    func setHideRoutes(_ on: Bool) async
}

// MARK: - ViewModel

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var units: UnitsSetting
    @Published public var voiceGuidanceEnabled: Bool
    @Published public var hapticsEnabled: Bool
    @Published public var autoPauseEnabled: Bool
    @Published public var showSurfaceLegend: Bool
    @Published public var analyticsEnabled: Bool

    @Published public var hideCity: Bool = false
    @Published public var hideRoutes: Bool = false

    @Published public var exporting = false
    @Published public var exportError: String?
    @Published public var infoMessage: String?
    @Published public var exportURL: URL? // for ShareSheet

    private let store: SettingsPersisting
    private let privacy: ProfilePrivacyEditing
    private let exporter: GPXExporting
    private let analytics: AnalyticsLogging?

    public init(store: SettingsPersisting,
                privacy: ProfilePrivacyEditing,
                exporter: GPXExporting,
                analytics: AnalyticsLogging?) {
        self.store = store
        self.privacy = privacy
        self.exporter = exporter
        self.analytics = analytics

        self.units = store.units
        self.voiceGuidanceEnabled = store.voiceGuidanceEnabled
        self.hapticsEnabled = store.hapticsEnabled
        self.autoPauseEnabled = store.autoPauseEnabled
        self.showSurfaceLegend = store.showSurfaceLegend
        self.analyticsEnabled = store.analyticsEnabled

        Task { await hydratePrivacy() }
    }

    private func hydratePrivacy() async {
        hideCity = await privacy.hideCity
        hideRoutes = await privacy.hideRoutes
    }

    // MARK: - Mutations

    public func setUnits(_ new: UnitsSetting) {
        units = new
        store.units = new
        analytics?.log(.init(name: "units_set", category: .settings, params: ["units": .string(new.rawValue)]))
    }

    public func setVoice(_ on: Bool) {
        voiceGuidanceEnabled = on
        store.voiceGuidanceEnabled = on
    }

    public func setHaptics(_ on: Bool) {
        hapticsEnabled = on
        store.hapticsEnabled = on
    }

    public func setAutoPause(_ on: Bool) {
        autoPauseEnabled = on
        store.autoPauseEnabled = on
    }

    public func setLegend(_ on: Bool) {
        showSurfaceLegend = on
        store.showSurfaceLegend = on
    }

    public func setAnalytics(_ on: Bool) {
        analyticsEnabled = on
        store.analyticsEnabled = on
        infoMessage = on
        ? NSLocalizedString("Thanks for helping us improve the app.", comment: "analytics on")
        : NSLocalizedString("Analytics disabled. Only essential diagnostics remain.", comment: "analytics off")
    }

    public func setHideCity(_ on: Bool) {
        Task {
            hideCity = on
            await privacy.setHideCity(on)
            infoMessage = on
            ? NSLocalizedString("Your city is hidden in public views.", comment: "hide city on")
            : NSLocalizedString("Your city may appear in leaderboards.", comment: "hide city off")
        }
    }

    public func setHideRoutes(_ on: Bool) {
        Task {
            hideRoutes = on
            await privacy.setHideRoutes(on)
            infoMessage = on
            ? NSLocalizedString("Your saved routes are hidden from your public profile.", comment: "hide routes on")
            : NSLocalizedString("Your saved routes may be visible on your public profile.", comment: "hide routes off")
        }
    }

    // MARK: - Export

    public func export(format: String, fuzzMeters: Double) {
        exporting = true
        exportError = nil
        exportURL = nil
        analytics?.log(.init(name: "export_start", category: .settings, params: ["format": .string(format)]))
        Task {
            do {
                let url = try await exporter.exportAll(format: format, redactionRadiusMeters: fuzzMeters)
                await MainActor.run {
                    exporting = false
                    exportURL = url
                    infoMessage = String(format: NSLocalizedString("%@ export ready.", comment: "export ok"), format.uppercased())
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    exportError = NSLocalizedString("Couldn’t export your rides. Try again later.", comment: "export fail")
                }
            }
        }
    }

    // MARK: - System settings

    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - View

public struct SettingsView: View {
    @ObservedObject private var vm: SettingsViewModel
    @State private var fuzzRadius: Double = 80 // meters; used for export redaction
    @State private var showingShare = false

    public init(viewModel: SettingsViewModel) { self.vm = viewModel }

    public var body: some View {
        List {
            unitsSection
            defaultsSection
            privacySection
            exportSection
            systemSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Settings", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShare) { shareSheet }
        .overlay(toasts)
        .accessibilityIdentifier("settings_root")
        .onChange(of: vm.exportURL) { url in showingShare = (url != nil) }
    }

    // MARK: - Sections

    private var unitsSection: some View {
        Section(header: header("Units")) {
            Picker(selection: Binding(get: { vm.units }, set: vm.setUnits)) {
                ForEach(UnitsSetting.allCases) { u in
                    Text(u.label).tag(u)
                }
            } label: { Text(NSLocalizedString("Measurement units", comment: "units")) }
            .accessibilityIdentifier("units_picker")
        }
    }

    private var defaultsSection: some View {
        Section(header: header(NSLocalizedString("Defaults", comment: "defaults"))) {
            Toggle(isOn: Binding(get: { vm.voiceGuidanceEnabled }, set: vm.setVoice)) {
                Label(NSLocalizedString("Voice guidance", comment: "voice"), systemImage: "speaker.wave.2.fill")
            }
            .accessibilityIdentifier("voice_toggle")

            Toggle(isOn: Binding(get: { vm.hapticsEnabled }, set: vm.setHaptics)) {
                Label(NSLocalizedString("Haptics", comment: "haptics"), systemImage: "iphone.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("haptics_toggle")

            Toggle(isOn: Binding(get: { vm.autoPauseEnabled }, set: vm.setAutoPause)) {
                Label(NSLocalizedString("Auto-pause on stop", comment: "autopause"), systemImage: "pause.circle.fill")
            }
            .accessibilityIdentifier("autopause_toggle")

            Toggle(isOn: Binding(get: { vm.showSurfaceLegend }, set: vm.setLegend)) {
                Label(NSLocalizedString("Show surface legend on map", comment: "legend"), systemImage: "map")
            }
            .accessibilityIdentifier("legend_toggle")
        }
    }

    private var privacySection: some View {
        Section(header: header(NSLocalizedString("Privacy", comment: "privacy")),
                footer: Text(NSLocalizedString("We don’t track you. These options control what others see. Leaderboards use coarse city codes only.", comment: "privacy foot")).font(.footnote)) {
            Toggle(isOn: Binding(get: { vm.analyticsEnabled }, set: vm.setAnalytics)) {
                Label(NSLocalizedString("Share anonymous analytics", comment: "analytics"), systemImage: "chart.xyaxis.line")
            }
            .accessibilityIdentifier("analytics_toggle")

            Toggle(isOn: Binding(get: { vm.hideCity }, set: vm.setHideCity)) {
                Label(NSLocalizedString("Hide my city in public", comment: "hide city"), systemImage: "building.2.slash")
            }
            .accessibilityIdentifier("hide_city_toggle")

            Toggle(isOn: Binding(get: { vm.hideRoutes }, set: vm.setHideRoutes)) {
                Label(NSLocalizedString("Hide my saved routes", comment: "hide routes"), systemImage: "map.slash")
            }
            .accessibilityIdentifier("hide_routes_toggle")
        }
    }

    private var exportSection: some View {
        Section(header: header(NSLocalizedString("Data export", comment: "export")),
                footer: Text(NSLocalizedString("Your exports fuzz home and frequent starts by the radius below. Files are saved temporarily for sharing.", comment: "export foot")).font(.footnote)) {

            HStack {
                Label(NSLocalizedString("Home fuzz radius", comment: "fuzz"), systemImage: "lock.shield")
                Spacer()
                Text("\(Int(fuzzRadius)) m").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }

            Slider(value: $fuzzRadius, in: 0...300, step: 10)
                .accessibilityLabel(Text(NSLocalizedString("Fuzz radius meters", comment: "fuzz ax")))
                .accessibilityIdentifier("fuzz_slider")

            Button {
                vm.export(format: "gpx", fuzzMeters: fuzzRadius)
            } label: {
                Label(NSLocalizedString("Export GPX", comment: "gpx"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(vm.exporting)
            .accessibilityIdentifier("export_gpx")

            Button {
                vm.export(format: "geojson", fuzzMeters: fuzzRadius)
            } label: {
                Label(NSLocalizedString("Export GeoJSON", comment: "geojson"), systemImage: "square.and.arrow.up.on.square")
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .disabled(vm.exporting)
            .accessibilityIdentifier("export_geojson")

            if vm.exporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("Preparing export…", comment: "exporting"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var systemSection: some View {
        Section(header: header(NSLocalizedString("System", comment: "system"))) {
            Button {
                vm.openSystemSettings()
            } label: {
                Label(NSLocalizedString("Open iOS Settings", comment: "open settings"), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("open_settings")
       
            Section(header: header(NSLocalizedString("Legal", comment: "legal"))) {
                NavigationLink {
                    LegalListView()
            } label: {
                Label(NSLocalizedString("Privacy & Terms", comment: "legal link"), systemImage: "doc.text")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(NSLocalizedString("Version", comment: "version"))
                Spacer()
                Text(appVersion()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            header(NSLocalizedString("About", comment: "about"))
        }
    }

    // MARK: - Share

    @ViewBuilder
    private var shareSheet: some View {
        if let url = vm.exportURL {
            ShareSheet(activityItems: [url])
                .ignoresSafeArea()
                .presentationDetents([.medium])
                .onDisappear { vm.exportURL = nil }
        }
    }

    // MARK: - UI helpers

    private func header(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
        }.accessibilityHidden(true)
    }

    @ViewBuilder
    private var toasts: some View {
        VStack {
            Spacer()
            if let e = vm.exportError {
                toast(text: e, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.exportError = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.exportError != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

// MARK: - ShareSheet UIKit bridge

fileprivate struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - DEBUG fakes

#if DEBUG
final class SettingsStoreFake: SettingsPersisting {
    var units: UnitsSetting = .metric
    var voiceGuidanceEnabled: Bool = true
    var hapticsEnabled: Bool = true
    var autoPauseEnabled: Bool = true
    var showSurfaceLegend: Bool = true
    var analyticsEnabled: Bool = true
}
final class PrivacyFake: ProfilePrivacyEditing {
    private var _hideCity = false
    private var _hideRoutes = false
    var hideCity: Bool { get async { _hideCity } }
    var hideRoutes: Bool { get async { _hideRoutes } }
    func setHideCity(_ on: Bool) async { _hideCity = on }
    func setHideRoutes(_ on: Bool) async { _hideRoutes = on }
}
final class ExporterFake: GPXExporting {
    func exportAll(format: String, redactionRadiusMeters: Double) async throws -> URL {
        // Write a tiny temp file for sharing
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rides.\(format)")
        try "demo".data(using: .utf8)?.write(to: tmp)
        return tmp
    }
}
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView(viewModel: .init(store: SettingsStoreFake(),
                                          privacy: PrivacyFake(),
                                          exporter: ExporterFake(),
                                          analytics: nil))
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `SettingsPersisting` to a small UserDefaults wrapper (namespaced keys). Keep defaults:
//   - units = .metric, voiceGuidanceEnabled = true, hapticsEnabled = true, autoPauseEnabled = true, showSurfaceLegend = true, analyticsEnabled = true.
// • Connect `ProfilePrivacyEditing` to Services/Profile/UserProfileStore update(_:): map toggles to hideCity/hideRoutes (async safe).
// • Hook `GPXExporting` to Services/Export/GPXExporter:
//   - Implement GPXExporter.exportAll(format:redactionRadiusMeters:) by reading SessionLogger NDJSON,
//     applying home fuzzing, and writing to a temp file with appropriate UTType (gpx / json).
// • Respect PaywallRules: export is available to everyone (ethical data portability).
// • UITests:
//   - Toggle voice/haptics/legend and assert persistence across app relaunch (via SettingsStoreFake).
//   - Export GPX/GeoJSON shows progress → ShareSheet; failing exporter surfaces red toast.
//   - Privacy toggles flip labels and call ProfilePrivacyEditing setters; verify by spy.
// • Accessibility: identifiers “settings_root”, “units_picker”, “export_gpx”, “export_geojson”, “open_settings”.


