// Features/UX/TurnCueEngine.swift
// Speed-aware turn cue engine with tiered announcements, jitter suppression, and clean hooks.

import Foundation
import Combine
import CoreLocation
import MapKit

// MARK: - Cue Model

public enum CueTier: Int, Comparable {
    // Increasing urgency as you get closer to the maneuver.
    case far = 0     // e.g., ~200–300 m out
    case near = 1    // e.g., ~60–100 m out
    case now = 2     // e.g., ~10–25 m, do it now
    case arrived = 3 // destination reached

    public static func < (lhs: CueTier, rhs: CueTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CueKind: Equatable {
    case start
    case continueStraight
    case turnLeft
    case turnRight
    case slightLeft
    case slightRight
    case uTurn
    case roundabout(exit: Int?)
    case merge
    case exit
    case arrive
    case custom(text: String)
}

public struct TurnCue: Equatable, Identifiable {
    public var id: String { "\(stepIndex)-\(kind)-\(tier.rawValue)" }
    public let stepIndex: Int
    public let kind: CueKind
    public let tier: CueTier
    public let instruction: String           // human-readable, localized-ish
    public let distanceMeters: CLLocationDistance // remaining distance to maneuver (best-effort)
    public let iconName: String              // SF Symbol name for UI
    public let shouldSpeak: Bool             // for TTS, caller decides
    public let shouldHaptic: Bool            // for haptics, caller decides
}

// MARK: - Engine

@MainActor
public final class TurnCueEngine: ObservableObject {

    // Outputs
    @Published public private(set) var latestCue: TurnCue?
    public var cuePublisher: AnyPublisher<TurnCue, Never> { cueSubject.eraseToAnyPublisher() }

    // Config
    public struct Config {
        public var minMetersForAnyCue: CLLocationDistance = 20         // ignore micro movements
        public var arrivedMeters: CLLocationDistance = 18              // arrival radius
        public var minSecondsBetweenCues: TimeInterval = 4             // anti-spam
        public var allowRepeatAtSameTier: Bool = false                 // usually false; UX dependent
        public var defaultLookaheadMeters: CLLocationDistance = 240    // cap for far-tier spacing
        public var nearBandFraction: Double = 0.35
        public var nowBandFraction: Double = 0.10
        public init() {}
    }

    private var cfg = Config()

    // Dependencies
    private var route: MKRoute?
    private var steps: [MKRoute.Step] = []

    // State
    private var lastCueAt: Date?
    private var lastCueStep: Int?
    private var lastCueTier: CueTier?
    private var lastStepIndexFromMatcher: Int?
    private var lastProgressInStep: Double?
    private var lastCoord: CLLocationCoordinate2D?

    private var cueSubject = PassthroughSubject<TurnCue, Never>()

    public init(config: Config = Config()) {
        self.cfg = config
    }

    // MARK: - Public API

    /// Call when a new route is selected.
    public func setRoute(_ route: MKRoute?) {
        self.route = route
        self.steps = route?.steps ?? []
        resetCueMemory()
        if steps.count > 0 {
            // Emit a start cue for UX momentum
            let startCue = TurnCue(
                stepIndex: 0,
                kind: .start,
                tier: .far,
                instruction: steps.first?.instructions.nonEmpty ?? "Start",
                distanceMeters: steps.first?.distance ?? 0,
                iconName: "arrow.up.right", // neutral start arrow
                shouldSpeak: true,
                shouldHaptic: true
            )
            commitCue(startCue)
        }
    }

    /// Feed live samples into the engine (call from your recorder or location pipeline).
    /// - Parameters:
    ///   - location: latest location
    ///   - stepIndex: optional current step index (from your Matcher). If nil, we fall back to geometry inference.
    ///   - progressInStep: optional 0–1 progress (from Matcher). Used for more accurate distance-to-maneuver.
    ///   - currentSpeedMps: optional speed (m/s); used for dynamic lookahead bands.
    public func ingest(location: CLLocation,
                       stepIndex: Int?,
                       progressInStep: Double?,
                       currentSpeedMps: Double?) {
        guard let route else { return }
        guard route.distance >= cfg.minMetersForAnyCue else { return }

        lastCoord = location.coordinate
        lastStepIndexFromMatcher = stepIndex
        lastProgressInStep = progressInStep

        // Arrival handling
        if isArrived(location) {
            emitArrivalCueIfNeeded()
            return
        }

        guard let next = nextManeuverStepIndex(current: stepIndex) else { return }
        let distToManeuver = distanceToStepStart(from: location.coordinate,
                                                 currentStepIndex: stepIndex,
                                                 progressInStep: progressInStep,
                                                 targetStepIndex: next)

        // Speed-aware dynamic lookahead
        let L = dynamicLookaheadMeters(speedMps: currentSpeedMps)
        let farThreshold = max(60, min(cfg.defaultLookaheadMeters, L))                 // ~60–240 m
        let nearThreshold = max(25, farThreshold * cfg.nearBandFraction)               // e.g., 80m → 28m
        let nowThreshold  = max(10, farThreshold * cfg.nowBandFraction)                // e.g., 80m → 8m

        let tier: CueTier
        if distToManeuver <= nowThreshold {
            tier = .now
        } else if distToManeuver <= nearThreshold {
            tier = .near
        } else if distToManeuver <= farThreshold {
            tier = .far
        } else {
            // too far; don't cue yet
            return
        }

        // Jitter/anti-spam
        if let lcAt = lastCueAt, Date().timeIntervalSince(lcAt) < cfg.minSecondsBetweenCues { return }
        if let lcStep = lastCueStep, let lcTier = lastCueTier {
            if lcStep == next, lcTier == tier, cfg.allowRepeatAtSameTier == false { return }
        }

        // Build cue from the target step's instruction
        let step = steps[next]
        let parsed = parseManeuver(from: step)
        let text = makeInstructionText(step: step, kind: parsed.kind, distanceMeters: distToManeuver)
        let cue = TurnCue(
            stepIndex: next,
            kind: parsed.kind,
            tier: tier,
            instruction: text,
            distanceMeters: max(0, distToManeuver),
            iconName: parsed.symbol,
            shouldSpeak: tier != .far,        // keep voice quiet at far range by default
            shouldHaptic: tier >= .near       // buzz for near/now
        )
        commitCue(cue)
    }

    public func reset() {
        resetCueMemory()
        latestCue = nil
    }

    // MARK: - Internals

    private func resetCueMemory() {
        lastCueAt = nil
        lastCueStep = nil
        lastCueTier = nil
        lastStepIndexFromMatcher = nil
        lastProgressInStep = nil
    }

    private func commitCue(_ cue: TurnCue) {
        latestCue = cue
        cueSubject.send(cue)
        lastCueAt = Date()
        lastCueStep = cue.stepIndex
        lastCueTier = cue.tier
    }

    private func isArrived(_ location: CLLocation) -> Bool {
        guard let route else { return false }
        let dst = route.destination.placemark.coordinate
        let d = location.coordinate.haversineMeters(to: dst)
        return d <= cfg.arrivedMeters
    }

    private func emitArrivalCueIfNeeded() {
        // Prevent repeat arrival spam
        if lastCueTier == .arrived { return }
        let finalIndex = max(0, steps.count - 1)
        let cue = TurnCue(
            stepIndex: finalIndex,
            kind: .arrive,
            tier: .arrived,
            instruction: "Arrived",
            distanceMeters: 0,
            iconName: "checkmark.circle.fill",
            shouldSpeak: true,
            shouldHaptic: true
        )
        commitCue(cue)
    }

    /// Returns the *next* maneuver step index after the current step (or best-guess when current is nil).
    private func nextManeuverStepIndex(current: Int?) -> Int? {
        guard !steps.isEmpty else { return nil }
        if let idx = current {
            // If we're on the last step, the next maneuver is arrival.
            if idx >= steps.count - 1 { return idx } // arrival handling occurs separately
            // Skip empty-instruction steps (MapKit sometimes inserts them)
            for i in (idx + 1)..<steps.count where steps[i].instructions.nonEmpty != nil {
                return i
            }
            return min(idx + 1, steps.count - 1)
        } else {
            // No matcher index — find the nearest step start by geometry (best effort).
            // Use first non-empty instruction step as the next.
            for i in 0..<steps.count where steps[i].instructions.nonEmpty != nil {
                return i
            }
            return 0
        }
    }

    /// Estimate remaining distance to the start of a target step.
    private func distanceToStepStart(from coord: CLLocationCoordinate2D,
                                     currentStepIndex: Int?,
                                     progressInStep: Double?,
                                     targetStepIndex: Int) -> CLLocationDistance {
        guard !steps.isEmpty else { return 0 }
        var distance: CLLocationDistance = 0

        if let cur = currentStepIndex, cur < targetStepIndex, cur >= 0, cur < steps.count {
            // Remaining in current step
            let currentStep = steps[cur]
            let remainingInCurrent: CLLocationDistance
            if let p = progressInStep {
                remainingInCurrent = max(0, currentStep.distance * (1.0 - p))
            } else {
                // geometry fallback: distance to step end
                remainingInCurrent = distanceFrom(coord, toPolylineEnd: currentStep.polyline)
            }
            distance += remainingInCurrent
            // Full middle steps
            if targetStepIndex - cur > 1 {
                for s in steps[(cur + 1)..<targetStepIndex] {
                    distance += s.distance
                }
            }
            // Up to target step *start* (0)
            // Nothing to add for target start itself.
            return max(0, distance)
        }

        // Unknown current step — fallback: distance to start coordinate of target step polyline
        let startCoord = steps[targetStepIndex].polyline.firstCoordinate() ?? route?.polyline.firstCoordinate() ?? coord
        return coord.haversineMeters(to: startCoord)
    }

    private func dynamicLookaheadMeters(speedMps: Double?) -> CLLocationDistance {
        guard let v = speedMps, v.isFinite, v > 0 else {
            return cfg.defaultLookaheadMeters
        }
        // Rough: speed * 10 sec, clamped. Faster roll = earlier heads-up.
        return max(80, min(320, v * 10.0))
    }

    // MARK: - Instruction parsing / formatting

    private func parseManeuver(from step: MKRoute.Step) -> (kind: CueKind, symbol: String) {
        let text = step.instructions.lowercased()
        // Lightweight heuristics; MapKit doesn’t always give explicit maneuver types.
        if text.contains("roundabout") {
            return (.roundabout(exit: extractExitNumber(text)), "arrow.triangle.branch")
        }
        if text.contains("u-turn") || text.contains("u turn") {
            return (.uTurn, "arrow.uturn.left")
        }
        if text.contains("merge") {
            return (.merge, "arrow.merge")
        }
        if text.contains("exit") {
            return (.exit, "arrow.up.left")
        }
        if text.contains("slight right") {
            return (.slightRight, "arrow.turn.down.right")
        }
        if text.contains("slight left") {
            return (.slightLeft, "arrow.turn.down.left")
        }
        if text.contains("right") {
            return (.turnRight, "arrow.turn.right.up")
        }
        if text.contains("left") {
            return (.turnLeft, "arrow.turn.left.up")
        }
        if text.contains("arrive") {
            return (.arrive, "checkmark.circle.fill")
        }
        if text.contains("continue") || text.isEmpty {
            return (.continueStraight, "arrow.up")
        }
        return (.custom(text: step.instructions), "arrow.up")
    }

    private func makeInstructionText(step: MKRoute.Step, kind: CueKind, distanceMeters: CLLocationDistance) -> String {
        switch kind {
        case .arrive:
            return "Arrived"
        case .start:
            return step.instructions.nonEmpty ?? "Start"
        default:
            let lead = distanceString(distanceMeters)
            let body = step.instructions.nonEmpty ?? verb(for: kind)
            return lead.isEmpty ? body : "\(lead) • \(body)"
        }
    }

    private func verb(for kind: CueKind) -> String {
        switch kind {
        case .turnLeft: return "Turn left"
        case .turnRight: return "Turn right"
        case .slightLeft: return "Bear left"
        case .slightRight: return "Bear right"
        case .uTurn: return "Make a U-turn"
        case .roundabout(let exit):
            if let e = exit { return "At roundabout, take exit \(e)" }
            return "At roundabout, continue"
        case .merge: return "Merge"
        case .exit: return "Exit"
        case .continueStraight: return "Continue"
        case .start: return "Start"
        case .arrive: return "Arrived"
        case .custom(let t): return t
        }
    }

    private func distanceString(_ meters: CLLocationDistance) -> String {
        // Keep it snappy and legible.
        let fmt = MeasurementFormatter()
        fmt.unitOptions = .naturalScale
        fmt.numberFormatter.maximumFractionDigits = meters < 5000 ? 0 : 0
        let km = Measurement(value: meters, unit: UnitLength.meters)
        return fmt.string(from: km)
    }

    private func extractExitNumber(_ text: String) -> Int? {
        // crude parse like "take the 2nd exit"
        let tokens = text.split(separator: " ")
        for t in tokens {
            if let n = Int(t.filter(\.isNumber)) { return n }
        }
        return nil
    }
}

// MARK: - Geo helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension MKPolyline {
    func firstCoordinate() -> CLLocationCoordinate2D? {
        guard pointCount > 0 else { return nil }
        let pointer = points()
        return pointer.pointee.coordinate
    }

    func lastCoordinate() -> CLLocationCoordinate2D? {
        guard pointCount > 0 else { return nil }
        let pointer = points().advanced(by: pointCount - 1)
        return pointer.pointee.coordinate
    }
}

private extension CLLocationCoordinate2D {
    func haversineMeters(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let R = 6_371_000.0
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = (other.latitude - latitude) * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ/2)*sin(dφ/2) + cos(φ1)*cos(φ2)*sin(dλ/2)*sin(dλ/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }
}

private func distanceFrom(_ coord: CLLocationCoordinate2D, toPolylineEnd poly: MKPolyline) -> CLLocationDistance {
    // Fallback: sum of segment lengths from the closest point to the end of polyline.
    // We’ll approximate by using whole-step distance since MapKit steps are short.
    return poly.pointCount > 0 ? poly.distanceMetersFallback() : 0
}

private extension MKPolyline {
    func distanceMetersFallback() -> CLLocationDistance {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        guard coords.count > 1 else { return 0 }
        var d: CLLocationDistance = 0
        for i in 0..<(coords.count - 1) {
            let a = MKMapPoint(coords[i])
            let b = MKMapPoint(coords[i + 1])
            d += MKMetersBetweenMapPoints(a, b)
        }
        return d
    }
}


