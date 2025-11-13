// Services/Crash/MetricKitService.swift
// MXMetricManager hooks + signposts around routing/overlay/recorder hot paths.
// Pulls diagnostics (crash, hang, battery, thermal), persists redacted summaries for DiagnosticsView,
// and pairs with our performance budgets to surface breaching signals in logs.
//
// Privacy: no PII, no coordinates, no user IDs. ATT-free.
//
// iOS 14+ for MetricKit. Safe to compile on older OSes (no-op guards).
// Integrates with AnalyticsLogger for structured OSLog + optional façade.

import Foundation
import Combine
import os.log
import MetricKit

// MARK: - Budgets (defaults match product goals)

public struct PerfBudgets: Equatable, Sendable {
    public var coldStartPlanMs: Int = 1200          // plan budget ≤ 1.2s
    public var rerouteFreezeMs: Int = 100           // reroute UI stall < 100ms
    public var gpsMedianDriftM: Double = 8.0        // median drift ≤ 8 m (tracked elsewhere; logged here)
    public var navBatteryPctPerHour: Double = 8.0   // ≤ 8%/hr during nav
    public init() {}
}

// MARK: - DI seam

public protocol MetricEventsSink {
    func onMetricsSummary(_ summary: MetricKitService.Summary)
    func onBudgetBreach(_ breach: MetricKitService.Breach)
}

// MARK: - Service

@MainActor
public final class MetricKitService: NSObject, ObservableObject {

    public enum State: Equatable { case idle, ready, error(String) }

    // Redacted & compact snapshot for DiagnosticsView
    public struct Summary: Codable, Equatable, Sendable {
        public let collectedAt: Date
        public let batteryDrainPctPerHour: Double?    // aggregated from MXSignpostMetrics / MXGPUMetrics
        public let cpuTimeSec: Double?
        public let hangCount: Int
        public let crashCount: Int
        public let thermalLevel: String?              // last seen (Nominal/Fair/Serious/Critical)
        public let appVersion: String
    }

    public enum Breach: Sendable, Equatable {
        case batteryOverBudget(actualPctPerHour: Double, budget: Double)
        case thermalSerious
        case hangDetected
        case crashDetected
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastSummary: Summary?

    public var summaryPublisher: AnyPublisher<Summary, Never> { summarySubject.eraseToAnyPublisher() }
    public var breachPublisher: AnyPublisher<Breach, Never> { breachSubject.eraseToAnyPublisher() }

    // DI
    private let analytics: AnalyticsLogging
    private let sink: MetricEventsSink?
    private let budgets: PerfBudgets

    // System
    private let mx = MXMetricManager.shared
    private let log = Logger(subsystem: "com.skateroute", category: "metrics")

    // Publish
    private let summarySubject = PassthroughSubject<Summary, Never>()
    private let breachSubject = PassthroughSubject<Breach, Never>()

    // Persist summaries for DiagnosticsView
    private let storeURL: URL
    private let fm = FileManager.default

    // Signpost handles for hot-path spans (mapped to AnalyticsLogger which already emits signposts)
    private var spanHandles: [String: AnalyticsSpanHandle] = [:]

    // MARK: Init

    public init(analytics: AnalyticsLogging,
                sink: MetricEventsSink? = nil,
                budgets: PerfBudgets = .init()) {
        self.analytics = analytics
        self.sink = sink
        self.budgets = budgets

        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Metrics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("last_summary.json")

        super.init()

        // Register for MetricKit payloads.
        if #available(iOS 14.0, *) {
            mx.add(self)
            state = .ready
        } else {
            state = .error("MetricKit unavailable")
        }

        // Load previous summary if any
        if let s = Self.loadSummary(from: storeURL) { lastSummary = s }
    }

    deinit {
        if #available(iOS 14.0, *) { mx.remove(self) }
    }

    // MARK: Public API — signpost helpers for hot paths

    public func routingStart(_ label: String = "route_plan") {
        let h = analytics.beginSpan(.init(label, category: .routing))
        spanHandles["routing:\(label)"] = h
    }

    public func routingEnd(_ label: String = "route_plan") {
        guard let h = spanHandles.removeValue(forKey: "routing:\(label)") else { return }
        analytics.endSpan(h)
    }

    public func rerouteFreezeStart() {
        let h = analytics.beginSpan(.init("reroute_freeze", category: .routing))
        spanHandles["reroute_freeze"] = h
    }

    public func rerouteFreezeEnd() {
        guard let h = spanHandles.removeValue(forKey: "reroute_freeze") else { return }
        analytics.endSpan(h)
    }

    public func overlayRenderStart(_ label: String = "overlay") {
        let h = analytics.beginSpan(.init(label, category: .overlay))
        spanHandles["overlay:\(label)"] = h
    }

    public func overlayRenderEnd(_ label: String = "overlay") {
        guard let h = spanHandles.removeValue(forKey: "overlay:\(label)") else { return }
        analytics.endSpan(h)
    }

    public func recorderStart() {
        let h = analytics.beginSpan(.init("recorder_session", category: .recorder))
        spanHandles["recorder"] = h
    }

    public func recorderEnd() {
        guard let h = spanHandles.removeValue(forKey: "recorder") else { return }
        analytics.endSpan(h)
    }

    // MARK: Manual pull (debug)

    /// Ask MetricKit to deliver any pending payloads now (debug / test hooks).
    public func requestImmediateMetricPayload() {
        if #available(iOS 14.0, *) {
            mx.makeLogHandle() // no-op but keeps linkage; deliveries are async by system cadence
        }
    }

    // MARK: Summaries

    private func publish(_ summary: Summary) {
        lastSummary = summary
        summarySubject.send(summary)
        sink?.onMetricsSummary(summary)
        Self.saveSummary(summary, to: storeURL)
        // Commerce-free analytics ping (sampler will gate volume)
        analytics.log(.init(name: "metric_summary",
                            category: .privacy,
                            params: ["battery_pct_per_hr": .double(summary.batteryDrainPctPerHour ?? -1),
                                     "hang_count": .int(summary.hangCount),
                                     "crash_count": .int(summary.crashCount),
                                     "thermal": .string(summary.thermalLevel ?? "unknown"),
                                     "duration_ms": .int(0)]))
    }

    private func emitBreach(_ breach: Breach) {
        breachSubject.send(breach)
        sink?.onBudgetBreach(breach)
        // Also log to OS
        switch breach {
        case .batteryOverBudget(let actual, let budget):
            log.notice("Battery over budget: \(actual, privacy: .public)%/hr > \(budget, privacy: .public)%/hr")
        case .thermalSerious:
            log.notice("Thermal state escalated to Serious/Critical")
        case .hangDetected:
            log.notice("Hang diagnostic received")
        case .crashDetected:
            log.notice("Crash diagnostic received")
        }
    }

    // MARK: Persistence helpers

    private static func saveSummary(_ s: Summary, to url: URL) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private static func loadSummary(from url: URL) -> Summary? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: d)
    }

    private func appVersion() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(ver)(\(build))"
    }
}

// MARK: - MXMetricManagerSubscriber

extension MetricKitService: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        guard #available(iOS 14.0, *) else { return }

        // Aggregate across payloads; MetricKit typically batches daily.
        var totalCPU: Double = 0
        var thermal: String?
        var drainPerHour: Double?

        for p in payloads {
            // CPU
            if let cpu = p.cpuMetrics?.cumulativeCPUTime {
                totalCPU += cpu.doubleValue
            }

            // Thermal state (grab last known string)
            if let th = p.thermalMetrics?.thermalStateHistogram?.histogramData?.last?.bucketStart {
                thermal = th.stringValue
            }

            // Battery drain %/hr
            if let battery = p.cellularConditionMetrics?.histogrammedCellularConditionTime {
                // Not a direct drain metric, but we can pair with appRunTime for coarse signal.
                // Prefer powerMetrics if available.
                _ = battery // kept for potential future weighting
            }
            if let power = p.powerMetrics?.totalApplicationWattHours {
                // Convert watt-hours into a rough %/hr using common battery capacities (guarded assumption).
                // We avoid device model; use a coarse 11.0 Wh iPhone battery assumption.
                let wh = power.doubleValue
                if let runtime = p.applicationTimeMetrics?.cumulativeForegroundTime {
                    let hours = max(0.001, runtime.doubleValue / 3600.0)
                    let pctPerHour = (wh / 11.0) * 100.0 / hours
                    drainPerHour = max(0, pctPerHour)
                }
            }
        }

        let summary = Summary(collectedAt: Date(),
                              batteryDrainPctPerHour: drainPerHour,
                              cpuTimeSec: totalCPU > 0 ? totalCPU : nil,
                              hangCount: 0,
                              crashCount: 0,
                              thermalLevel: thermal,
                              appVersion: appVersion())
        publish(summary)

        // Budgets
        if let d = drainPerHour, d > budgets.navBatteryPctPerHour { emitBreach(.batteryOverBudget(actualPctPerHour: d, budget: budgets.navBatteryPctPerHour)) }
        if let t = thermal, t.lowercased().contains("serious") || t.lowercased().contains("critical") { emitBreach(.thermalSerious) }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard #available(iOS 14.0, *) else { return }

        var crash = 0
        var hang = 0

        for p in payloads {
            crash += p.crashDiagnostics?.count ?? 0
            hang += p.hangDiagnostics?.count ?? 0
        }

        // Merge into last summary (lightweight)
        var s = lastSummary ?? Summary(collectedAt: Date(), batteryDrainPctPerHour: nil, cpuTimeSec: nil, hangCount: 0, crashCount: 0, thermalLevel: nil, appVersion: appVersion())
        s.collectedAt = Date()
        s.hangCount += hang
        s.crashCount += crash
        publish(s)

        if hang > 0 { emitBreach(.hangDetected) }
        if crash > 0 { emitBreach(.crashDetected) }
    }
}

// MARK: - Events used by AnalyticsLogger façade (minimal mirror)

// MARK: - DEBUG fakes (for tests)

#if DEBUG
public final class MetricSinkSpy: MetricEventsSink {
    public private(set) var summaries: [MetricKitService.Summary] = []
    public private(set) var breaches: [MetricKitService.Breach] = []
    public init() {}
    public func onMetricsSummary(_ summary: MetricKitService.Summary) { summaries.append(summary) }
    public func onBudgetBreach(_ breach: MetricKitService.Breach) { breaches.append(breach) }
}

public final class AnalyticsLoggerNoop: AnalyticsLogging {
    public init() {}
    public func log(_ event: AnalyticsEvent) {}
    public func updateConfig(_ config: Any) {}
    public func beginSpan(_ span: AnalyticsSpan) -> AnalyticsSpanHandle { AnalyticsSpanHandle() }
    public func endSpan(_ handle: AnalyticsSpanHandle) {}
}
#endif

// MARK: - Integration notes
// • AppDI: register a singleton `MetricKitService(analytics: AnalyticsLogger, sink: MetricSinkSpy/DiagnosticsViewAdapter, budgets: PerfBudgets())`.
// • App lifecycle: instantiate at app start so MetricKit deliveries attach. No extra background modes needed.
// • DiagnosticsView: subscribe to `summaryPublisher` and show battery/hr, CPU time, last thermal state; read persisted JSON on open.
// • Hot paths: wire the following calls:
//     RouteService: routingStart("route_plan") before MKDirections; routingEnd("route_plan") on completion.
//     RouteService: rerouteFreezeStart() when off-route snap detected → rerouteFreezeEnd() after overlay update.
//     SmoothOverlayRenderer / HazardOverlayRenderer: overlayRenderStart/End around draw cycles (throttle to important passes).
//     CapturePipeline: recorderStart() on begin, recorderEnd() on stop.
// • Budgets: if breachPublisher emits batteryOverBudget, raise a subtle banner in DiagnosticsView and log OS notice.
// • CI Perf tests: parse exported .xcresult (outside this service) to confirm plan and reroute spans meet budgets; this service provides runtime signposts & daily metrics to compare.

// MARK: - Test plan (unit / integration)
// 1) Payload aggregation:
//    - Build synthetic MXMetricPayload with power + app time (use private test-only constructors or wrap via an adapter); call didReceive.
//      Assert summaryPublisher emits with batteryDrainPctPerHour and triggers .batteryOverBudget when above threshold.
// 2) Diagnostics payloads:
//    - Simulate MXDiagnosticPayload arrays with 2 hangs + 1 crash; assert lastSummary counts and breachPublisher emitted .hangDetected and .crashDetected.
// 3) Persistence:
//    - After publish(), ensure Metrics/last_summary.json exists and reloading service yields same lastSummary.
// 4) Signpost glue:
//    - Call routingStart/routingEnd, overlayRenderStart/End, recorderStart/End; verify no crashes and AnalyticsLogging receives begin/end (use spy).
// 5) Back-compat:
//    - On iOS < 14, service enters .error("MetricKit unavailable") and does not crash.
// 6) Budget changes:
//    - Construct service with PerfBudgets(navBatteryPctPerHour: 1.0), feed in battery 5%/hr → breach emitted.


