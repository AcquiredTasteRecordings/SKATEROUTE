# SkateRoute — AI Engineering Context (Senior iOS)

> **Prime Directive:** Build the world’s best *skateboard-first* navigation for iPhone. Favor **smooth**, **downhill**, **legal/safe** lines. Keep the UI glanceable; keep everything fast, battery-light, and privacy-first.

---

## 0) What “good” looks like (1.0 Final)

**User outcome:** From a start & destination, the app returns a route that:
- Minimizes roughness and uphill while respecting legality/safety.
- Shows per-step coloring (butter → meh → crusty), downhill braking dashes, ETA/distance, and a grade summary.
- Runs a **Start / Stop** ride recorder: logs roughness + speed + location on-device, colors the live route, and provides subtle haptic/voice cues.
- **Reroutes** when off-route (>25 m) with low-distraction guidance.
- Works **offline** for active routes (cached tiles + per-step attributes + elevation summary via city packs).
- Prompts only for **minimal permissions** with clear, honest copy.

**Community & growth outcome:**
- **Gamified check-ins**, **weekly challenges**, **leaderboards**, and **badges** (e.g., *“100 km with SkateRoute”*).
- **Referral links** (universal links + `skateroute://`) deep-link into community/challenge flows with safe onboarding.
- Lightweight **capture/edit/share** of ride clips; background-safe uploads; feed with moderation.

**Engineering outcomes:**
- Deterministic, testable **scoring** with explicit weights and feature toggles.
- Clear **service boundaries** and protocols; no UIKit/SwiftUI in Services.
- CI green; zero avoidable crashes; no main-actor violations in Services; performance budgets met.

---

## 1) Platforms, SDK, and constraints
- **iOS**: 17+ (target), 18.x (tested), iPhone-only.
- **Maps**: MapKit routes (on-device + Apple services). Third‑party maps optional behind feature flags.
- **System frameworks**: StoreKit 2, BackgroundTasks, AVFoundation, CoreMotion, CoreLocation, UserNotifications, SafariServices (for terms/privacy), PassKit (Apple Pay, when enabled).
- **Privacy**: No third‑party tracking SDKs. Location + Motion strictly for navigation/safety; analytics beyond essentials are **opt‑in**.
- **Performance guardrails**:
  - CPU during ride: **< 12%** on A16-equivalent
  - Memory headroom: **> 150 MB** free
  - Motion sampling: 50–100 Hz internal, 10 Hz processed
  - Location: `bestForNavigation`, adaptive distanceFilter 5–15 m
  - Cold start: **≤ 1.2 s**

---

## 2) High-level architecture (folders map)

- **Core/**
  - `AppCoordinator` — navigation flow (Home → Map → Ride).
  - `AppDI` — dependency graph (singletons/factories), testable injection.
  - `AppRouter` — enum-based screen routing.
- **Features/**
  - **Home/** — onboarding hero, origin/destination fields, **RideMode** presets, **Challenges widget**, **Referral card**, recents.
  - **Map/** — `MapScreen` (route preview + Start/Stop), `MapViewContainer` (MKMapView host), `SmoothOverlayRenderer` (per-step coloring & braking dashes).
  - **Navigate/** — Ride HUD, cues, reroute, geofenced hazard alerts.
  - **Search/** — `PlaceSearchView`, `PlaceSearchViewModel` (MKLocalSearch wrapper with debounced updates).
  - **Spots/** — discovery list/map, spot detail, add-a-spot (private option).
  - **Social/** — capture, edit, upload queue, feed, profile.
  - **Commerce/** — paywall, IAP, Apple Pay/Stripe flows.
  - **Settings/** — permissions, privacy, data export/delete, units, voice/haptics.
  - **OfflinePacks/** — city pack manager (download/update/delete).
- **Services/**
  - `RouteService`, `RouteContextBuilder`, `ElevationService`, `Matcher`, `MotionRoughnessService`, `SmoothnessEngine`, `SegmentStore`, `SkateRouteScorer`, `RideRecorder`, `SessionLogger`.
  - `GeocoderService`, `AttributionService`, `CacheManager`, `LocationManagerService`.
  - **New (growth/commerce):** `ChallengeService`, `LeaderboardService`, `CheckInService`, `BadgeService`, `ReferralService` (deep links), `IAPService` (StoreKit 2), `PaymentsService` (Apple Pay/Stripe for physical goods), `BackgroundUploadService`, `HazardAlertService` (geofence + notification).
- **Support/Utilities/**
  - `AccuracyProfile`, `Geometry`, `DeepLinkParser`, `UnitFormatters`, test fixtures, GPX.

All UI talks to **Services** via protocols injected by **AppDI**. Services are pure (UIKit/SwiftUI-free) and unit-testable.

---

## 3) Core domain models (canonical types)

```swift
public struct StepContext: Sendable, Hashable {
    public let stepIndex: Int
    public let distance: CLLocationDistance
    public let expectedGradePct: Double        // [-30, +30]
    public let brakingZone: Bool               // downhill caution zone
    public let crossingsPerKm: Double          // proxy via step density or OSM later
    public let hasBikeLane: Bool               // overlays when present
    public let surfaceRoughnessRMS: Double?    // rolling median from SegmentStore
    public let hazardScore: Double?            // 0..1 if known
    public let legalityScore: Double?          // 0..1 (1 = fully legal)
    public let freshnessDays: Double?          // how recent the data is
}

public struct GradeSummary: Sendable, Hashable {
    public let maxGradePct: Double
    public let meanGradePct: Double
    public let totalClimbMeters: Double
    public let totalDescentMeters: Double
    public let brakingMask: IndexSet          // step indices requiring caution
}

public enum RideMode: String, CaseIterable, Sendable {
    case smoothest, chillFewCrossings, fastMildRoughness, nightSafe, trickSpotCrawl
}

public struct CheckIn: Sendable, Hashable {
    public let id: UUID
    public let spotID: String
    public let timestamp: Date
    public let location: CLLocationCoordinate2D
}

public struct Challenge: Sendable, Hashable {
    public let id: String
    public let title: String
    public let type: String   // distance, elevation, spots
    public let period: DateInterval // weekly
    public let goal: Double
}

public struct LeaderboardEntry: Sendable, Hashable {
    public let userID: String
    public let displayName: String
    public let metric: Double // distance/elevation/etc.
}

public struct Badge: Sendable, Hashable {
    public let id: String
    public let name: String
    public let unlockedAt: Date?
}

public struct ReferralPayload: Sendable, Hashable {
    public let code: String
    public let deepLink: URL // skateroute://challenge/<id> etc.
}
```

---

## 4) Services — behavior contracts
> Services expose protocols. Concrete impls live beside the protocols; tests may inject stubs.

### 4.1 `RouteService`
```swift
protocol RouteService {
    func fetchRoute(from: MKMapItem, to: MKMapItem, mode: RideMode) async throws -> MKRoute
}
```
- MapKit for baseline; post-score via `SkateRouteScorer`. Cache by `(start,dest,mode)`.

### 4.2 `RouteContextBuilder`
- MKRoute → `[StepContext]` using ElevationService, overlays (bike lanes, hazards), and SegmentStore.

### 4.3 `ElevationService`
```swift
protocol ElevationService {
    func elevation(_ coord: CLLocationCoordinate2D) async -> Double?
    func grade(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) async -> Double?
    func summarizeGrades(on route: MKRoute) async -> GradeSummary
}
```
- Sample 50–100 m; braking zones for downhill (e.g., ≤ −8% for ≥ 50 m).

### 4.4 `Matcher`
```swift
struct MatchSample { let location: CLLocation; let roughnessRMS: Double }
protocol Matcher {
    func nearestStepIndex(on route: MKRoute, to sample: MatchSample, tolerance: CLLocationDistance) -> Int?
}
```
- Default tolerance ~40 m; reject if > tolerance.

### 4.5 Motion & smoothing
- **MotionRoughnessService**: band‑pass + RMS, publish 10 Hz.
- **SmoothnessEngine**: low‑pass smoothing for stable HUD.

### 4.6 `SegmentStore`
```swift
enum SegmentFeature: String { case roughnessRMS, hazardScore, bikeLane, legalityScore, crossingsPerKm }
protocol SegmentStore {
    func value(stepIndex: Int, feature: SegmentFeature) -> Double?
    func update(stepIndex: Int, feature: SegmentFeature, value: Double, freshness: Date)
    func decayAll(now: Date)
}
```

### 4.7 `SkateRouteScorer`
- Weighted composite; RideMode adjusts weights; unit-tested monotonicity: rougher never scores higher.

### 4.8 Growth & referrals
```swift
protocol ChallengeService { func activeWeeklyChallenges() async throws -> [Challenge] }
protocol LeaderboardService { func topEntries(for challengeID: String) async throws -> [LeaderboardEntry] }
protocol CheckInService { func checkIn(at spotID: String, location: CLLocationCoordinate2D) async throws -> CheckIn }
protocol BadgeService { func badges() async throws -> [Badge] }
protocol ReferralService { func resolve(url: URL) -> ReferralPayload? }
```

### 4.9 Commerce & payments
```swift
protocol IAPService {
    func products() async throws -> [Product]
    func purchase(_ id: String) async throws -> Transaction
    func restore() async throws
}
protocol PaymentsService { func startApplePay(items: [PKPaymentSummaryItem]) async throws }
```
- IAP for digital (Pro, event passes). Apple Pay/Stripe for **physical goods/services** only.

### 4.10 Media & background
- **BackgroundUploadService**: resumable queue using BackgroundTasks.
- **HazardAlertService**: region monitoring + in-app toasts/haptics/optional voice.

---

## 5) UI/UX contracts (what Features expect)
- **Home**: search, recents, **Challenges**, **Referral** CTA.
- **Map**: route preview, color bands, braking mask, Start/Stop.
- **Ride HUD**: next-turn, distance, ETA, speed, braking indicator; voice + haptics.
- **Spots**: map/list, filters, detail with media; add-a-spot with privacy.
- **Capture/Edit**: presets (Normal, VHS, Speed Overlay), trim; queue shows background state.
- **Feed**: clips + route cards; moderation actions.
- **Profile**: stats, badges, routes, videos; privacy controls.
- **Commerce**: paywall, manage subscriptions, Apple Pay/Stripe checkout.
- **Offline Packs**: city selector, size, update cadence, delete.
- **Settings**: permissions, units, voice/haptics, analytics opt‑in, legal.

---

## 6) Permissions, privacy, background
**Info.plist** (typical):
- `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSLocationTemporaryUsageDescriptionDictionary` → `NavigationPrecision`
- `NSMotionUsageDescription`
- `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`
- `BGTaskSchedulerPermittedIdentifiers` (uploads/refresh)
- `UIBackgroundModes` → `location`
- Associated Domains for universal links (referrals)

**Privacy Manifest**: declares Location/Motion for functionality only. On‑device by default; no third‑party tracking.

---

## 7) Concurrency & threading
- Services are non‑main by default; hop to main late. Avoid blocking I/O on main.
- `RideRecorder` uses AsyncSequence with back-pressure; discard‑oldest at 20 events.
- StoreKit UI must be invoked from main; background uploads via BackgroundTasks.

---

## 8) Error handling
- Fail **soft** with conservative defaults:
  - Missing DEM → grade 0.
  - Missing SegmentStore values → neutral with lower confidence.
  - Matcher miss → keep last known color; don’t thrash.
- Commerce errors → user‑friendly messages + retry/backoff.
- Upload errors → resumable queue; exponential backoff.
- Referral failures → fallback to Home without data leak.

---

## 9) Performance & battery
- Overlay redraws: batch by color band; update only visible range.
- Motion RMS window: 250–500 ms; publish 10 Hz.
- Location: adaptive distanceFilter (5–15 m) based on speed.
- Budgets: cold start ≤ 1.2 s; active nav energy ≤ 8%/hr; GPS drift median ≤ 8 m; UI‑thread nav ops < 150 ms.

---

## 10) Testing strategy
- **Unit**: scorer monotonicity; elevation sampling & braking mask; matcher tolerance; reducers; referral parser; IAP receipts (mocked).
- **Snapshot**: `SmoothOverlayRenderer` fixed route JSON → pixel-stable images.
- **UI/XCUITest**: routing flow, Start/Stop, hazard toast, check‑in, challenge join, leaderboard view, referral deep‑link, purchase/restore.
- **Performance**: route compute < 250 ms typical urban; capture pipelines sustain target FPS.
- **Offline/Low‑bandwidth**: airplane mode + throttled networks before each release.
- **Device matrix**: last three iOS versions; SE and Pro Max.

---

## 11) Observability
- `os.Logger` categories: `routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`, `commerce`, `growth`, `deeplink`, `moderation`.
- `SessionLogger`: NDJSON lines; print export path on ride stop.

Example:
```swift
let log = Logger(subsystem: "com.skateroute.app", category: "deeplink")
log.info("resolved referral code=\(code, privacy: .private(mask: .hash)) → challenge=\(id, privacy: .public)")
```

---

## 12) CI/CD & code quality
- GitHub Actions: build/test on PR; archive on `main`; TestFlight via Fastlane.
- Lint/format: `swiftlint` + `swift-format` clean; warnings as errors.
- **Doc sync** gate: changes to `AGENTS`, `README`, or `WHITEPAPER.md` must be coordinated.

---

## 13) Configuration & feature flags
- `App-Shared.xcconfig` holds Info.plist copy and light flags.
- Flags: `FEATURE_CHALLENGES`, `FEATURE_REFERRALS`, `FEATURE_OFFLINE_PACKS`, `FEATURE_VIDEO_FILTERS` (default ON for 1.0).

---

## 14) Security & privacy
- No secrets in code; CI-managed keys. All logs local by default; user‑initiated export only.
- No raw lat/lon in analytics; bucketize/hash if analytics opt‑in is enabled.
- LICENSE: **All Rights Reserved** (SkateRoute).

---

## 15) Contribution guide for AI agents (Do/Don’t)
**Do**
- Write/modify tests with code; keep Services UI-agnostic; document new weights/thresholds.
- Register new Services in `AppDI`; keep ViewModels thin.

**Don’t**
- Mix SwiftUI with Services; block the main thread; add heavy deps casually; alter Info.plist keys silently.

**PR checklist**
- [ ] Tests added/updated ✓  
- [ ] SwiftLint/format clean ✓  
- [ ] Public APIs documented ✓  
- [ ] Doc sync considered (AGENTS/README/WHITEPAPER) ✓

---

## 16) Next high‑impact tasks (post‑1.0)
1. Server‑assisted hazard reconciliation & richer trust graphs.
2. Sharp‑turn penalty for steep downhill (>60°) in scorer.
3. Partner events (quests, branded rewards) via feature flags.

---

## 17) Quick start for a new engineer
1. Open `SKATEROUTE.xcodeproj` → Scheme **SkateRoute**.
2. Home → set origin/destination → Map shows per‑step colors & grade summary.
3. **Start** ride → HUD + cues; **Stop** → NDJSON path printed; file saved to Documents.
4. Run tests `⌘U`. Simulate GPX from `Support/TestData`.

---

## 18) Sample acceptance tests
- **Downhill caution**: −8% grade over ≥50 m → braking dashes + pre‑turn haptic.
- **Reroute**: deviation >25 m → new route in <2 s; cues reset.
- **Monotonicity**: rougher steps never outscore smoother ones.
- **Check‑in**: entering spot geofence + action → check‑in persists and increments challenge.
- **Referral**: universal link to `skateroute://challenge/<id>` opens to challenge detail; consent respected.
- **Commerce**: purchase/restore toggles Pro entitlements; Apple Pay path only for physical goods.

---

## 19) Design north star
Brand tone: **“It’s all downhill from here.”** Bold, high‑contrast skate heritage; minimal distractions in ride mode. Accessibility: Dynamic Type, VoiceOver, large hit targets, night‑safe palettes.

---

*Appendix: Reference color map for smoothness (suggested)*
- 0.00–0.05 RMS → `butter` (very light)
- 0.05–0.12 → `okay`
- 0.12–0.20 → `meh`
- 0.20+ → `crusty`
(Exact palette lives in `SmoothOverlayRenderer`.)

---

**See also:** [`AGENTS.md`](./AGENTS.md) · [`README.md`](./README.md) · [`WHITEPAPER.md`](./WHITEPAPER.md)
