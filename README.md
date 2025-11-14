

# SkateRoute (iOS) — Final 1.0

SkateRoute is a **skateboard‑first navigation + social** app. It delivers grade‑aware routing, real‑time hazard alerts, offline reliability, and a creator‑friendly social layer. This README reflects the **complete, App Store–ready** 1.0 scope aligned with the consolidated `AGENTS` charter.

> TL;DR: SwiftUI + MapKit, MVVM/Coordinators/DI, StoreKit 2 monetization, privacy‑respecting analytics, and a skater‑centric UX. Battery‑light, glanceable, and built for flow.

---

## Table of Contents
- [Product Overview](#product-overview)
- [Key Features](#key-features)
- [UX Surfaces](#ux-surfaces)
- [Architecture](#architecture)
- [Module Map](#module-map)
- [Data Contracts](#data-contracts)
- [Performance Budgets](#performance-budgets)
- [Setup & Build](#setup--build)
- [Permissions & Privacy](#permissions--privacy)
- [Monetization](#monetization)
- [Offline Packs](#offline-packs)
- [Testing](#testing)
- [CI/CD](#cicd)
- [Release Checklist](#release-checklist)
- [Telemetry](#telemetry)
- [Contributing](#contributing)
- [FAQ](#faq)

---

## Product Overview
**North Star:** Frictionless, elevation‑aware navigation with real‑time hazard intelligence for skateboards and small‑wheel micromobility—wrapped in a safe, inclusive community.

**Pillars**
1) Safety • 2) Flow • 3) Community • 4) Performance

---

## Key Features
**Skate‑Optimized Navigation**
- MapKit‑based routes scored by **grade**, **surface**, **crossings**, and **hazard** signals.
- Per‑step coloring (butter → meh → crusty), **braking dashes** for steep downhills, live ETA & distance.
- **Reroute** when deviating > **25 m** from the route.
- **Ride Modes**: `smoothest`, `chillFewCrossings`, `fastMildRoughness`, `nightSafe`, `trickSpotCrawl`.

**Hazard Intelligence**
- Crowdsourced hazards (potholes, gravel, tram tracks, wet leaves, glass) with **trust weighting** and **time decay**.
- **Geofenced** entry/exit alerts; multimodal delivery (voice while navigating, haptic by default, visual toast).

**Spots & Discovery**
- Built‑in map of skateparks/plazas/DIYs and community pins; clustering; one‑tap directions; private spot option.

**Ride Recording & Telemetry**
- On‑device **roughness (RMS)**, GPS **matcher**, stability meter; **NDJSON** ride logs private by default.

**Video & Social**
- 60 FPS‑target capture (graceful degrade), GPU‑efficient filters (**Normal, VHS, Speed Overlay**).
- Background uploads with `BackgroundTasks`, resumable queue; moderation hooks (flag/shadow/automated checks).

**Growth & Community**
- **Gamified check‑ins, weekly challenges, leaderboards, and badges** (e.g., *“100 km with SkateRoute”*).
- **Referral links** with **deep‑link onboarding** directly into community flows and spot invites.

**Monetization**
- **StoreKit 2** freemium → Pro (offline packs, advanced overlays, premium spots); event passes as consumables.
- **Apple Pay / Stripe** for **physical** merch & event tickets (digital features stay IAP‑gated only).
- Privacy‑respecting contextual ads (no tracking walls).

**Offline & Reliability**
- City‑scoped **offline route packs** (polyline + step attributes + elevation summary) and cached tiles; ETag/timestamp invalidation.

**Accessibility**
- Dynamic Type, VoiceOver, high‑contrast theme, **large hit targets**, low‑distraction ride HUD.

---

## UX Surfaces
- **Home (Features/Home):** search, recents, challenges widget, referral card.
- **Map (Features/Map):** destination card, multi-route options, color-banded polyline, hazard/spot toggles.
- **Ride HUD (Features/UX):** next-turn emphasis, braking indicator, live speed; voice + haptic cues.
- **Spots (Features/Spots):** map/list, filters, detail with media, add-a-spot with privacy.
- **Capture/Edit (Features/Media):** filters, trim, speed overlay; background upload state.
- **Feed (Features/Feed):** clips + route cards; moderation actions; system share.
- **Profile (Features/Profile):** stats, badges, routes, videos; privacy controls; data export/delete.
- **Monetization (Features/Monetization):** paywall, manage subscriptions; Apple Pay/Stripe checkout hooks.
- **Offline Packs (Services/Offline, UI pending):** route pack lifecycle wired through services; dedicated feature shell to be scheduled.
- **Settings (Features/Settings):** permissions, units, voice/haptics, analytics opt-in, legal.

---

## Architecture
**Style:** Swift + SwiftUI; `async/await`; MVVM + Coordinators + Dependency Injection (TCA‑friendly inside features). UIKit is isolated to MapKit bridges and custom renderers.

**Principles**
- Services expose protocols; view models are thin; views remain declarative.
- Telemetry fidelity is sacred; schema changes include migrations and back‑compat.
- No secrets in code; lint/CI blocks token leaks.

---

## Module Map
```
Core/            Domain orchestration (AppDI, AppCoordinator, policy, entitlements)
Services/        Navigation, Offline, StoreKit, Media, Hazards, Rewards, Referrals, Logging, System
Features/
  Home/          Entry, search, recents, challenges widget
  Map/           Route planning, overlays, planner view model
  UX/            Ride HUD, turn cues, ride telemetry surfaces
  Search/        Place search view + debounced MKLocalSearch view model
  Spots/         Discovery list, detail, add-a-spot flows
  Media/         Capture, editor, background upload bridges
  Feed/          Clip feed, moderation actions
  Community/     Quick hazard reporting, surface ratings
  Monetization/  Paywall + subscription management (commerce UI)
  Settings/      Permissions, privacy, data export/delete
Support/         Utilities, previews, test fixtures, GPX
Docs/            Specs, ADRs, telemetry schemas, checklists
```

---

## Data Contracts
- `StepContext`: `gradePercent`, `roughnessRMS`, `brakingZone`, `surface`, `bikeLane`, `hazardScore`, `legalityScore`, `freshness`
- `GradeSummary`: `maxGrade`, `meanGrade`, `climb`, `descent`, `brakeMask`
- `SkateRouteScore`: ride‑mode‑weighted composite with monotonicity tests
- `RideMode`: influences scorer weights and cue policy

---

## Performance Budgets
- **Cold start:** ≤ **1.2 s**
- **Active nav energy:** ≤ **8%/hr** (stretch 4%/hr with overlay throttling)
- **GPS drift (median):** ≤ **8 m**
- **Nav ops latency (UI thread):** < **150 ms**
- **CPU:** < **12%** sustained; **Memory** headroom > **150 MB**

---

## Setup & Build
**Requirements**
- Xcode 17.x or newer, iOS 17+ deployment target
- CocoaPods not required; SPM only
- Ruby (for Fastlane) if you plan to ship via CI

**Project**
- Open `SKATEROUTE.xcodeproj` and run the **SkateRoute** scheme.
- Config lives in `App-Shared.xcconfig`. For local overrides, create `App-Local.xcconfig` (ignored by VCS) and include only non‑secret tweaks.

**Lint/Format**
```bash
swiftlint # uses ./swiftlint.yml
swift-format --configuration .swift-format.json --in-place --recursive .
```

**Simulating Rides**
- Use bundled GPX files under `Support/TestData` to validate overlays, cues, and reroute.

---

## Permissions & Privacy
**Info.plist keys** (typical)
- `NSLocationWhenInUseUsageDescription` (Always only if background rides)
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSMotionUsageDescription`
- `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`
- `BGTaskSchedulerPermittedIdentifiers` for upload/refresh tasks

**Stance**
- On‑device by default. Export only with user intent. No third‑party tracking SDKs.
- Privacy Manifest declares Location/Motion as functionality‑critical.

---

## Monetization
**StoreKit 2 SKUs**

| SKU | Purpose |
| --- | --- |
| `com.skateroute.app.pro.offline` | Offline packs entitlement |
| `com.skateroute.app.pro.analytics` | Advanced analytics entitlement |
| `com.skateroute.app.pro.editor` | Pro editor entitlement |
| `com.skateroute.app.pro.monthly` | SkateRoute Pro monthly subscription |
| `com.skateroute.app.pro.yearly` | SkateRoute Pro yearly subscription |
| `com.skateroute.app.pro.lifetime` | Lifetime unlock (non-renewing) |
| `com.skateroute.event.pass.<slug>` | Event-specific consumables |

**Entitlements**
- Pro unlocks offline packs, advanced overlays, premium spots. Event passes are time‑bound.

**Payments**
- **Apple Pay/Stripe** only for **physical goods/services** (merch, tickets). Digital features remain IAP‑gated.

---

## Offline Packs
- City‑level downloads include polylines, per‑step attributes, elevation summaries.
- Cache invalidation via ETag or timestamp; user controls updates and deletion.

---

## Testing
**Targets**
- Unit (Core/Services ≥ 90% coverage): scorer monotonicity, elevation sampling, matcher tolerance, reducers
- Snapshot/UI: overlay images are pixel‑stable for fixed route JSON; XCUITest for nav/camera/feed
- Performance: route compute < **250 ms** typical urban; capture pipelines sustain target FPS
- Offline/Low‑bandwidth: airplane mode + throttled networks prior to each release
- Device matrix: last three iOS versions; smallest (SE) + largest (Pro Max)

**Commands**
```bash
xcodebuild -scheme SkateRoute -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

---

## CI/CD
- GitHub Actions: build + tests on PR, archive on `main`.
- Fastlane: beta distribution to TestFlight. Crash‑free goal ≥ **99.5%** users per release.

---

## Release Checklist
1. Version bump (`Info.plist` / Fastlane).
2. Full regression across target locales and device matrix.
3. App Store metadata (localized copy, screenshots) updated.
4. Privacy nutrition/data safety forms reviewed.
5. Go/No‑Go sign‑off: Product • Engineering • Community.

---

## Telemetry
- `os.Logger` categories: `routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`, `commerce`.
- `SessionLogger`: NDJSON with schema versioning.
- KPIs: DAU/MAU, route success, reroute frequency, hazard report conversion, video uploads, shares, Pro conversion.

See: [`AGENTS`](./AGENTS) for the canonical agent charter & engineering guardrails.

---

## Contributing
- Conventional commits (`feat:`, `fix:`, `perf:`, `docs:`, `chore:`). Squash merges.
- Every PR: linked issue w/ acceptance criteria, green tests, QA checklist, and UI screenshots/clips where relevant.
- ADRs for significant decisions under `Docs/adr/ADR-XXXX-title.md`.
- Inclusive tone; respond to reviews within 2 business days.

---

## FAQ
**Why MapKit first?** Best native perf, energy, and privacy; 1st‑party fit with SwiftUI and on‑device processing. Mapbox/Google can be added behind feature flags if required by partners.

**Do I need an account to ride?** No. Core nav works without login. Social and cloud backup are opt‑in.

**What about referrals?** Referral links (universal links + `skateroute://`) deep‑link straight into community and challenge flows.

---

## License
© SkateRoute. All rights reserved. See repository license file if present.