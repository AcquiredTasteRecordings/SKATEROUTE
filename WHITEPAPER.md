# SkateRoute — Whitepaper (v1.0)

**Document type:** Product & Technical Whitepaper  
**Target:** Engineering, Product, Design, Security, and Operations  
**Platform:** iOS (Swift/SwiftUI, MapKit-first)  
**Release:** 1.0 (App Store–ready)  
**Date:** 2025-11-05

---

## 0. Executive Summary
SkateRoute is a skateboard‑first navigation and social platform that fuses **grade‑aware routing**, **real‑time hazard intelligence**, and a **creator‑friendly video community**. It delivers safe, smooth paths for skaters and small‑wheel micromobility—optimized for battery life, glanceability, and offline reliability. The 1.0 release is production‑complete, privacy‑respecting, and aligned to App Store policies.

**North Star:** Frictionless, elevation‑aware navigation with trustworthy, low‑distraction cues and a community that grows through ethical gamification and referrals.

**Core pillars:**
1) **Safety** · 2) **Flow** · 3) **Community** · 4) **Performance**

---

## 1. Market Thesis & Problem Statement
Urban riders lack navigation tuned for **small wheels**: typical walking/cycling data ignores surface roughness, micro‑hazards (gravel, rails, cracks), braking distances on steep downhills, and night safety. Skaters also want a **lightweight way to log rides, capture/share clips, and discover spots** without trading away privacy or battery.

SkateRoute solves this with a **skateability‑first** routing engine, **crowdsourced hazard graph** with trust weighting, and an **integrated social layer**—all built natively for iPhone.

---

## 2. Product Overview
**Key capabilities**
- **Skate‑Optimized Navigation:** MapKit directions enriched with grade, surface, hazard, and crossing costs; per‑step coloring and braking dashes; deviation‑aware rerouting.
- **Hazard Intelligence:** Debounced, deduped, provenance‑aware hazard reports with time decay and geofence alerts.
- **Spots & Discovery:** Parks, plazas, DIYs, and community pins with clustering and one‑tap directions.
- **Ride Recording & Telemetry:** On‑device roughness (RMS), GPS matcher, stability meter, private NDJSON logs.
- **Video & Social:** 60 FPS capture when available, GPU‑efficient filters, background upload queue, moderation hooks.
- **Growth & Community:** **Gamified check‑ins, weekly challenges, leaderboards, and badges** (e.g., *“100 km with SkateRoute”*). **Referral links** with deep‑link onboarding into community flows.
- **Monetization:** StoreKit 2 freemium → Pro (offline packs, advanced overlays, premium spots), event passes; Apple Pay/Stripe for physical goods; contextual ads without tracking.
- **Offline & Reliability:** City‑level offline route packs (polyline + attributes + elevation summary) and cached tiles; integrity via ETag/timestamps.
- **Accessibility:** Dynamic Type, VoiceOver, high contrast, large hit targets, low‑distraction HUD.

---

## 3. Requirements & SLOs
- **Cold start:** ≤ **1.2 s**  
- **Active nav energy:** ≤ **8%/hr** (stretch 4%/hr with overlay throttling)  
- **GPS drift (median):** ≤ **8 m**  
- **On‑device nav ops latency:** < **150 ms** on the UI thread  
- **Hazard alert latency (geofence→cue):** ≤ **300 ms**  
- **CPU:** < **12%** sustained; **Memory** headroom > **150 MB**  
- **Crash‑free users:** ≥ **99.5%** per release

---

## 4. System Architecture
**Language & UI:** Swift + SwiftUI (UIKit isolated to MapKit bridge/renderers).  
**Patterns:** MVVM + Coordinators + Dependency Injection (TCA allowed inside features).  
**Maps:** MapKit‑first; custom overlays for step coloring and braking masks.

**Module map**
```
Core/            Domain orchestration (AppCoordinator, AppDI, policy, entitlements)
Services/        Navigation, Offline, StoreKit, Media, Hazards, Rewards, Referrals, Logging, System
Features/
  Home/          Search, recents, challenges widget, referral card
  Map/           Route planning, overlays, planner view model
  UX/            Ride HUD, cues, reroute messaging, ride telemetry
  Search/        Place search view + debounced MKLocalSearch view model
  Spots/         Discovery list, detail, add-a-spot flows
  Media/         Capture, edit, upload queue bridges
  Feed/          Clip feed, moderation actions
  Community/     Quick hazard reporting, surface ratings
  Monetization/  Paywall + subscription management (commerce UI)
  Settings/      Permissions, privacy, data export/delete
Support/         Utilities, previews, test fixtures, GPX
Docs/            Specs, ADRs, telemetry schemas, checklists
```

**High‑level data flow**
```
LocationManager → Matcher → RouteService ┐
                               │        │
                 ElevationService        │
                 HazardStore  ───────────┼→ RouteContextBuilder → SkateRouteScorer → Map overlays/HUD
                                         │
                                      SessionLogger (NDJSON) → private device storage/export
```

---

## 5. Navigation Engine
### 5.1 Data Contracts (stable)
```swift
struct StepContext: Hashable {
  let gradePercent: Double
  let roughnessRMS: Double
  let brakingZone: Bool
  let surface: Surface
  let bikeLane: Bool
  let hazardScore: Double
  let legalityScore: Double
  let freshness: Double // 0..1 confidence time-decayed
}

struct GradeSummary { let maxGrade: Double; let meanGrade: Double; let climb: Double; let descent: Double }

enum RideMode { case smoothest, chillFewCrossings, fastMildRoughness, nightSafe, trickSpotCrawl }
```

### 5.2 Scoring (pseudocode)
```pseudo
w = weights(for: rideMode)

skateability(step) =
  w.grade   * fGrade(step.gradePercent) +
  w.surface * fSurface(step.surface, step.roughnessRMS) +
  w.hazard  * fHazard(step.hazardScore, step.freshness) +
  w.legal   * fLegality(step.legalityScore) +
  w.xings   * fCrossings(step) +
  w.lane    * fBikeLane(step.bikeLane)

brakingZone = step.gradePercent <= -8 && step.length >= 50m
```
**Invariant:** Rougher steps never score higher than smoother ones, all else equal (unit‑tested monotonicity).

### 5.3 Rerouting & Cues
- **Deviation:** Trigger reroute when user is > **25 m** from nearest polyline point.
- **Cues:** Voice + haptic at ~40 m and ~15 m; braking haptic when entering braking mask.

---

## 6. Hazard Intelligence
### 6.1 Intake & Reconciliation
- **Debounce** client submissions; **dedupe** via geohash; attach **provenance** (source, timestamp, device signals).
- **Reconcile** with authoritative feeds (where available). Store **confidence**; decay over time.

### 6.2 Trust & Confidence
- Reporter reputation increases with concordant reports; decays with time/outliers. UI conveys confidence state.

### 6.3 Alerts
- **Geofenced** entry/exit; delivery through haptic (default), visual toast, optional voice if navigating. Never rely on sound alone.

---

## 7. Social, Gamification & Community
- **Gamified check‑ins** at spots and along notable routes.
- **Weekly challenges & leaderboards** (distance, elevation, spots visited) with anti‑cheat motion heuristics.
- **Badges** including milestones like *100 km with SkateRoute*.
- **Referral links** (universal links + `skateroute://`) that **deep‑link** directly into community and challenge flows; safe onboarding and clear consent prompts.
- **Video feed** with capture/edit/share; moderation pipeline (flagging, shadow lists, automated checks). Users can mark spots **private**.

---

## 8. Offline Strategy
- **Offline route packs** per city: polyline, per‑step attributes, elevation summary; downloaded on Wi‑Fi by default.
- **Cache policy:** ETag/timestamp validation; user‑initiated updates; clear storage controls.
- **Behavior:** Routing + overlays work offline with packs; tiles fallback to cached areas. Online reconnection reconciles hazards.

---

## 9. Privacy, Security & Compliance
- **On‑device by default;** export only with user intent.
- **No third‑party tracking SDKs.** Analytics beyond essentials are **opt‑in**.
- **Identifiers & Data:** No raw lat/lon in analytics; use bucketized or hashed regions.
- **Permissions:** When‑In‑Use location; Always only for background rides. Temporary precise location with clear rationale.
- **Storage:** Keychain for credentials; encrypt cached hazard/video metadata where applicable.
- **Transport:** HTTPS/TLS 1.2+; certificate pinning for first‑party APIs.
- **Privacy Manifest:** Declares location/motion as functionality‑critical.
- **App Store compliance:** Digital features behind IAP (StoreKit 2). Apple Pay/Stripe **only** for **physical goods/services**.

---

## 10. Monetization & Economics
- **IAP (StoreKit 2):** `com.skateroute.app.pro.monthly`, `com.skateroute.app.pro.yearly`, `com.skateroute.event.pass.<slug>`.
- **Pro entitlements:** Offline packs, advanced overlays, premium spots; event passes time‑bound.
- **Payments:** Apple Pay/Stripe for merch & tickets; no gating of digital features outside IAP.
- **Ads:** Contextual, privacy‑respecting; no tracking walls.
- **Growth loops:** Referrals → deep‑linked onboarding; shareable route snapshots with safe return links.

---

## 11. Telemetry & Observability
- **Logger categories:** `routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`, `commerce`.
- **SessionLogger:** NDJSON with schema versioning and local retention; export path shown post‑ride.
- **KPIs:** DAU/MAU, route success rate, reroute frequency, hazard report conversion, video uploads, shares, Pro conversion.

**Data retention:** Minimal by default; configurable retention windows documented in `docs/telemetry.md`.

---

## 12. Performance Engineering
- **Pipelines:** Coalesce UI updates; throttle overlay redraw; offload heavy work to background actors.
- **Battery:** Prefer reduce/precise location modes adaptively; avoid unnecessary camera sessions.
- **Profiling:** 20‑min ride sessions on SE/Pro Max devices; alert on main‑thread hitches; budget regressions block release.

---

## 13. Testing & Validation
**Unit tests (Core/Services ≥ 90%):**
- Scorer monotonicity; elevation sampling; braking mask; matcher tolerance; reducers.

**UI/Snapshot:**
- Stable overlay rendering for fixed route JSON; XCUITest for nav, capture, feed, commerce.

**Performance:**
- Route compute < **250 ms** (typical urban); capture pipelines sustain device‑appropriate FPS.

**Offline & Low‑bandwidth:**
- Airplane mode + throttled networks before each release.

**Device matrix:**
- Last three iOS major versions; smallest (SE) and largest (Pro Max). Exceptions documented.

**Acceptance examples:**
- −8% grade over ≥50 m shows braking dashes + pre‑turn haptic.  
- Deviations >25 m trigger reroute within 2 s.  
- Rougher steps never outscore smoother ones, ceteris paribus.

---

## 14. Release, CI/CD & Governance
- **CI:** GitHub Actions—build/test on PR; archive on `main`. Fastlane → TestFlight cohort.
- **Quality gates:** Lint clean; unit/UI/perf tests green; 20‑min ride profiling attached.
- **Release train:** 4‑week cadence; hotfix lane. Crash‑free users ≥99.5%.
- **Checklist:** Version bump, device‑matrix regression, localized metadata, privacy forms, Go/No‑Go sign‑off (Product, Eng, Community).

---

## 15. Accessibility & Inclusion
- Dynamic Type, VoiceOver labels, high contrast themes, **44×44 pt** min hit targets.
- Low‑distraction HUD with voice + haptic parity. Inclusive, welcoming copy; no gatekeeping.

---

## 16. Risks & Mitigations
- **Map data gaps:** Provide accessibility fallback and user opt‑in for rough segments; enable quick hazard reporting.
- **Battery regressions:** Telemetry watchdog + feature flags to reduce polling/overlays in degraded mode.
- **Abuse/Content risk:** Moderation hooks, rate limits, community guidelines, and appeal path.
- **Privacy drift:** Regular audit; nutrition labels kept current; analytics opt‑in guarded by tests.

---

## 17. Roadmap (Post‑1.0, non‑blocking)
- Server‑side hazard reconciliation at city scale; richer trust graphs.  
- Event partnerships (check‑in quests, branded rewards) with transparent consent and export controls.  
- Optional partner map packs behind feature flags.

---

## 18. Glossary
- **Braking mask:** Visual overlay for steep downhill segments (typically ≤ −8% grade over ≥50 m).
- **Roughness (RMS):** On‑device vibration proxy for surface smoothness.
- **Skateability score:** Weighted composite of grade, surface, hazards, crossings, lanes, legality.
- **Offline pack:** City bundle of polylines + per‑step attributes + elevation summaries.

---

## 19. Appendices
**A. Deep Links**  
- Universal links domain (example): `https://links.skateroute.app`  
- App scheme: `skateroute://`  
- Examples: `skateroute://spot/<id>`, `skateroute://challenge/<id>`, `skateroute://refer/<code>`

**B. IAP Catalog (placeholders)**  
- `com.skateroute.app.pro.monthly`
- `com.skateroute.app.pro.yearly`
- `com.skateroute.event.pass.<slug>`

**C. Logger categories**  
`routing`, `elevation`, `matcher`, `recorder`, `overlay`, `privacy`, `commerce`

**D. References**  
- See repository: `README` (product & setup) and `AGENTS` (engineering guardrails).

---

**Status:** Finalized for 1.0. Changes to any stable contracts (`StepContext`, scoring weights, RideMode, telemetry schemas) require an ADR and test updates.
