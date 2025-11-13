SkateRoute Agent Charter & Engineering Guidelines (2025 Refresh)

Mission

Ship the world’s smoothest, safest, most hype skateboard-first navigation and social app for iPhone. Every contribution must push SkateRoute toward an App Store–ready release with production-quality code, resilient architecture, rigorous validation, and zero drama.

⸻

Product North Star
	•	Primary Goal: Frictionless, elevation-aware navigation with real-time hazard intelligence tuned for skateboards and other small-wheel micromobility.
	•	User Pillars (map each change to ≥1 pillar, never regress others):
	1.	Safety – Hazard detection, fall prevention, redundant alerts (visual + haptic + voice).
	2.	Flow – Smooth turn-by-turn guidance optimized for skate-friendly surfaces and gradients.
	3.	Community – Effortless capture, curation, discovery of lines, clips, spots, and meetups.
	4.	Performance – Native, battery-efficient, offline-tolerant experiences.

⸻

Scope for SkateRoute 1.0 (Complete Feature Set)

Skate-Optimized Navigation
	•	Grade-aware + surface-aware routing (MapKit-first) with per-step skateability coloring.
	•	Braking dashes for steep downhills, live ETA/distance, reroute on deviation.
	•	Ride modes: smoothest, chillFewCrossings, fastMildRoughness, nightSafe, trickSpotCrawl.

Hazard Detection & Alerts
	•	Crowdsourced hazards (potholes, gravel, tram tracks, glass, wet leaves) with trust weighting + time decay.
	•	Geofenced entry/exit alerts with confidence visualization; background-safe delivery during rides.

Spots & Discovery
	•	Built-in directory of skateparks/plazas/DIYs and community pins; clustering; one-tap directions; optional private spots.

Ride Recording & Telemetry
	•	On-device motion roughness (RMS), GPS matcher, stability meter; NDJSON ride logs exportable by the user.

Search & Offline Packs
	•	Search feature module (Features/Search) using PlaceSearchView + PlaceSearchViewModel with debounced MKLocalSearch.
	•	Offline pack manager (Features/OfflinePacks) for cached city bundles (polylines, per-step attributes, elevation summaries).

Video + Social Layer
	•	60 FPS target with AVFoundation filters (Normal, VHS, Speed Overlay).
	•	Feed with clips, route cards, spot pins, moderation hooks (flagging, shadow ban, unsafe-content checks).
	•	Background upload queue via BackgroundUploadService.

Growth, Challenges & Monetization
	•	StoreKit 2 freemium → Pro (offline packs, advanced overlays, premium spots).
	•	Consumables for event passes; Apple Pay / Stripe for merch + event tickets.
	•	Weekly challenges, leaderboards, check-ins, badges, referrals via deep links (skateroute://).
	•	Privacy-respecting house/network ads (contextual only).

Accessibility & Brand
	•	Big tap targets, Dynamic Type, VoiceOver labels, high contrast; vibe is welcoming, skate-savvy, never gatekeepy.

⸻

Non-Negotiable Principles
	1.	Respect the architecture. Extend, don’t fork. Register new services in AppDI. Keep view models thin.
	2.	SwiftUI first, MapKit-aware. UIKit stays in bridges like MapViewContainer or custom renderers.
	3.	Async clarity. Prefer async/await; propagate cancellation; never block the main thread.
	4.	Telemetry is sacred. Maintain data fidelity in RideRecorder, Matcher, MotionRoughnessService. Schema changes must stay backward-compatible.
	5.	User trust. Privacy, accessibility, and low-distraction UX are first-class. Haptics + voice cues ship together.
	6.	No secrets in code. Keys live in CI or configuration; lint fails on token leaks.

⸻

Architecture & Project Structure

Style: Swift + SwiftUI. Combine acceptable for bridges; async/await for concurrency.

Pattern: MVVM + Coordinators + DI (TCA-friendly). Feature modules may embed TCA reducers internally while exposing MVVM façades to the app layer.

Project layout

Core/            AppCoordinator, AppDI, shared domain orchestration
Services/        RouteService, RouteContextBuilder, ElevationService, Matcher,
                 MotionRoughnessService, SmoothnessEngine, SegmentStore,
                 SkateRouteScorer, RideRecorder, SessionLogger,
                 GeocoderService, AttributionService, CacheManager,
                 LocationManagerService, ChallengeService, LeaderboardService,
                 CheckInService, BadgeService, ReferralService, IAPService,
                 PaymentsService, BackgroundUploadService, HazardAlertService
Features/
  Home/          Entry, search entry points, recent routes, challenges widget
  Map/           MapScreen, MapViewContainer, SmoothOverlayRenderer, TurnCueEngine
  Navigate/      Ride HUD, cues, reroute, alerts
  Search/        PlaceSearchView & ViewModel (debounced MKLocalSearch)
  OfflinePacks/  City pack management (download/update/delete)
  Spots/         Discovery list/map, detail, add-a-spot (private option)
  Social/        Capture, Edit, Upload Queue, Feed, Profile
  Commerce/      Paywall, IAP, Apple Pay/Stripe flows
  Settings/      Permissions, privacy, data export/delete, units, voice/haptics
DesignSystem/    Typography, color, iconography, haptics, motion tokens
Support/         Utilities, previews, test fixtures, GPX (NDJSON ride logs)
Docs/            Specs, ADRs, telemetry schemas, checklists

Swift style
	•	Follow Swift API Design Guidelines. Build clean with swift-format + swiftlint (warnings as errors).
	•	Document public types with /// summarizing purpose and invariants.
	•	Keep services UI-free; communicate through protocols injected via AppDI.

⸻

Canonical Domain Contracts
	•	StepContext: gradePercent, roughnessRMS, brakingZone, surface, bikeLane, hazardScore, legalityScore, freshness.
	•	GradeSummary: maxGrade, meanGrade, climb, descent, brakeMask.
	•	RideMode: enum values listed above control scoring weights and cue policy.
	•	SkateRouteScore: weighted composite; ride-mode dependent with monotonicity tests.
	•	Community models: CheckIn, Challenge, LeaderboardEntry, Badge, Referral (see docs/AI_CONTEXT.md).

⸻

Navigation & Mapping Requirements
	•	Routing weights (defaults):
	•	Uphill penalized > 6%; downhill braking warnings at > 8% grade.
	•	Rough/forbidden surfaces excluded unless user opts-in.
	•	Traffic/crossings and hazard score factor into step penalties.
	•	Fallback: Always provide an accessibility route if rejecting walking/cycling defaults.
	•	Render: Multi-segment overlays by color band (butter → meh → crusty). Braking shown as dashed mask atop polyline.
	•	Reroute: Trigger when user deviates > 25 m from nearest polyline point.
	•	Caching: Route tiles + hazard layers cached per city; offline pack management UI controls download/update/delete.
	•	Tests: Geospatial changes require fixtures validating distance, ETA, skateability score, braking mask.

⸻

Hazard Intelligence & Alerts
	•	Ingest: Debounce, dedupe via geohash, reconcile with authoritative feeds. Store provenance (source, timestamp, confidence).
	•	Trust: Reporter reputation with time decay; display confidence state in UI.
	•	Alerts: Multimodal (voice if navigating, haptic always, visual toast). Never rely on sound alone.

⸻

Performance & Reliability Targets
	•	Route compute < 250 ms in typical urban scenarios.
	•	Map pan/overlay animations at 60 FPS.
	•	Median time to first route ≤ 1.5 s (≤1.2 s stretch goal) with cache warm.
	•	Ride recorder energy impact ≤ 8%/hr on A16-equivalent devices.
	•	Hazard alert latency ≤ 300 ms from geofence entry to UI cue.
	•	Maintain ≥ 99.5% crash-free users per release.

⸻

Offline, Battery & Network Expectations
	•	Offline packs bundle polylines, attributes, elevation summaries; respect ETag/timestamp invalidation.
	•	Exercise airplane mode + throttled network scenarios pre-release.
	•	Background uploads & hazard polling must back off on low battery / constrained network.

⸻

Accessibility, Copy & Brand Guardrails
	•	Dynamic Type, VoiceOver labels, haptics + voice cues in sync.
	•	Tone: upbeat, inclusive, skate-savvy, never gatekeepy. Highlight underrepresented skaters and accessible spots.
	•	Maintain night-safe palettes in ride HUD; keep ride UI distraction-free.

⸻

Quality Gates (Blocking)
	1.	Static analysis: swiftlint clean; swift-format applied; no stray print.
	2.	Tests: Add/update coverage with new code. Run
xcodebuild -scheme SkateRoute -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test (green).
	3.	Manual matrix: Routing; ride start/stop; overlay recolor; quick hazard report; offline pack lifecycle; background/termination geofence flows; challenge/check-in/leaderboard happy paths.
	4.	Performance: Validate route compute + video pipeline budgets; monitor 20-min ride CPU/memory/energy.
	5.	Docs: Keep README.md, WHITEPAPER.md, and this charter in sync when behaviors/architecture change.

⸻

Workflow & Tooling
	•	Branches: Conventional commits (feat:, fix:, perf:, docs:, chore:).
	•	PR expectations:
	•	Link issue with acceptance criteria.
	•	Passing automated tests (CI).
	•	QA checklist (offline, device matrix, regressions).
	•	Screenshots or short clips for UI changes; include before/after when relevant.
	•	Start PR description with trade-offs / open questions.
	•	Merge: Squash to keep main clean.
	•	Commit messages in imperative mood (e.g., “Add”, “Refine”).

⸻

Testing Strategy
	•	Unit: Scorer monotonicity; elevation sampling & braking mask; matcher tolerance; referral parsing; IAP receipts (mocked); challenge/leaderboard logic; offline pack lifecycle.
	•	Snapshot: SmoothOverlayRenderer overlays vs fixtures.
	•	UI/XCUITest: Routing flow, Start/Stop, hazard toast, check-in, challenge join, leaderboard view, referral deep-link, purchase/restore, offline pack download.
	•	Performance: Route compute, capture pipeline throughput, background upload queue latency.
	•	Offline/Low-bandwidth: Validate features in airplane mode and constrained networks.
	•	Device matrix: Last three iOS versions; smallest (SE) + largest (Pro Max) form factors.

⸻

Observability & Telemetry
	•	Use os.Logger categories: routing, elevation, matcher, recorder, overlay, privacy, commerce, growth, deeplink, moderation.
	•	SessionLogger writes NDJSON lines; print export path on ride stop.
	•	No raw lat/lon in analytics without opt-in; bucketize or hash as needed.

⸻

Configuration & Feature Flags
	•	Shared config lives in App-Shared.xcconfig.
	•	Feature flags: FEATURE_CHALLENGES, FEATURE_REFERRALS, FEATURE_OFFLINE_PACKS, FEATURE_VIDEO_FILTERS (default ON for 1.0). Keep new flags discoverable and documented.

⸻

Security & Privacy
	•	No third-party tracking SDKs. Location + Motion strictly for navigation/safety.
	•	Commerce flows must surface clear purchase copy; Apple Pay/Stripe only for physical goods/services.
	•	Handle referral and deep-link flows without leaking private data; fallback gracefully when validation fails.

⸻

Do / Don’t Checklist

Do
	•	Extend services via protocols; keep SwiftUI out of service layers; wire via AppDI.
	•	Localize strings; surface user-facing errors via view models; log via SessionLogger.
	•	Add tests + docs alongside code; snapshot overlays where feasible.
	•	Respect availability checks (#available(iOS 18+, *)) for modern MapKit APIs.

Don’t
	•	Mix UI with business logic or block the main thread.
	•	Rename canonical types (StepContext, RideMode, SkateRouteScore, etc.) without ADR + migration.
	•	Add heavy dependencies without justification; never ship placeholder privacy copy.

⸻

Quick Start for New Agents
	1.	Open SKATEROUTE.xcodeproj and run the SkateRoute scheme.
	2.	Home → set origin/destination → Map renders color-banded route + grade summary.
	3.	Start ride → roughness updates recolor steps; braking dashes show; stop → NDJSON path saved to Documents.
	4.	Explore Search, Offline Packs, Challenges, and Referrals flows to stay familiar.
	5.	Run tests with ⌘U. Simulate rides using GPX fixtures in Support/TestData.

⸻

Acceptance Examples
	•	Downhill caution: A −8% grade over ≥50 m displays braking dashes and triggers pre-turn haptic.
	•	Reroute: Deviations > 25 m from route polyline request a new route within 2 s.
	•	Monotonicity: Rougher steps never outscore smoother ones (all else equal).
	•	Check-in: Entering spot geofence and confirming action persists the check-in and increments relevant challenges.
	•	Referral: skateroute://challenge/<id> opens challenge detail; consent respected.
	•	Commerce: Purchase/restore toggles Pro entitlements; Apple Pay path restricted to physical goods.
	•	Offline pack: Download/update/delete flows honor storage warnings and respect cache invalidation.

⸻

By following this refreshed playbook, agents keep SkateRoute crisp, safe, and App Store–ready—so riders can lock in lines and vibe anywhere.
