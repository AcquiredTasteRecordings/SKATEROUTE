// Features/Settings/DiagnosticsView.swift
// Runtime diagnostics dashboard for power users and QA.
// - Pulls metrics from Services/Crash/MetricKitService, CacheManager, OfflineHealthCheck.
// - Surfaces last 24h GPS accuracy (median), battery burn (/hr while navigating), app hangs, thermal events.
// - Shows cache and offline tile stats; provides repair actions (health check, evict LRU, clear temp).
// - Exposes a redacted log export for bug reports (via Support/Feedback/Redactor).
// - A11y: ≥44pt targets, Dynamic Type safe, clear labels. Zero tracking; purpose-labeled Analytics only.

import SwiftUI
import Combine
import UIKit

// MARK: - Domain adapters

public struct GPSDiagnostics: Equatable, Sendable {
    public let samples: Int
    public let medianDriftMeters: Double
    public let p95DriftMeters: Double
    public let worstMeters: Double
    public let lastSampleAt: Date?
    public init(samples: Int, medianDriftMeters: Double, p95DriftMeters: Double, worstMeters: Double, lastSampleAt: Date?) {
        self.samples = samples; self.medianDriftMeters = medianDriftMeters; self.p95DriftMeters = p95DriftMeters; self.worstMeters = worstMeters; self.lastSampleAt = lastSampleAt
    }
}

public struct BatteryDiagnostics: Equatable, Sendable {
    public let avgBurnPerHourNav: Double   // %/hr while navigating
    public let avgBurnPerHourIdle: Double  // %/hr idle
    public let lastWindowHours: Int        // averaging window
    public init(avgBurnPerHourNav: Double, avgBurnPerHourIdle: Double, lastWindowHours: Int) {
        self.avgBurnPerHourNav = avgBurnPerHourNav; self.avgBurnPerHourIdle = avgBurnPerHourIdle; self.lastWindowHours = lastWindowHours
    }
}

public struct AppEventsDiagnostics: Equatable, Sendable {
    public let hangs: Int
    public let crashes: Int
    public let thermalWarnings: Int
    public let routingSignpostMsP95: Double   // P95 for “routing” signpost duration
    public let overlaySignpostMsP95: Double   // P95 for “overlay” signpost
    public init(hangs: Int, crashes: Int, thermalWarnings: Int, routingSignpostMsP95: Double, overlaySignpostMsP95: Double) {
        self.hangs = hangs; self.crashes = crashes; self.thermalWarnings = thermalWarnings
        self.routingSignpostMsP95 = routingSignpostMsP95; self.overlaySignpostMsP95 = overlaySignpostMsP95
    }
}

public struct CacheDiagnostics: Equatable, Sendable {
    public let diskBytes: Int64
    public let tileCount: Int
    public let hitRate: Double         // 0…1
    public let lastEvictionAt: Date?
    public init(diskBytes: Int64, tileCount: Int, hitRate: Double, lastEvictionAt: Date?) {
        self.diskBytes = diskBytes; self.tileCount = tileCount; self.hitRate = hitRate; self.lastEvictionAt = lastEvictionAt
    }
}

public protocol MetricKitReading: AnyObject {
    var gpsPublisher: AnyPublisher<GPSDiagnostics, Never> { get }
    var batteryPublisher: AnyPublisher<BatteryDiagnostics, Never> { get }
    var appEventsPublisher: AnyPublisher<AppEventsDiagnostics, Never> { get }
    func refresh() async
    func exportRedactedLog() async throws -> URL // uses Support/Feedback/Redactor internally
}

public protocol CacheInspecting: AnyObject {
    var cachePublisher: AnyPublisher<CacheDiagnostics, Never> { get }
    func clearCaches() async throws
}

public protocol OfflineHealthChecking: AnyObject {
    func runHealthCheck() async throws -> String  // human-readable summary of actions taken
    func evictLRUIfNeeded() async throws -> String
    func repairCorruptSegments() async throws -> String
}

// MARK: - ViewModel

@MainActor
public final class DiagnosticsViewModel: ObservableObject {
    @Published public private(set) var gps: GPSDiagnostics = .init(samples: 0, medianDriftMeters: 0, p95DriftMeters: 0, worstMeters: 0, lastSampleAt: nil)
    @Published public private(set) var battery: BatteryDiagnostics = .init(avgBurnPerHourNav: 0, avgBurnPerHourIdle: 0, lastWindowHours: 0)
    @Published public private(set) var appEvents: AppEventsDiagnostics = .init(hangs: 0, crashes: 0, thermalWarnings: 0, routingSignpostMsP95: 0, overlaySignpostMsP95: 0)
    @Published public private(set) var cache: CacheDiagnostics = .init(diskBytes: 0, tileCount: 0, hitRate: 0, lastEvictionAt: nil)

    @Published public var busy = false
    @Published public var infoMessage: String?
    @Published public var errorMessage: String?
    @Published public var shareURL: URL?

    private let metrics: MetricKitReading
    private let cacheMgr: CacheInspecting
    private let health: OfflineHealthChecking
    private let analytics: AnalyticsLogging?
    private var cancellables = Set<AnyCancellable>()

    public init(metrics: MetricKitReading, cache: CacheInspecting, health: OfflineHealthChecking, analytics: AnalyticsLogging?) {
        self.metrics = metrics
        self.cacheMgr = cache
        self.health = health
        self.analytics = analytics
        bind()
    }

    private func bind() {
        metrics.gpsPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$gps)
        metrics.batteryPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$battery)
        metrics.appEventsPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$appEvents)
        cacheMgr.cachePublisher
            .receive(on: RunLoop.main)
            .assign(to: &$cache)
    }

    public func refresh() {
        Task { await metrics.refresh() }
    }

    public func runHealthCheck() {
        busy = true
        Task {
            do {
                let summary = try await health.runHealthCheck()
                infoMessage = summary
                analytics?.log(.init(name: "offline_health_check", category: .diagnostics, params: [:]))
            } catch {
                errorMessage = NSLocalizedString("Health check failed.", comment: "health fail")
            }
            busy = false
        }
    }

    public func evictLRU() {
        busy = true
        Task {
            do {
                let summary = try await health.evictLRUIfNeeded()
                infoMessage = summary
            } catch {
                errorMessage = NSLocalizedString("Eviction failed.", comment: "evict fail")
            }
            busy = false
        }
    }

    public func repairSegments() {
        busy = true
        Task {
            do {
                let summary = try await health.repairCorruptSegments()
                infoMessage = summary
            } catch {
                errorMessage = NSLocalizedString("Repair failed.", comment: "repair fail")
            }
            busy = false
        }
    }

    public func clearCaches() {
        busy = true
        Task {
            do {
                try await cacheMgr.clearCaches()
                infoMessage = NSLocalizedString("Caches cleared.", comment: "cache ok")
            } catch {
                errorMessage = NSLocalizedString("Couldn’t clear caches.", comment: "cache fail")
            }
            busy = false
        }
    }

    public func exportDiagnostics() {
        busy = true
        Task {
            do {
                let url = try await metrics.exportRedactedLog()
                shareURL = url
                infoMessage = NSLocalizedString("Diagnostics ready.", comment: "export ok")
                analytics?.log(.init(name: "diagnostics_export", category: .diagnostics, params: [:]))
            } catch {
                errorMessage = NSLocalizedString("Export failed.", comment: "export fail")
            }
            busy = false
        }
    }

    // MARK: - Formatting

    public func pct(_ x: Double) -> String {
        String(format: "%.0f%%", x * 100)
    }
    public func burn(_ x: Double) -> String {
        String(format: "%.1f%%/h", x)
    }
    public func meters(_ x: Double) -> String {
        if x < 1000 { return String(format: "%.0f m", x) }
        return String(format: "%.1f km", x/1000.0)
    }
    public func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    public func dateStr(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - View

public struct DiagnosticsView: View {
    @ObservedObject private var vm: DiagnosticsViewModel
    @State private var showingShare = false

    public init(viewModel: DiagnosticsViewModel) { self.vm = viewModel }

    public var body: some View {
        List {
            gpsSection
            batterySection
            eventsSection
            cacheSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Diagnostics", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: vm.refresh) {
                    Image(systemName: "arrow.clockwise").imageScale(.medium)
                }
                .accessibilityLabel(Text(NSLocalizedString("Refresh", comment: "refresh")))
            }
        }
        .overlay(banner, alignment: .bottom)
        .sheet(isPresented: $showingShare) {
            if let url = vm.shareURL { ShareSheet(activityItems: [url]) }
        }
        .onChange(of: vm.shareURL) { showingShare = ($0 != nil) }
        .accessibilityIdentifier("diagnostics_root")
    }

    // MARK: Sections

    private var gpsSection: some View {
        Section(header: header(NSLocalizedString("GPS accuracy (last 24h)", comment: "gps"))) {
            Row(label: NSLocalizedString("Samples", comment: "samples"), value: "\(vm.gps.samples)")
            Row(label: NSLocalizedString("Median drift", comment: "median"), value: vm.meters(vm.gps.medianDriftMeters))
            Row(label: NSLocalizedString("P95 drift", comment: "p95"), value: vm.meters(vm.gps.p95DriftMeters))
            Row(label: NSLocalizedString("Worst", comment: "worst"), value: vm.meters(vm.gps.worstMeters))
            Row(label: NSLocalizedString("Last sample", comment: "last"), value: vm.dateStr(vm.gps.lastSampleAt))
            BudgetStatusRow(
                label: NSLocalizedString("Budget", comment: "budget"),
                value: vm.gps.medianDriftMeters <= 8 ? NSLocalizedString("≤8 m ✅", comment: "ok") : NSLocalizedString(">8 m ⚠️", comment: "warn"),
                ok: vm.gps.medianDriftMeters <= 8
            )
        }
    }

    private var batterySection: some View {
        Section(header: header(NSLocalizedString("Battery", comment: "battery")),
                footer: Text(String(format: NSLocalizedString("Averaged over last %d h", comment: "avg window"), vm.battery.lastWindowHours)).font(.footnote)) {
            Row(label: NSLocalizedString("Nav burn", comment: "nav burn"), value: vm.burn(vm.battery.avgBurnPerHourNav))
            Row(label: NSLocalizedString("Idle burn", comment: "idle burn"), value: vm.burn(vm.battery.avgBurnPerHourIdle))
            BudgetStatusRow(
                label: NSLocalizedString("Budget", comment: "budget"),
                value: vm.battery.avgBurnPerHourNav <= 8 ? NSLocalizedString("≤8%/h ✅", comment: "ok") : NSLocalizedString(">8%/h ⚠️", comment: "warn"),
                ok: vm.battery.avgBurnPerHourNav <= 8
            )
        }
    }

    private var eventsSection: some View {
        Section(header: header(NSLocalizedString("App events", comment: "events"))) {
            Row(label: NSLocalizedString("Crashes", comment: "crashes"), value: "\(vm.appEvents.crashes)")
            Row(label: NSLocalizedString("Hangs", comment: "hangs"), value: "\(vm.appEvents.hangs)")
            Row(label: NSLocalizedString("Thermal warnings", comment: "thermal"), value: "\(vm.appEvents.thermalWarnings)")
            Row(label: NSLocalizedString("Routing P95", comment: "routing p95"), value: String(format: "%.0f ms", vm.appEvents.routingSignpostMsP95))
            Row(label: NSLocalizedString("Overlay P95", comment: "overlay p95"), value: String(format: "%.0f ms", vm.appEvents.overlaySignpostMsP95))
            BudgetStatusRow(
                label: NSLocalizedString("Reroute freeze", comment: "reroute"),
                value: vm.appEvents.routingSignpostMsP95 <= 100 ? NSLocalizedString("<100 ms ✅", comment: "ok") : NSLocalizedString(">100 ms ⚠️", comment: "warn"),
                ok: vm.appEvents.routingSignpostMsP95 <= 100
            )
        }
    }

    private var cacheSection: some View {
        Section(header: header(NSLocalizedString("Cache & offline", comment: "cache"))) {
            Row(label: NSLocalizedString("Disk", comment: "disk"), value: vm.bytes(vm.cache.diskBytes))
            Row(label: NSLocalizedString("Tiles", comment: "tiles"), value: "\(vm.cache.tileCount)")
            Row(label: NSLocalizedString("Hit rate", comment: "hit"), value: vm.pct(vm.cache.hitRate))
            Row(label: NSLocalizedString("Last eviction", comment: "evict"), value: vm.dateStr(vm.cache.lastEvictionAt))

            HStack(spacing: 8) {
                Button(action: vm.runHealthCheck) { Label(NSLocalizedString("Run health check", comment: "health"), systemImage: "stethoscope") }
                    .buttonStyle(.borderedProminent)
                Button(action: vm.evictLRU) { Label(NSLocalizedString("Evict LRU", comment: "evict"), systemImage: "externaldrive.badge.minus") }
                    .buttonStyle(.bordered)
                Button(action: vm.repairSegments) { Label(NSLocalizedString("Repair", comment: "repair"), systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(.bordered)
            }
            .frame(minHeight: 44)
            .disabled(vm.busy)
            .accessibilityIdentifier("cache_actions")

            Button(role: .destructive, action: vm.clearCaches) {
                Label(NSLocalizedString("Clear caches", comment: "clear"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .disabled(vm.busy)
            .accessibilityIdentifier("clear_caches")
        }
    }

    private var actionsSection: some View {
        Section(header: header(NSLocalizedString("Support", comment: "support")),
                footer: Text(NSLocalizedString("Exported diagnostics redact personal data. Attach to bug reports only.", comment: "redact")).font(.footnote)) {
            Button(action: vm.exportDiagnostics) {
                Label(NSLocalizedString("Export diagnostics", comment: "export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(vm.busy)
            .accessibilityIdentifier("export_diag")
        }
    }

    // MARK: - UI atoms

    private func header(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
        }.accessibilityHidden(true)
    }

    private var banner: some View {
        VStack {
            if vm.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("Working…", comment: "busy"))
                        .font(.callout)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(.ultraThinMaterial, in: Capsule())
            } else if let e = vm.errorMessage {
                toast(text: e, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.bottom, 12).padding(.horizontal, 16)
        .animation(.easeInOut, value: vm.busy || vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 10) {
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
}

fileprivate struct Row: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label) \(value)"))
    }
}

fileprivate struct BudgetStatusRow: View {
    let label: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((ok ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                .foregroundColor(ok ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label) \(value)"))
    }
}

// MARK: - ShareSheet

fileprivate struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - DEBUG fakes

#if DEBUG
final class MetricsFake: MetricKitReading {
    let gpsS = CurrentValueSubject<GPSDiagnostics, Never>(.init(samples: 420, medianDriftMeters: 6.2, p95DriftMeters: 12.8, worstMeters: 28.0, lastSampleAt: Date().addingTimeInterval(-120)))
    let batS = CurrentValueSubject<BatteryDiagnostics, Never>(.init(avgBurnPerHourNav: 6.7, avgBurnPerHourIdle: 1.2, lastWindowHours: 24))
    let appS = CurrentValueSubject<AppEventsDiagnostics, Never>(.init(hangs: 0, crashes: 0, thermalWarnings: 1, routingSignpostMsP95: 82, overlaySignpostMsP95: 45))
    var gpsPublisher: AnyPublisher<GPSDiagnostics, Never> { gpsS.eraseToAnyPublisher() }
    var batteryPublisher: AnyPublisher<BatteryDiagnostics, Never> { batS.eraseToAnyPublisher() }
    var appEventsPublisher: AnyPublisher<AppEventsDiagnostics, Never> { appS.eraseToAnyPublisher() }
    func refresh() async { }
    func exportRedactedLog() async throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diagnostics.txt")
        try "redacted".data(using: .utf8)!.write(to: tmp); return tmp
    }
}
final class CacheFake: CacheInspecting {
    let s = CurrentValueSubject<CacheDiagnostics, Never>(.init(diskBytes: 180*1024*1024, tileCount: 1280, hitRate: 0.83, lastEvictionAt: Date().addingTimeInterval(-3600)))
    var cachePublisher: AnyPublisher<CacheDiagnostics, Never> { s.eraseToAnyPublisher() }
    func clearCaches() async throws { }
}
final class HealthFake: OfflineHealthChecking {
    func runHealthCheck() async throws -> String { "Health check OK: 0 repairs, 0 fetches." }
    func evictLRUIfNeeded() async throws -> String { "Evicted 120 tiles (75 MB)." }
    func repairCorruptSegments() async throws -> String { "Repaired 2 segments." }
}
struct DiagnosticsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            DiagnosticsView(viewModel: .init(metrics: MetricsFake(), cache: CacheFake(), health: HealthFake(), analytics: nil))
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire MetricKitReading to Services/Crash/MetricKitService publishers:
//   - gpsPublisher aggregates CoreLocation sample errors (vs. snapped route) → median/p95/worst across 24h window.
//   - batteryPublisher computes %/hr using MXPowerMetrics while marking “navigating” sessions via signposts.
//   - appEventsPublisher surfaces crash/hang/thermal counts and P95 for routing/overlay signposts.
// • CacheInspecting should read from CacheManager (bytes on disk, tile count, hit rate, last eviction).
// • OfflineHealthChecking is backed by Services/Offline/OfflineHealthCheck and orchestrates manifest validation,
//   LRU eviction, and corrupt segment repair. Return user-readable summaries for the banner.
// • Analytics: purpose-labeled ‘diagnostics’ category; absolutely no PII.
// • UITests: assert identifiers “diagnostics_root”, “cache_actions”, “clear_caches”; trigger health check → green banner.
// • Budgets: explicitly show budget badges (≤8 m drift; ≤8%/h nav; <100 ms reroute P95) aligned with product goals.


