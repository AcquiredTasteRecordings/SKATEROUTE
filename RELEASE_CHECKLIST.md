---
# Downhill Navigator — iOS **Release Checklist** (Investor- & Engineer‑Grade)

> Target: **SKATEROUTE** (iOS 17+), Devices: iPhone (A14–A18), Regions: Canada (pilot), City focus: **Victoria, BC**  
> Mission: deliver a **skateboard‑first navigation** app that **favors smooth, downhill, safe roads**, with accurate on‑device telemetry and compliant privacy.

This checklist is the single source of truth used by engineering, QA, and product before every TestFlight or App Store submission. **All boxes must be checked** (or have a signed waiver) for release.

---

## 0) Gatekeepers (must be zero)
- [ ] **Open P0/P1 bugs** in tracker: **0**.
- [ ] **CI red**: **0 workflows failing**.
- [ ] **App Review blockers** (privacy/permissions/metadata): **0**.
- [ ] **Crash-free session rate** on latest TF build: **≥ 99.5%**.

---

## 1) Versioning & CI
- [ ] **Marketing version** (e.g., `1.0.0`) bumped.
- [ ] **Build number** incremented (monotonic).
- [ ] **Git tag** created: `v{marketing}-{build}`.
- [ ] **CHANGELOG.md** updated (user-facing + technical).
- [ ] **CI matrix green**: Xcode **16.4**, iOS **17.6** & **18.5** simulators.
- [ ] Unit tests ✅ (`xcodebuild test`).
- [ ] UI smoke ✅ (critical flows via `xcodebuild test-without-building` or XCUITests).
- [ ] **Archive** reproducible:  
  ```sh
  xcodebuild \
    -scheme SKATEROUTE \
    -configuration Release \
    -sdk iphoneos \
    -archivePath build/SKATEROUTE.xcarchive \
    clean archive
  ```

---

## 2) Capabilities & Entitlements
- [ ] **Background Modes** → *Location updates* enabled.
- [ ] **Location** → *When In Use* + *Always & When In Use* (for screen-off guidance).
- [ ] **Motion & Fitness** (CoreMotion) enabled.
- [ ] **Maps** capability enabled (MapKit).
- [ ] **App Groups / iCloud / CloudKit** (if used) entitlements correct and container ID matches App Store Connect.
- [ ] **ATS** exceptions (if any) documented and justified.

---

## 3) Privacy, Policy & Legal (Apple 5.1.x + locality)
- [ ] **Privacy Manifest** (`PrivacyInfo.xcprivacy`) lists:
  - [ ] **Location** (precise, background) → *Required for turn-by-turn skate navigation.*
  - [ ] **Motion** (accelerometer/gyroscope) → *On-device roughness scoring.*
  - [ ] **Diagnostics** (crash/metrics) → only if integrated.
- [ ] **Info.plist** usage strings present, accurate, and non-generic:
  - [ ] `NSLocationWhenInUseUsageDescription`  
        *“Downhill Navigator uses your location to find smooth, safe skate routes while you’re using the app.”*
  - [ ] `NSLocationAlwaysAndWhenInUseUsageDescription`  
        *“Allows accurate ETAs and continuous guidance with the screen off.”*
  - [ ] `NSLocationTemporaryUsageDescriptionDictionary` → key **NavigationPrecision**  
        *“Used briefly to improve route accuracy during active navigation.”*
  - [ ] `NSMotionUsageDescription`  
        *“Uses motion sensors to estimate surface roughness and improve route quality.”*
  - [ ] `UIBackgroundModes` includes **location**.
- [ ] **App Privacy Details** in App Store Connect match implementation.
- [ ] **Privacy Policy** & **Terms** URLs reachable; include **data deletion** contact/process.
- [ ] **Age handling**: Under‑18 defaults stricter; no unsafe spot sharing.
- [ ] **Content moderation**: “no trespassing / doxxing” rules enforced; reporting flag path verified.
- [ ] **Export compliance** questionnaire answered (no end‑to‑end encryption or tracking).
- [ ] **No ATT prompt** (IDFA not used). If analytics vendor added, reassess.

---

## 4) Map/Data Attribution & Licensing
- [ ] **Apple MapKit** attribution is visible when maps render.
- [ ] **OpenStreetMap / municipal data** (if shown) attribution included in **Settings → About → Attribution**.
- [ ] **Tile/cache** retention & size policy documented (see `CacheManager`); eviction works.
- [ ] **Offline packs** (if enabled) list data sources & licenses.

---

## 5) Functional Readiness (Skateboard‑first)
- [ ] **Routing** (MapKit) returns a route between selected **start** and **destination**.
- [ ] **SkateRouteScorer**:
  - [ ] Consumes **grade/elevation** (from `ElevationService`).
  - [ ] Applies **roughness** (from `SmoothnessEngine` + `Matcher` → `SegmentStore`).
  - [ ] Weights **crossings**, **bike lanes**, **hazards** when available.
  - [ ] Produces **route score** + **per‑step colors** + **braking mask**.
- [ ] **Map overlays** (`SmoothOverlayRenderer`) render:
  - [ ] Per‑step colorization (butter/ok/crusty).
  - [ ] **Braking dashes** on steep downhills.
- [ ] **Turn cues** (`TurnCueEngine`) fire at 40m/15m with **haptic + tone**.
- [ ] **RideRecorder**:
  - [ ] Start/Stop controlled in `MapScreen`.
  - [ ] Logs **timestamp, coordinate, speed, RMS roughness, step index**.
  - [ ] Writes **NDJSON** to app sandbox; on stop prints file path:
    ```
    📄 Ride log saved to: <path>
    ```
- [ ] **Place search** start/destination works; clears correctly.
- [ ] **Permissions onboarding** explains *Why Always / Precise / Motion*.
- [ ] **No phone-in-hand** mode works (audio/haptics adequate).

---

## 6) Performance, Reliability & Safety Budgets
- [ ] **Cold start** &gt; **2s** on A14–A18 **(FAIL)**; aim **&lt; 1.2s** ✅.
- [ ] **Overlay rendering** per frame **&lt; 8ms** (profiling snapshot recorded).
- [ ] **Background location**: battery drain **&lt; 3%/hr** in guidance.
- [ ] **File I/O**: ride log write latency **&lt; 5ms** avg; file closed on stop.
- [ ] **Crash‑free** ≥ **99.5%** TF metric.
- [ ] **Safety UI**: warns on **> 8%** grades; shows **no‑skate** zones if data exists.

---

## 7) Accessibility & Internationalization
- [ ] **VoiceOver** reads next maneuver + distance.
- [ ] **Dynamic Type** supported for HUD/banners.
- [ ] **Haptic only** mode viable (tones + haptics).
- [ ] **High contrast** assets validated (brand black/white).
- [ ] **Localization**: `en-CA` baseline; text not hardcoded in code.

---

## 8) QA Test Matrix (must run on device)
**Devices:** iPhone 12, 13 mini, 14 Pro, 15, 16 Pro (as available).  
**OS:** iOS 17.x, 18.x  
**Routes:** Smooth waterfront, residential downhill, mixed traffic, rainy night.

| Area | Scenario | Expected |
|---|---|---|
| Permissions | Fresh install → When In Use → upgrade to Always | System prompts appear with our copy; app handles each path |
| Routing | Start/Destination set | Route draws; score and overlays visible |
| Roughness | Skate 300–500m on smooth → rough | RMS increases; segment colors adapt within 1–2 steps |
| Braking | Steep downhill &gt;6% | Red braking dashes visible; cue warns |
| Background | Lock screen during guidance | Guidance continues; blue location pill visible |
| Offline | Toggle Airplane Mode mid‑ride | Route remains; no crash; overlays persist |
| Logging | Stop ride | Console prints **file path**; file exists and is non‑empty |

---

## 9) Store Assets & Metadata (App Store Connect)
- [ ] App name, subtitle, keywords, category set.
- [ ] **Description** highlights: *downhill preference, smoothness scoring, safety*.
- [ ] **Age rating** questionnaire complete (no UGC for first release unless moderation is fully on).
- [ ] **Screenshots** (5.5", 6.5", 6.7"): home, search, route preview, in‑ride HUD, braking overlay.
- [ ] **App Preview** (optional): 15–30s flow.
- [ ] **Support URL**, **Marketing URL**, **Privacy Policy URL** valid.
- [ ] **Review notes** explain:
  - Background location for turn‑by‑turn.
  - Motion use for on‑device roughness (no raw sensor export).
  - No trespassing / safety guidelines.

---

## 10) Submission
- [ ] Upload via **Xcode Organizer** or:
  ```sh
  xcodebuild -exportArchive \
    -archivePath build/SKATEROUTE.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist ExportOptions.plist
  # then upload build/export/*.ipa via Transporter (or API)
  ```
- [ ] **App Privacy** form updated for this build.
- [ ] **In‑App Events / Promo text** (optional) prepared.
- [ ] **TestFlight**:
  - [ ] Internal testers auto‑added.
  - [ ] External testers & notes (known limitations, Victoria‑first).
  - [ ] Focused test charter (downhill routes, wet surfaces, night).

---

## 11) Post‑Release Operational Checklist
- [ ] **Crash & metric dashboards** monitored daily for 72 hours.
- [ ] **Support**: canned replies for permissions, battery, legality.
- [ ] **Attribution** page cross‑checked after first app launch in production.
- [ ] **Data pipeline**: ride logs sampled (manual) to verify schema.
- [ ] **Backlog intake**: convert TF feedback into prioritized issues.

---

## 12) Appendix — Config Keys Quick Reference
**`App-Shared.xcconfig`** (examples):
```ini
PRODUCT_BUNDLE_IDENTIFIER = com.yourco.skateroute
INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = Downhill Navigator uses your location to find smooth, safe skate routes while you’re using the app.
INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription = Allows accurate ETAs and continuous guidance with the screen off.
INFOPLIST_KEY_NSLocationTemporaryUsageDescriptionDictionary_NavigationPrecision = Used briefly to improve route accuracy during active navigation.
INFOPLIST_KEY_NSMotionUsageDescription = Uses motion sensors to estimate surface roughness and improve route quality.
INFOPLIST_KEY_UIBackgroundModes = location
SWIFT_STRICT_CONCURRENCY = complete
ENABLE_USER_SCRIPT_SANDBOXING = YES
```

**Paths**
- Ride logs: `Documents/Rides/*.ndjson`
- Cache: `Library/Caches/tiles/` & `Library/Caches/elevation/`

---

### Sign‑off
- [ ] **Engineering Lead**
- [ ] **QA Lead**
- [ ] **Product/Founder**

*Ship it.* 🛹⬇️
---