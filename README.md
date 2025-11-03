# SkateRoute — *All Downhill From Here*

A skate-first navigation app that optimizes for ride quality, safety, and downhill flow. SkateRoute computes routes that **feel good**—prioritizing smooth pavement, safer streets, and favorable grades—then adapts in real time using on‑device motion roughness and location data.

> This repository contains the iOS beta codebase. It is designed for on‑device testing, rapid iteration, and future expansion into ML‑assisted routing and crowdsourced surface insights.

---

## Executive overview

**Problem.** Maps optimize for drivers or pedestrians, not skaters. What matters to skateboarders is *surface smoothness, slope, braking risk, and crossings*.  
**Solution.** SkateRoute combines MapKit routing with a skate‑aware scorer. It colors the route by comfort, gives low‑distraction turn cues, and learns from your ride via on‑device sensors—no accounts and no cloud required.

**Why now.** Modern iPhones provide precise motion + location, MapKit directions are robust, and on‑device storage makes privacy‑first iteration easy. The app captures unique telemetry (roughness RMS, grade, braking zones) that compounds into a durable data asset.

**What’s in this repo.** A complete iOS app skeleton with:
- Route scoring (surface + slope + crossings proxies)
- Live overlays (per‑step coloring, braking dashes)
- Turn cues + haptics
- Ride logging for post‑analysis
- Modular services built for future ML and crowdsourcing

---

## Quick start

1. **Requirements**
   - Xcode 16+, iOS 17+ (sim or device)
   - No external API keys (MapKit only)
   - Location permissions: *When In Use* (and Precise if testing roughness/recorder)

2. **Build & run**
   - Open `SKATEROUTE.xcodeproj`
   - Select *iPhone 16 Pro* (sim) or a physical device
   - Run ▶︎
   - On first launch, grant location permission

3. **Try a line**
   - In **Home**, set *Source* and *Destination* or use current location
   - Tap **Find Smooth Line**
   - On **Map**, tap **Start** to begin recording (roughness + telem)
   - Watch the route recolor as you move; braking zones render as short red dashes

---

## Project layout

```text
SKATEROUTE
├─ Core
│  ├─ AppCoordinator.swift
│  ├─ AppDI.swift
│  └─ AppRouter.swift
├─ Features
│  ├─ Community
│  │  ├─ Models/SurfaceRating.swift
│  │  └─ Views/QuickReportView.swift
│  ├─ Home
│  │  ├─ HomeView.swift
│  │  └─ HomeViewModel.swift
│  ├─ Map
│  │  ├─ MapScreen.swift
│  │  ├─ MapViewContainer.swift
│  │  └─ SmoothOverlayRenderer.swift
│  ├─ Search
│  │  ├─ PlaceSearchView.swift
│  │  └─ PlaceSearchViewModel.swift
│  └─ UX
│     ├─ HapticCue.swift
│     ├─ RideMode.swift
│     ├─ RideTelemetryHUD.swift
│     ├─ SpeedHUDView.swift
│     └─ TurnCueEngine.swift
├─ Resources
│  └─ attrs-victoria.json
├─ Services
│  ├─ AttributionService.swift
│  ├─ CacheManager.swift
│  ├─ ElevationService.swift
│  ├─ GeocoderService.swift
│  ├─ LocationManagerService.swift
│  ├─ Matcher.swift
│  ├─ MatcherTypes.swift
│  ├─ MotionRoughnessService.swift
│  ├─ RideRecorder.swift
│  ├─ RouteContextBuilder.swift
│  ├─ RouteService.swift
│  ├─ SegmentStore.swift
│  ├─ SessionLogger.swift
│  ├─ SkateRouteScorer.swift
│  └─ SmoothnessEngine.swift
├─ Support
│  └─ Utilities
│     ├─ AccuracyProfile.swift
│     └─ Geometry.swift
├─ Assets
├─ DownhillNavigatorApp.swift   ← app entry point
└─ Info/
```

---

## System architecture (high level)

- **Views** are SwiftUI shells composed with MapKit and small UIKit adapters.
- **Core** wires the app: dependency injection (DI), coordination, and routing between screens.
- **Services** encapsulate logic: routing, elevation, matching, roughness, storage, and logging.
- **Stores** (e.g., `SegmentStore`) cache per‑segment attributes and decay stale values over time.

### Data flow (runtime)

```mermaid
flowchart TD
    Home[HomeView] -->|source/destination| RS[RouteService]
    RS -->|MKDirections| MK[MapKit]
    MK --> R(Route)
    R --> RCB[RouteContextBuilder]
    RCB -->|per-step attrs| SRS[SkateRouteScorer]
    SRS --> MVC[MapViewContainer / overlays]
    subgraph Live Ride
      LMS[LocationManagerService] --> MRS[MotionRoughnessService]
      MRS --> SE[SmoothnessEngine (RMS)]
      SE --> MAT[Matcher] --> SEG[SegmentStore]
      SEG --> MVC
      LMS --> TCE[TurnCueEngine] --> HAP[HapticCue]
      LMS --> RR[RideRecorder] --> LOG[SessionLogger]
    end
```

---

## Key modules — what each file does

### Core
- **AppCoordinator.swift** — Orchestrates navigation between Home → Map and handles lifecycle hooks. Central place to present the map with a pre‑built route and to dismiss back to Home.
- **AppDI.swift** — Lightweight dependency container for singletons (routing, elevation, matcher, recorder, etc.). Keeps construction in one place to avoid cross‑talk and simplifies preview wiring.
- **AppRouter.swift** — Pure routing helpers for presenting sheets/stacks. Keeps view code declarative and testable.

### Features / Community
- **SurfaceRating.swift** — Data model for quick surface reports (Butter / Okay / Crusty) with timestamp and coordinate. Future‑proofed to support confidence and photo evidence.
- **QuickReportView.swift** — One‑tap UI to submit a surface report on the map during or after a ride. Designed for minimal attention cost.

### Features / Home
- **HomeView.swift** — Branded launch + input screen. Lets riders pick *Source* and *Destination*, choose **RideMode** (e.g., Smoothest, Chill, Night Safe), and kick off routing.
- **HomeViewModel.swift** — Binds text/search inputs, maintains selected MapKit `MKMapItem`s, and coordinates geocoding/autocomplete queries.

### Features / Map
- **MapScreen.swift** — The main navigation canvas. Shows the candidate route, next‑maneuver banner, speed HUD, overlays, and **Start/Stop** recording control.
- **MapViewContainer.swift** — A `UIViewRepresentable` bridge for MapKit overlays and per‑step coloring. Updates only the visible polyline range for performance.
- **SmoothOverlayRenderer.swift** — Custom `MKOverlayPathRenderer` that draws a multicolor route (green→amber→red by score) and short red **braking dashes** for steep downhills.

### Features / Search
- **PlaceSearchView.swift** — Reusable SwiftUI search field + results list for places/addresses.
- **PlaceSearchViewModel.swift** — Wraps MapKit search/autocomplete and debounces user input.

### Features / UX
- **HapticCue.swift** — Small façade over `UIFeedbackGenerator` to standardize haptics. Used by Start/Stop and approach‑turn cues.
- **RideMode.swift** — Tuning presets for the scorer (e.g., chill few crossings, night safe, fast mild roughness).
- **RideTelemetryHUD.swift** — Compact, glanceable speed and stability readout (km/h + inferred surface stability).
- **SpeedHUDView.swift** — Visualizes current speed and optionally appends small glyphs when stability drops.
- **TurnCueEngine.swift** — Low‑distraction prompts: distance‑to‑next step, 40m/15m haptics, and a short system beep.

### Resources
- **attrs-victoria.json** — Seed attributes for the Victoria test area (e.g., lane proxies, turn penalties, known hazards) consumed by `AttributionService` & `RouteContextBuilder`.

### Services
- **AttributionService.swift** — Loads local attribute “tiles” like `attrs-victoria.json` and exposes light‑weight lookups for steps (bike lane proxy, turn severity, hazard hints).
- **CacheManager.swift** — Simple disk cache (JSON/png/bin). Used for elevation tiles and segment summaries.
- **ElevationService.swift** — Queries elevation (e.g., Terrain‑RGB/DEM tiles), returns meters and computes **grade**; provides `summarizeGrades(on:)` (max/mean) and braking masks.
- **GeocoderService.swift** — Reverse geocoding helpers and conversions between `CLLocation`/`MKMapItem`.
- **LocationManagerService.swift** — Centralized CoreLocation manager with accuracy profiles (`AccuracyProfile`), permission flow, and current location stream.
- **Matcher.swift** / **MatcherTypes.swift** — Snaps roughness samples to the nearest route step. `MatchSample` and related types live here for consistency across modules.
- **MotionRoughnessService.swift** — Reads accelerometer/gyro and computes **RMS roughness**; low‑passes signal and emits a normalized stability value.
- **RideRecorder.swift** — Session controller that toggles recording, subscribes to location & roughness, matches samples to steps, and emits logs via `SessionLogger`.
- **RouteContextBuilder.swift** — Derives **per‑step attributes** (grade, lane bonus, hazard/turn penalties) by combining elevation with local attributions.
- **RouteService.swift** — Thin wrapper over MapKit `MKDirections` with convenience to fetch, cancel, and normalize routes.
- **SegmentStore.swift** — In‑memory + persisted store keyed by (routeID, stepIndex). Holds rolling statistics (roughness, last seen, decay) to color the polyline responsively.
- **SessionLogger.swift** — Streams session CSV/JSON to disk (and prints path when finished). Enables offline analysis and future upload pipelines.
- **SkateRouteScorer.swift** — Core scoring model. Blends smoothness, slope, crossings, lane bonuses, and hazard penalties into a 0…1 comfort score per step.
- **SmoothnessEngine.swift** — Aggregates raw motion samples, computes clamped RMS, and publishes *stability* for UI and scoring.

### Support / Utilities
- **AccuracyProfile.swift** — Named accuracy modes (e.g., `fitness`, `skatePrecise`) for energy vs precision trade‑offs.
- **Geometry.swift** — Polyline helpers, coordinate math, and distance utilities.

---

## Configuration & privacy

- No third‑party keys required.  
- All telemetry is **on‑device** by default.  
- The recorder prints the log path on stop (look for `📄 Ride log saved to:` in the console).  
- Location permission is *When In Use*; precise accuracy can be requested temporarily while recording.

---

## How routing feels “skate aware”

1. **Surface:** Uses live roughness RMS + community reports to weight steps.  
2. **Slope:** Samples grade along the route; highlights braking zones (< −6% for ≥30m).  
3. **Crossings proxy:** Penalizes segments with many steps/turns (as a first‑pass proxy).  
4. **Lanes & hazards:** Local attribution adds bonuses for bike lanes and penalties for sharp turns or flagged hazards.  
5. **Modes:** *ChillFewCrossings*, *NightSafe*, *FastMildRoughness* tweak weights without rewriting the model.

---

## Developer notes

- **Runtime tracing:** Enable the `DEBUG` build to see RMS and stability prints from `SmoothnessEngine`.  
- **Persisted data:** Tiles and segment caches are written under the app’s sandbox `Library/Caches/`.  
- **Extensibility:** Each service is a small unit with few dependencies; replace or mock freely.

---

## Roadmap & opportunities

- **ML route scoring.** Train a learned comfort model from logged rides (features: roughness, slope context, turn acuity, lane class, traffic proxy). Export on‑device Core ML.  
- **Crowdsourcing.** Turn quick reports into a light reputation system; reconcile conflicts; attribute decay and local upvotes.  
- **VisionOS / Apple Watch.** Heads‑up nav banner with distance‑to‑turn; watch haptic cadence as braking approaches.  
- **Lighting & safety.** Night‑safe mode with lighting proxies (POI density, OSM lamps); community‑verified “skateable at night” tags.  
- **Offline mode.** Cache routes, elevation tiles, and attribution tiles for dead‑zone rides.  
- **SDK / API.** Expose the scorer and matcher as a standalone Swift package for partner apps.

---

## Contributing

Please open issues for bugs, ideas, or city data contributions. For collaboration inquiries, reach out via the repository contact.

---

## License

**Proprietary — All rights reserved.** No redistribution or commercial use without written permission.
