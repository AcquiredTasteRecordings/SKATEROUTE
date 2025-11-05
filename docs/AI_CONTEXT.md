# SkateRoute — AI Engineering Context (Senior iOS)

> **Prime Directive:** Build the world’s best *skateboard-first* navigation for iPhone. Favor **smooth**, **downhill**, **legal/safe** lines. Keep the UI glanceable; keep everything fast, battery-light, and privacy-first.

---

## 0) What “good” looks like

**User outcome (Beta):** From a start & destination, the app returns a route that:
- Minimizes roughness and uphill while respecting legality/safety.
- Shows per-step coloring (butter → meh → crusty), downhill braking dashes, ETA/distance, and a grade summary.
- Runs a **Start / Stop** ride recorder: logs roughness + speed + location on-device, colors the live route, and provides subtle haptic cues.
- Works offline for the active route (cached tiles + per-step attributes).
- Asks for only the minimal permissions with clear, honest copy.

**Engineering outcomes:**
- Deterministic, testable **scoring** with explicit weights and feature toggles.
- Clear **service boundaries** and protocols; no UIKit or SwiftUI in Services.
- CI green; zero avoidable crashes; no main-actor violations in Services.

---

## 1) Platforms, SDK, and constraints

- **iOS**: 17+ (target), 18.x (tested), iPhone-only for now.
- **Maps**: MapKit routes (on-device + Apple services). No third‑party maps required.
- **No background network uploads**; all telemetry/logging remains on-device.
- **Privacy**: Location + Motion are used strictly for navigation/safety (no tracking, no 3P ads).
- **Performance guardrails**:
  - CPU budget during ride: \< 12% on A16 equivalent
  - Memory headroom: \> 150 MB free at runtime
  - Motion sampling: 50–100 Hz internal, 10 Hz processed
  - Location: desiredAccuracy `bestForNavigation`, distanceFilter adaptively 5–15 m

---

## 2) High-level architecture (folders map)

- **Core/**
  - `AppCoordinator`: navigation flow (Home → Map → Ride).
  - `AppDI`: dependency graph (singletons/factories), testable injection points.
  - `AppRouter`: enum-based screen routing.
- **Features/**
  - **Home/**: onboarding hero, origin/destination fields, presets (RideMode), quick access to recent routes.
  - **Map/**: `MapScreen` (route preview + Start/Stop), `MapViewContainer` (MKMapView host), `SmoothOverlayRenderer` (per-step coloring & braking dashes).
  - **Search/**: `PlaceSearchView`, `PlaceSearchViewModel` (MKLocalSearch wrapper with debounced updates).
  - **UX/**: `RideMode`, `TurnCueEngine`, `HapticCue`, `SpeedHUDView`, `RideTelemetryHUD`.
  - **Community/**: `QuickReportView`, `SurfaceRating` (2-tap “butter/okay/crusty”).
- **Services/**
  - `RouteService`: wraps MapKit Directions; canonical entry for route building.
  - `RouteContextBuilder`: derives `StepContext` array (per-step feature vector).
  - `ElevationService`: DEM sampling, grade summaries, braking zone detection.
  - `Matcher`: maps telemetry samples → nearest route step index.
  - `MotionRoughnessService`: accelerometer/gyro → RMS roughness (battery‑light).
  - `SmoothnessEngine`: smoothing & stability metric for UI.
  - `SegmentStore`: on-device store for per-step features & decay-by-age updates.
  - `SkateRouteScorer`: combiner of features into a scalar route score (mode-aware).
  - `RideRecorder`: orchestrates motion+location capture, step-attribution, logging.
  - `SessionLogger`: newline-delimited JSON (NDJSON) ride logs to app sandbox.
  - `GeocoderService`, `AttributionService`, `CacheManager`, `LocationManagerService`.
- **Support/Utilities/**
  - `AccuracyProfile`, `Geometry`, etc.

All UI talks to **Services** via protocols injected by **AppDI**. Services are pure (UIKit/SwiftUI-free) and unit-testable.

---

## 3) Core domain models (canonical types)

> These types are reference shapes used across Services and Features. Keep them small, copyable, and value-semantics friendly.

```swift
public struct StepContext: Sendable, Hashable {
    public let stepIndex: Int
    public let distance: CLLocationDistance
    public let expectedGradePct: Double        // [-30, +30]
    public let brakingZone: Bool               // grade < -6% over ≥30 m
    public let crossingsPerKm: Double          // proxy via step density or OSM later
    public let hasBikeLane: Bool               // from OSM/municipal overlays when present
    public let surfaceRoughnessRMS: Double?    // rolling median from SegmentStore
    public let hazardScore: Double?            // potholes/gravel/etc., 0..1 if known
    public let legalityScore: Double?          // 0..1 (1 = fully legal/allowed)
    public let freshnessDays: Double?          // how recent the data is
}
```

```swift
public struct GradeSummary: Sendable, Hashable {
    public let maxGradePct: Double
    public let meanGradePct: Double
    public let totalClimbMeters: Double
    public let totalDescentMeters: Double
    public let brakingMask: IndexSet          // step indices that require caution
}
```

```swift
public enum RideMode: String, CaseIterable, Sendable {
    case smoothest, chillFewCrossings, fastMildRoughness, nightSafe, trickSpotCrawl
}
```

---

## 4) Services — behavior contracts

> Services expose protocols. Concrete impls live beside the protocols; tests can inject stubs.

### 4.1 `RouteService`
**Purpose**: Single source of truth for route calculation and caching.

**API (suggested):**
```swift
protocol RouteService {
    func fetchRoute(from: MKMapItem, to: MKMapItem, mode: RideMode) async throws -> MKRoute
}
```
**Notes**:
- Prefer shortest or recommended MapKit profile but post-score via `SkateRouteScorer`.
- Cache by `(start,dest,mode)` key; invalidate when overlays change materially.

### 4.2 `RouteContextBuilder`
**Purpose**: Convert `MKRoute` → `[StepContext]`.

**Inputs**: MKRoute.steps, ElevationService, overlays (bike lanes, hazards), historical SegmentStore stats.  
**Outputs**: Dense per-step features with conservative defaults if data is missing.

### 4.3 `ElevationService`
**Purpose**: Grade/summary; braking zone detection.

**API**:
```swift
protocol ElevationService {
    func elevation(_ coord: CLLocationCoordinate2D) async -> Double?
    func grade(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) async -> Double?
    func summarizeGrades(on route: MKRoute) async -> GradeSummary
}
```
**Notes**:
- DEM source (pluggable): SRTM/Terrain-RGB/City DEM when available.
- Sample every 50–100 m; infer step grade from polyline sampling.
- `brakingZone`: grade \< −6% for ≥ 30 m.

### 4.4 `Matcher`
**Purpose**: Snap a telemetry sample → nearest step index.

```swift
struct MatchSample { let location: CLLocation; let roughnessRMS: Double }
protocol Matcher {
    func nearestStepIndex(on route: MKRoute, to sample: MatchSample, tolerance: CLLocationDistance) -> Int?
}
```
**Defaults**: tolerance 40 m; reject if beyond tolerance to avoid noise.

### 4.5 `MotionRoughnessService` & `SmoothnessEngine`
- **MotionRoughnessService**: band-pass filter + RMS on a rolling window; publish 10 Hz value.
- **SmoothnessEngine**: low-pass smoothed RMS (UI stability metric).

### 4.6 `SegmentStore`
**Purpose**: Per-step feature storage, decays with age.

**API shape**:
```swift
enum SegmentFeature: String { case roughnessRMS, hazardScore, bikeLane, legalityScore, crossingsPerKm }

protocol SegmentStore {
    func value(stepIndex: Int, feature: SegmentFeature) -> Double?
    func update(stepIndex: Int, feature: SegmentFeature, value: Double, freshness: Date)
    func decayAll(now: Date)
}
```
**File layout**: `/tiles/segments-{z}-{x}-{y}.json` (pluggable). Keep files \< 200 KB.

### 4.7 `SkateRouteScorer`
**Purpose**: Combine StepContext into a scalar.

**Scoring (illustrative):**
```
score = w_dist*norm(distance) +
        w_uphill*pos(gradePct) +
        w_downhill*neg(gradePct)*downhillBias +
        w_rough*norm(roughnessRMS) +
        w_cross*norm(crossingsPerKm) +
        w_hazard*norm(hazardScore) +
        w_legal*(1 - legalityScore)
```
- `RideMode` tweaks weights:
  - `.smoothest`: increase `w_rough`, cap `w_dist`.
  - `.chillFewCrossings`: increase `w_cross`.
  - `.nightSafe`: increase `w_hazard` (proxy for lighting/arterial).
  - `.fastMildRoughness`: reduce `w_rough` to ~60%.
- **Normalization**: MinMax or sigmoid by feature-specific ranges.

---

## 5) UI/UX contracts (what Features expect)

### 5.1 `MapScreen`
- Needs: `MKRoute`, `[StepContext]`, `GradeSummary`, `routeScore: Double`.
- Renders:
  - **Per-step coloring**: gradient from butter (#F2F2F2-ish) to crusty (dark).
  - **Braking dashes** on steps in `GradeSummary.brakingMask`.
  - **HUD**: speed, next maneuver distance, surface icon, stability meter.
- Start/Stop toggles `RideRecorder` with the active route & step contexts.

### 5.2 `TurnCueEngine`
- Triggers at ~40 m / 15 m before turns; plays `AudioServicesPlaySystemSound(1104)` + light haptic.
- Should avoid cue spam on stair-step polylines; coalesce short steps.

### 5.3 `QuickReportView` & `SurfaceRating`
- 2-tap reports update `SegmentStore` and visually decay over time (e.g., half-life ~ 14 days).
- Respect geofenced “no spot” zones (schools/hospitals) in UI.

---

## 6) Permissions, privacy, background

- **Info.plist**:
  - `NSLocationWhenInUseUsageDescription`: “SkateRoute uses your location to navigate smooth, safe skate routes while you’re using the app.”
  - `NSMotionUsageDescription`: “Motion data helps estimate pavement smoothness during rides.”
  - Optional: `NSLocationTemporaryUsageDescriptionDictionary` → `NavigationPrecision`.
- **Background Modes**: Location updates (when RideRecorder active).
- **Privacy Manifest**: `PrivacyInfo.xcprivacy` declares Location/Motion for functionality only.

---

## 7) Concurrency & threading

- Services default to non-main actor. UI integration hops to main as late as possible.
- Avoid retaining `CLLocationManager` delegates on background queues.
- `RideRecorder` uses Combine/AsyncSequence with back-pressure; discard-oldest policy at 20 events.

---

## 8) Error handling

- Fail **soft** with conservative defaults:
  - Missing DEM → grade 0.
  - No SegmentStore value → treat as neutral but lower confidence.
  - Matcher miss → don’t update step; keep last known color.
- Central `RouteError` enum with user-safe messages (no stack dumping in UI).

---

## 9) Performance & battery

- Motion pipeline: compute RMS over 250–500 ms windows; publish at 10 Hz.
- Location updates: adaptive distanceFilter (5–15 m based on speed).
- Overlay rendering:
  - Batch polyline segments per color band to minimize draw calls.
  - Only redraw visible range after updates.

---

## 10) Testing strategy

- **Unit**:
  - `SkateRouteScorerTests`: weight sanity; monotonicity (smoother → better).
  - `ElevationServiceTests`: grade sampling math and braking zones.
  - `MatcherTests`: tolerance gates and nearest-step correctness.
- **Snapshot**:
  - `SmoothOverlayRenderer`: fixed route JSON → consistent coloring images.
- **UI**:
  - GPX-based simulated rides (flat, uphill, downhill, mixed).
- **Property tests** (optional):
  - Randomized step arrays to check scorer stability.

---

## 11) Observability

- `OSLog` categories:
  - `routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`.
- Example:
```swift
let log = Logger(subsystem: "com.yourorg.skateroute", category: "matcher")
log.debug("matched step \(step, privacy: .public) at dist \(dist, privacy: .private(mask: .hash))")
```
- `SessionLogger`: NDJSON lines; print file path on stop:
  ```
  {"t": 1730359200.12,"lat":48.428,"lon":-123.365,"speed":5.2,"rms":0.08,"step":12}
  ```

---

## 12) CI/CD & code quality

- GitHub Actions: build/test on PR, archive on main (see `ios-ci.yml`).
- Fastlane: `beta` lane to TestFlight.
- SwiftLint: keep warnings low; treat new warnings as failures on PR.
- Branch policy: PR required; checks must pass.

---

## 13) Configuration & feature flags

- `App-Shared.xcconfig` holds Info.plist values (usage strings) and lightweight flags.
- Example compile flags (per config): `SMOOTH_OVERLAY_DEBUG`, `USE_TERRAIN_RGB_DEM`.
- Keep flags additive (do not change behavior silently across configs).

---

## 14) Security & privacy

- No third-party tracking SDKs.
- All ride logs remain **on-device** by default; any export must be user-initiated with a clear preview.
- Never write raw PII to logs; location/time is sensitive—consider downsampling when exporting.

---

## 15) Contribution guide for AI agents (Do/Don’t)

**Do**
- Write/modify tests with code.
- Keep services UI-agnostic.
- Add small, isolated dependencies only with strong justification.
- Document new weights or thresholds inside the scoring file.

**Don’t**
- Mix SwiftUI with Services.
- Introduce blocking network calls on the main thread.
- Add global state outside `AppDI`.

**Good PR checklist**
- [ ] Tests added/updated and passing.
- [ ] SwiftLint clean.
- [ ] Public APIs documented.
- [ ] No Info.plist/Privacy changes unless explicitly stated.

---

## 16) Next high-impact tasks (backlog)

1. **Roughness→overlay live updates**: apply MotionRoughnessService output to visible steps only.
2. **Bike-lane overlays**: integrate municipal/OSM tiles; add `hasBikeLane` to StepContext reliably.
3. **Sharp-turn penalty**: geometry-based; penalize > 60° downhill turns.
4. **Offline pack**: route + [StepContext] + grade summary cached with TTL.
5. **Mode calibration UI**: slider to bias roughness vs distance, persisted per-user.

---

## 17) Quick start for a new engineer

1. Open `SKATEROUTE.xcodeproj` → Scheme **SKATEROUTE**.
2. Run **Home** → set origin/dest → **Map** shows per-step colors & grade summary.
3. Tap **Start** → ride recorder begins; view HUD + haptics; tap **Stop** → log path prints in console (NDJSON in app Documents).
4. Tests: `⌘U` (sim). Location simulation GPX in `Support/TestData`.

---

## 18) Sample acceptance tests (for AI tasks)

- **Scorer monotonicity**: When `surfaceRoughnessRMS` increases with all else equal, route score must not improve.
- **Braking mask**: For a synthetic -8% grade over 50 m, step must be flagged braking.
- **Matcher tolerance**: Samples 60 m away from all steps return `nil`.

---

## 19) Design north star

Brand tone: **“It’s all downhill from here.”** Visual language: bold, high-contrast skate heritage; minimal distractions in ride mode. Accessibility: large tap targets, voice/haptic support, night-safe palettes.

---

*Appendix: Reference color map for smoothness (suggested)*

- 0.00–0.05 RMS → `butter` (very light)
- 0.05–0.12 → `okay`
- 0.12–0.20 → `meh`
- 0.20+ → `crusty`
(Exact palette lives in `SmoothOverlayRenderer`.)