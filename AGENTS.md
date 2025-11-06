

# SkateRoute Agent Charter & Engineering Guidelines

## Mission
Ship the world’s smoothest, safest, most hype **skateboard-first** navigation and social app for iPhone. Every change must move SkateRoute toward an App Store–ready release with production-quality code, resilient architecture, and rigorous validation. No drama, just results.

---

## Product North Star
- **Primary Goal:** Frictionless, **elevation-aware** navigation with **real-time hazard intelligence** tailored to skateboards and small-wheel micromobility.
- **User Pillars (every change must map to ≥1 and not regress others):**
  1. **Safety:** Hazard detection, fall prevention, redundant alerts (visual + haptic + voice).
  2. **Flow:** Smooth turn-by-turn guidance optimized for skate-friendly surfaces and gradients.
  3. **Community:** Effortless capture, curation, and discovery of lines, clips, spots, and meetups.
  4. **Performance:** Native, battery-efficient, offline-tolerant experiences.

---

## Final Product Scope (1.0 complete)
**Skate-Optimized Navigation**
- Grade-aware + surface-aware routing (MapKit first), per-step skateability coloring, braking dashes for steep downhills, live ETA/distance, reroute on deviation.
- Ride modes: `smoothest`, `chillFewCrossings`, `fastMildRoughness`, `nightSafe`, `trickSpotCrawl`.

**Hazard Detection & Alerts**
- Crowdsourced hazards (potholes, gravel, tram tracks, glass, wet leaves) with trust weighting and time decay.
- Geofenced entry/exit alerts; background-safe delivery during rides; confidence visualization.

**Spots & Discovery**
- Built-in directory of skateparks/plazas/DIYs and community pins; clustering; one-tap directions; optional private spots.

**Ride Recording & Telemetry**
- On-device motion roughness (RMS), GPS matcher, stability meter; private NDJSON ride logs exportable by the user.

**Video + Social**
- 60 FPS when possible; AVFoundation filters (Normal, VHS, Speed Overlay). Background upload queue (BackgroundTasks).
- Feed with clips, route cards, spot pins; moderation hooks (flagging, shadow ban, unsafe-content checks).

**Growth & Monetization**
- **StoreKit 2** freemium → Pro (offline packs, advanced overlays, premium spots); consumables for event passes.
- **Apple Pay / Stripe** for merch + event tickets (no paywalling digital features outside IAP).
- Privacy-respecting house/network ads (contextual only). Referrals via universal deep links with safe onboarding.

**Offline & Reliability**
- Offline route packs (polyline + step attributes + elevation summary) and cached tiles per city; ETag/timestamp invalidation.

**Accessibility & Brand**
- Big tap targets, Dynamic Type, VoiceOver labels, high contrast; vibe is welcoming, skate-savvy, never gatekeepy.

---

## Non-Negotiable Principles
1. **Respect the architecture.** Extend, don’t fork. Register new services in `AppDI`. Keep view models thin.
2. **SwiftUI first, MapKit-aware.** UIKit lives only in bridges like `MapViewContainer` / custom renderers.
3. **Async clarity.** Prefer `async/await`. Propagate cancellation. Never block main.
4. **Telemetry is sacred.** Maintain data fidelity in `RideRecorder`, `Matcher`, `MotionRoughnessService`. Migrations must be backward-compatible.
5. **User trust.** Privacy, accessibility, and low-distraction UX are first-class. Haptics + voice cues ship together.
6. **No secrets in code.** Keys live in CI or configuration; lint fails on token leaks.

---

## Architecture & Project Structure
**Style:** Swift + SwiftUI. Combine acceptable for bridges; `async/await` for concurrency.

**Pattern:** MVVM + Coordinators + DI (TCA-friendly). Feature modules may embed TCA reducers internally while exposing MVVM façades to the app layer.

**Project layout**
```
Core/            Domain logic (routing, scoring, hazard models, analytics schemas)
Services/        RouteService, RouteContextBuilder, ElevationService, GeocoderService,
                 MotionRoughnessService, Matcher, CacheManager, SessionLogger, SkateRouteScorer
Features/
  Home/          Entry, search, recent routes, challenges widget
  Map/           MapScreen, MapViewContainer (UIKit bridge), SmoothOverlayRenderer, TurnCueEngine
  Navigate/      Ride HUD, cues, reroute, alerts
  Spots/         Discovery list, detail, add-a-spot flows
  Social/        Capture, Edit, Upload Queue, Feed, Profile
  Commerce/      Paywall, IAP, Apple Pay/Stripe flows
  Settings/      Permissions, privacy, data export/delete
DesignSystem/    Typography, color, iconography, haptics, motion
Support/         Utilities, previews, test fixtures, GPX
Docs/            Specs, ADRs, telemetry schemas, checklists
```

**Swift style**
- Swift API Design Guidelines. Warnings as errors. `swift-format` + `swiftlint` clean.
- Public types documented with `///` summarizing purpose and invariants.

---

## Canonical Domain Contracts (stable across modules)
- `StepContext`: `gradePercent`, `roughnessRMS`, `brakingZone`, `surface`, `bikeLane`, `hazardScore`, `legalityScore`, `freshness`.
- `GradeSummary`: `maxGrade`, `meanGrade`, `climb`, `descent`, `brakeMask`.
- `SkateRouteScore`: weighted composite; ride-mode dependent with monotonicity tests.
- `RideMode`: enum (see above) affecting `SkateRouteScorer` weighting and cue policy.

---

## Navigation & Mapping Requirements
- **Routing weights (defaults):**
  - Uphill: penalize > **6%**; downhill braking warnings at > **8%**.
  - Rough/forbidden surfaces excluded unless user opts-in.
  - Traffic/crossings and hazard score factor into step penalties.
- **Fallback:** Always provide an accessibility route if rejecting walking/cycling defaults.
- **Render:** Multi-segment overlays by color band (butter → meh → crusty). Braking shown as dashed mask atop polyline.
- **Reroute:** Trigger when user deviates > **25 m** from nearest polyline point.
- **Caching:** Route tiles + hazard layers cached per city; ETag/timestamp invalidation; offline pack management UI.
- **Tests:** Geospatial changes require fixtures validating distance, ETA, and skateability score.

---

## Hazard Intelligence
- **Ingest:** Debounce, dedupe via geohash, reconcile with authoritative feeds. Store provenance (source, timestamp, confidence).
- **Trust:** Reporter reputation with time decay; display confidence state in UI.
- **Alerts:** Multimodal (voice if navigating, haptic always, visual toast). Never rely on sound alone.
- **Privacy:** Anonymize contributors by default; never expose reporter identity without consent.

---

## Video & Social Platform
- **Capture:** Target 60 FPS; degrade gracefully with user notice. Filters: Normal, VHS, Speed Overlay (GPU-efficient).
- **Uploads:** BackgroundTasks; resumable; exponential backoff; user-visible state.
- **Feed:** Moderation hooks (flagging, shadow list, automated checks). Geo-tagged clips link to routes; private spot preference respected.

---

## Growth Engine (ethical by design)
- **Referrals:** Universal links → deep-link onboarding; reward cosmetic themes/badges (no pay-to-win).
- **Challenges & Leaderboards:** Weekly distance/elevation; anti-cheat via motion heuristics.
- **Shareables:** Auto-generate route snapshots, safe linkbacks to in-app route.

---

## Privacy, Security & Compliance
- **Permissions:** When-In-Use (Always only if background rides). Temporary precise location with clear rationale.
- **Storage:** Keychain for creds; encrypt cached hazard/video metadata.
- **Data rights:** GDPR/CCPA export/delete flows in Settings; on-device by default; upload only with consent.
- **Transport:** HTTPS/TLS 1.2+; certificate pinning for first-party APIs.
- **Analytics:** Opt-in beyond essential telemetry; bucketized/hashed coordinates—no raw lat/lon in analytics.

---

## Observability & Telemetry
- **Logger categories:** `routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`, `commerce`.
- **SessionLogger:** NDJSON with schema versioning; retention policy documented in `docs/telemetry.md`.
- **KPIs:** DAU/MAU, route success rate, reroute frequency, hazard report conversion, video uploads, share events, Pro conversion.

---

## Performance Budgets (engraved in grip tape)
- **Cold start:** ≤ **1.2 s** on flagship; graceful on SE-class.
- **Energy (active nav):** ≤ **8%/hr** (stretch 4%/hr with overlay throttling).
- **GPS drift (median):** ≤ **8 m** with adaptive filters.
- **On-device nav ops latency:** < **150 ms** on UI thread.
- **CPU:** < **12%** sustained during rides; **Memory** headroom > **150 MB**.

---

## Testing & Quality Assurance
- **Unit:** 90%+ coverage in `Core` and `Services` (scorer monotonicity, elevation sampling, matcher tolerance, reducers).
- **Snapshot/UI:** Map overlays pixel-stable for fixed route JSON; XCUITest for nav flows, camera UI, feed interactions.
- **Performance:** Route compute < **250 ms** typical urban; video pipeline throughput at target FPS.
- **Offline & Low-Bandwidth:** Airplane mode + throttled networks before each release.
- **Device Matrix:** Last three iOS versions; smallest (SE) and largest (Pro Max). Document exceptions.
- **Crash-Free Goal:** ≥ **99.5%** users per release.

---

## Quality Gates (blocking)
1. **Static analysis:** `swiftlint` clean; warnings as errors. No stray `print`.
2. **Tests:** Add tests with new code. `xcodebuild -scheme SkateRoute -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test` green.
3. **Manual matrix:** Routing; ride start/stop; overlay recolor; quick hazard report; offline pack use; background/termination geofence flows.
4. **Performance:** 20-min ride profiles (CPU/mem/energy); no main-thread hitches.

---

## Release Management
- **Cadence:** 4-week trains with hotfix lane.
- **Pre-release checklist (attach to release PR):**
  1. Version bump (`Info.plist`, `Fastfile`).
  2. Regression suite across target locales.
  3. App Store metadata validated (localized keywords, screenshots).
  4. Privacy nutrition/data safety updated.
  5. Go/No-Go sign-off (Product, Engineering, Community).
- **TestFlight:** Maintain beta cohort, collect structured feedback weekly, triage publicly.

---

## Documentation Expectations
- Keep `README.md`, onboarding, and in-app flows in sync.
- ADRs for major decisions (`docs/adr/ADR-XXXX-title.md`).
- Telemetry schemas + retention policy in `docs/telemetry.md`.
- Validation scripts/schemas for any data files (e.g., `attrs-*.json`, tiles).

---

## Workflow & Tooling
- **Branches:** Conventional commits (`feat:`, `fix:`, `perf:`, `docs:`, `chore:`).
- **PRs must include:**
  - Linked issue with acceptance criteria.
  - Passing automated tests (CI).
  - QA checklist (offline, device matrix, regressions).
  - Screenshots or short clips for UI changes.
- **Merge:** Squash to keep `main` clean.

---

## Collaboration Rituals
- Commit messages in imperative mood (“Add”, “Refine”).
- PRs start with **trade-offs/open questions**.
- Prefer small, reviewable increments; split milestone PRs when scope is large.
- All UI changes include before/after captures.
- Respect availability checks (`#available(iOS 18+, *)`) for MapKit 2025 APIs.

---

## UI Surfaces (reference)
- **Home:** Search bar, recents, challenges widget, CTA to go Pro; referral card.
- **Map:** Destination card, multi-route options, color-banded polyline, hazard/spot toggles.
- **Ride HUD:** Large next-turn, distance, ETA, speed, braking indicator; low-distraction theme; voice + haptic cues.
- **Spots:** Map/list, filters, detail with media and directions; add-a-spot with privacy option.
- **Capture/Edit:** Filter presets, trim, speed overlay; upload state with background resiliency.
- **Feed:** Clips + route cards; moderation actions; share to socials.
- **Profile:** Stats, badges, routes, videos; privacy controls; data export/delete.
- **Commerce:** Paywall (Pro features), Manage Subscriptions, Apple Pay/Stripe checkout for physical goods.
- **Offline Packs:** City selectors, pack storage size, update cadence, delete.
- **Settings:** Permissions, units, voice/haptics, analytics opt-in, legal.

---

## Monetization Details (StoreKit 2)
- **IAP IDs (placeholders):**
  - `com.skateroute.pro.monthly`
  - `com.skateroute.pro.yearly`
  - `com.skateroute.event.pass.<slug>`
- **Entitlements:** Unlock offline packs, advanced overlays, premium spots. Event passes time-bound.
- **Policies:** Apple Pay/Stripe only for physical goods/services. No tracking walls. Clear restore purchases.

---

## SLOs
- 60 FPS map pan/overlay animations.
- Median time to first route: ≤ **1.5 s** with cache warm.
- Hazard alert latency: ≤ **300 ms** from geofence enter to UI cue.

---

## Do / Don’t
**Do**
- Extend services via protocols; keep SwiftUI out of services; wire via `AppDI`.
- Localize strings; pipe user errors via view models; log via `SessionLogger`.
- Add tests + docs with your code; snapshot overlays where feasible.

**Don’t**
- Mix UI with business logic, block the main thread, or rename canonical types.
- Add heavy deps without justification; never YOLO privacy strings or permissions.

---

## Quick Start for New Agents
1. Open **SKATEROUTE.xcodeproj** and run **SkateRoute**.
2. Home → set origin/destination → Map renders color-banded route + grade summary.
3. Start ride → roughness updates recolor steps; braking dashes show; stop → NDJSON path saved.
4. Run tests with `⌘U`. Simulate with bundled GPX fixtures under `Support/TestData`.

---

## Acceptance Examples
- A **−8%** grade over **≥50 m** must display braking dashes and trigger a pre-turn haptic.
- Rougher steps can never score higher than smoother ones, all else equal (monotonicity).
- Deviations > **25 m** from route polyline must request a reroute within **2 s**.

---

## Community & Brand Alignment
- Upbeat, inclusive copy. Highlight underrepresented skaters and accessible spots.
- Respect local laws and community norms in suggestions. No gatekeeping, ever.
- Gamified check-ins, weekly challenges, leaderboards, and badges (e.g., “100 km with SkateRoute”). Referral links with deep-link onboarding.

---

By following this playbook, agents operate at peak effectiveness and keep SkateRoute crisp, safe, and App Store–ready—so riders can lock in lines and vibe, anywhere.