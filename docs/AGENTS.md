SkateRoute Agent Charter & Engineering Guidelines (2025 Refresh)

Mission

Ship the world’s smoothest, safest, most hype skateboard-first navigation and social app for iPhone. Every contribution must push SkateRoute toward an App Store–ready release with production-quality code, resilient architecture, rigorous validation, and zero drama.

⸻

Product North Star
    •    Primary Goal: Frictionless, elevation-aware navigation with real-time hazard intelligence tuned for skateboards and other small-wheel micromobility.
    •    User Pillars (map each change to ≥1 pillar; never regress others):
    1.    Safety — Hazard detection, fall prevention, redundant alerts (visual + haptic + voice).
    2.    Flow — Smooth turn-by-turn guidance optimized for skate-friendly surfaces and gradients.
    3.    Community — Effortless capture, curation, discovery of lines, clips, spots, and meetups.
    4.    Performance — Native, battery-efficient, offline-tolerant experiences.

⸻

Scope for SkateRoute 1.0 (Complete Feature Set)

Skate-Optimized Navigation
    •    Grade-aware + surface-aware routing (MapKit-first) with per-step skateability coloring.
    •    Braking dashes for steep downhills; live ETA/distance; reroute on deviation.
    •    Ride modes: smoothest, chillFewCrossings, fastMildRoughness, nightSafe, trickSpotCrawl.

Hazard Detection & Alerts
    •    Crowdsourced hazards: potholes, gravel, tram tracks, glass, wet leaves.
    •    Trust weighting + time decay.
    •    Geofenced entry/exit alerts with confidence visualization; background-safe delivery.

Spots & Discovery
    •    Built-in directory of skateparks/plazas/DIYs and community pins.
    •    Clustering, one-tap directions, optional private spots.

Ride Recording & Telemetry
    •    On-device RMS roughness, GPS matcher, stability meter.
    •    NDJSON ride logs exportable by the user.

Search & Offline Packs
    •    Search (Features/Search) with PlaceSearchView + PlaceSearchViewModel (debounced MKLocalSearch).
    •    Offline pack manager (Features/OfflinePacks) with polylines, attributes, elevation summaries.

Video + Social Layer
    •    60 FPS capture with AVFoundation filters (Normal, VHS, Speed Overlay).
    •    Feed with clips, route cards, pins, moderation/flagging.
    •    Background upload queue via BackgroundUploadService.

Growth, Challenges & Monetization
    •    StoreKit 2 freemium → Pro (offline packs, overlays, premium spots).
    •    Consumables for events; Apple Pay/Stripe for merch + tickets.
    •    Weekly challenges, leaderboards, badges, referrals (deep links: skateroute://).
    •    Privacy-respecting ads (contextual only).

Accessibility & Brand
    •    Dynamic Type, VoiceOver labels, high contrast, large tap targets.
    •    Welcoming, skate-savvy tone; no gatekeeping.

⸻

Non-Negotiable Principles
    1.    Respect the architecture. Extend, don’t fork. Register new services in AppDI. Keep view models thin.
    2.    SwiftUI first, MapKit-aware. UIKit only for bridges (MapViewContainer, custom renderers).
    3.    Async clarity. Prefer async/await; propagate cancellation; never block main thread.
    4.    Telemetry is sacred. Maintain fidelity in RideRecorder, Matcher, MotionRoughnessService. Schema changes must be backward-compatible.
    5.    User trust. Privacy, accessibility, low-distraction UX. Haptics + voice cues ship together.
    6.    No secrets in code. Keys belong in CI/config. Lint fails on token exposure.

⸻

Architecture & Project Structure

Style: Swift + SwiftUI. Combine for bridges; async/await for concurrency.
Pattern: MVVM + Coordinators + DI (TCA-friendly). TCA reducers allowed internally; MVVM outward-facing.

Project Layout

Core/            AppCoordinator, AppDI, shared domain orchestration
Services/        RouteService, RouteContextBuilder, ElevationService, Matcher,
                 MotionRoughnessService, SmoothnessEngine, SegmentStore,
                 SkateRouteScorer, RideRecorder, SessionLogger,
                 GeocoderService, AttributionService, CacheManager,
                 LocationManagerService, ChallengeService, LeaderboardService,
                 CheckInService, BadgeService, ReferralService, IAPService,
                 PaymentsService, BackgroundUploadService, HazardAlertService
Features/
  Home/          Entry points, search, recent routes, challenges widget
  Map/           MapScreen, MapViewContainer, SmoothOverlayRenderer, TurnCueEngine
  Navigate/      Ride HUD, cues, reroute, alerts
  Search/        PlaceSearchView & ViewModel (debounced MKLocalSearch)
  OfflinePacks/  Download/update/delete city packs
  Spots/         Discovery list/map, detail view, add-a-spot (private option)
  Social/        Capture, Edit, Upload Queue, Feed, Profile
  Commerce/      Paywall, IAP, Apple Pay/Stripe flows
  Settings/      Permissions, privacy, data export/delete, units, voice/haptics
DesignSystem/    Typography, color, icons, haptics, motion tokens
Support/         Utilities, previews, test fixtures, GPX/NDJSON logs
Docs/            Specs, ADRs, telemetry schemas, checklists

Swift Style
    •    Follow Swift API guidelines. Build clean with swift-format + swiftlint (warnings as errors).
    •    Document public types using ///.
    •    Services remain UI-free; communicate through protocols injected via AppDI.

⸻

Canonical Domain Contracts
    •    StepContext — gradePercent, roughnessRMS, brakingZone, surface, bikeLane, hazardScore, legalityScore, freshness.
    •    GradeSummary — maxGrade, meanGrade, climb, descent, brakeMask.
    •    RideMode — controls scoring + cue policy.
    •    SkateRouteScore — weighted composite; ride-mode dependent.
    •    Community Models: CheckIn, Challenge, LeaderboardEntry, Badge, Referral.

⸻

Navigation & Mapping Requirements
    •    Routing weights (defaults):
    •    Uphill penalty > 6%.
    •    Downhill braking alerts > 8% grade.
    •    Exclude rough/forbidden surfaces unless user opts-in.
    •    Traffic/crossings/hazard score adjust penalties.
    •    Fallback: Always provide accessibility route if walking/cycling rejected.
    •    Render: Color-banded overlays (butter → meh → crusty); dashed braking mask.
    •    Reroute: Trigger deviation > 25 m.
    •    Caching: City route tiles + hazard layers; managed via Offline Packs.
    •    Tests: Validate distance, ETA, skateability, braking mask using fixtures.

⸻

Hazard Intelligence & Alerts
    •    Ingest: Debounce, dedupe via geohash, reconcile with trusted feeds.
    •    Trust: Reporter reputation with decay; expose confidence state.
    •    Alerts: Multimodal — voice (during nav), haptic always, visual toast.

⸻

Performance & Reliability Targets
    •    Route compute < 250 ms.
    •    Map panning/overlay animations at 60 FPS.
    •    First route ≤ 1.5 s (goal: 1.2 s with warm cache).
    •    Ride recorder energy ≤ 8%/hr on A16-class devices.
    •    Hazard alert latency ≤ 300 ms.
    •    Crash-free users ≥ 99.5%.

⸻

Offline, Battery & Network Expectations
    •    Offline packs include polylines, attributes, elevation summaries; respect ETag/timestamps.
    •    Test airplane mode + throttled networks before release.
    •    Background uploads + hazard polling back off on low battery or constrained network.

⸻

Accessibility, Copy & Brand Guardrails
    •    Dynamic Type, VoiceOver labels, synced haptics + voice cues.
    •    Tone: upbeat, inclusive, skate-savvy. Highlight underrepresented skaters and accessible spots.
    •    Night-safe palettes for HUD; keep ride UI low-distraction.

⸻

Quality Gates (Blocking)
    1.    Static analysis: swiftlint clean; swift-format applied; no stray print.
    2.    Tests: Coverage updated.

xcodebuild -scheme SkateRoute \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test


    3.    Manual matrix: Routing; ride start/stop; recolor overlays; hazard report; offline pack lifecycle; geofence flows; challenges; referrals.
    4.    Performance: Validate routing budgets; monitor 20-min ride CPU/memory/energy.
    5.    Docs: README.md, WHITEPAPER.md, and this charter remain aligned.

⸻

Workflow & Tooling
    •    Branches: Conventional commits (feat:, fix:, perf:, docs:, chore:).
    •    PR Expectations:
    •    Link issue with acceptance criteria.
    •    Passing CI tests.
    •    QA checklist (offline, device matrix, regressions).
    •    Screenshots or clips for UI changes.
    •    Start PR description with trade-offs + open questions.
    •    Merge: Prefer Squash and merge to keep main clean.
    •    Commit messages: Imperative mood (“Add”, “Refine”).

⸻

Merge Strategy & Branch Discipline

Goal: Keep main clean, readable, and stable while allowing Codex and humans to iterate aggressively on feature branches.

Default Rules
    1.    Squash and merge (DEFAULT)
    •    Used for:
    •    All Codex PRs (codex/<short-desc>).
    •    Most human feature branches (feat/..., fix/...).
    •    Result: one clean commit on main.
    •    Examples:
    •    feat: adopt shared accuracy profile model
    •    fix: stabilize navigation warm-up hook
    2.    Merge commit (for major collaborative work)
    •    Use when:
    •    Multiple developers work on a long-lived branch.
    •    Internal commit history matters.
    •    Integrating recovery or release branches.
    •    Preserves full commit graph.
    3.    Rebase and merge (DO NOT USE in GitHub UI)
    •    If needed, rebase locally:

git fetch
git rebase origin/main


    •    Force-push only if you’re the sole owner of the branch.

Branching Expectations
    •    Main
    •    Always green.
    •    Changes land only via PR.
    •    Codex PRs target main unless working on recovery/release.
    •    Feature Branches
    •    Named: feat/, fix/, perf/, chore/, docs/.
    •    Short-lived; merged with Squash and merge.
    •    Codex Branches
    •    Named: codex/<short-desc>.
    •    Always squashed into main.
    •    PR title becomes final commit title.
    •    Recovery / Large Refactors
    •    Example: recovery/xcode-reload-20251110-211358.
    •    Regularly pull from main.
    •    When stabilized, PR back to main:
    •    Squash for noisy branches.
    •    Merge commit for structured integration.

Local Sync After a Codex PR
    1.    Merge Codex PR into main on GitHub (prefer Squash and merge).
    2.    Locally:

git checkout main
git pull origin main


    3.    If working on another branch:

git checkout <branch>
git merge main



⸻

Testing Strategy
    •    Unit: scorer monotonicity; elevation sampling; braking mask; matcher tolerance; referral parsing; IAP receipts (mocked); challenges/leaderboards; offline pack lifecycle.
    •    Snapshot: SmoothOverlayRenderer overlays vs fixtures.
    •    UI/XCUITest: routing flow; ride start/stop; hazard toast; check-in; challenge join; leaderboard; referral deep links; purchase/restore; offline pack download.
    •    Performance: route compute; capture pipeline throughput; background upload queue.
    •    Offline/Low-bandwidth: airplane mode + throttled networks.
    •    Device matrix: last three iOS versions; smallest (SE) + largest (Pro Max).

⸻

Observability & Telemetry
    •    Use os.Logger categories: routing, elevation, matcher, recorder, overlay, privacy, commerce, growth, deeplink, moderation.
    •    SessionLogger writes NDJSON lines; log export path on ride stop.
    •    Avoid raw lat/lon in analytics unless user opts in; bucketize/hash otherwise.

⸻

Configuration & Feature Flags
    •    Shared config: App-Shared.xcconfig.
    •    Feature flags:
    •    FEATURE_CHALLENGES
    •    FEATURE_REFERRALS
    •    FEATURE_OFFLINE_PACKS
    •    FEATURE_VIDEO_FILTERS
(All ON by default for 1.0.)

⸻

Security & Privacy
    •    No third-party tracking SDKs.
    •    Location & Motion strictly for navigation + safety.
    •    Commerce flows must include clear copy; Apple Pay/Stripe for physical goods only.
    •    Deep-links and referrals must protect user data; fail gracefully.

⸻

Do / Don’t Checklist

Do
    •    Extend services via protocols; keep SwiftUI out of service layers; wire via AppDI.
    •    Localize strings; surface user-facing errors via view models; log through SessionLogger.
    •    Add tests + docs alongside code.
    •    Snapshot overlays when feasible.
    •    Respect OS availability checks (#available(iOS 18+, *)).

Don’t
    •    Mix UI with business logic or block the main thread.
    •    Rename canonical types (StepContext, RideMode, SkateRouteScore, etc.) without ADR + migration.
    •    Add heavy dependencies without justification.
    •    Ship placeholder privacy content.

⸻

Quick Start for New Agents
    1.    Open SKATEROUTE.xcodeproj and run the SkateRoute scheme.
    2.    Home → set origin/destination → view color-banded route + grade summary.
    3.    Start a ride → roughness recolors steps; braking dashes appear; stop → NDJSON saved.
    4.    Explore Search, Offline Packs, Challenges, Referrals.
    5.    Run tests via ⌘U; simulate rides using GPX fixtures in Support/TestData.

⸻

Acceptance Examples
    •    Downhill caution: −8% grade over ≥50 m → dashed braking + pre-turn haptic.
    •    Reroute: deviation >25 m → new route within 2 seconds.
    •    Monotonicity: rougher steps never outscore smoother ones.
    •    Check-in: entering spot geofence and confirming increments challenges.
    •    Referral: skateroute://challenge/<id> opens challenge detail; respects consent.
    •    Commerce: purchase/restore toggles Pro entitlements; Apple Pay limited to physical goods.
    •    Offline Pack: download/update/delete flows respect storage warnings + cache invalidation.
