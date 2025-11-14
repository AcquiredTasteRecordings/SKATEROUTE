# Implementation Backlog — Navigation, Offline Packs, Monetization Alignment

_Last updated: 2025-11-14_

## Context
- There is no `Features/Navigate` target. Ride HUD and cueing live under `Features/UX` with supporting engines in `Services/Navigation` and `Services/Voice`.
- Offline lifecycle services (`Services/Offline`) are implemented, but no `Features/OfflinePacks` surface exists to expose downloads, updates, or deletions.
- Monetization UI resides in `Features/Monetization` (Paywall + Manage Subscription), so the previously referenced `Features/Commerce` module is unimplemented.

The backlog below schedules the missing feature shells so the published project layout and release scope stay in lockstep.

## Milestone Timeline
| Milestone | Target Window | Goal |
| --- | --- | --- |
| **M1 — Navigation Shell Alignment** | T-8 weeks from 1.0 code freeze | Establish dedicated `Features/Navigate` wrapper that orchestrates Ride HUD flows owned today by `Features/UX` + navigation services. |
| **M2 — Offline Pack UI** | T-6 weeks | Ship downloadable city pack management experience wired into `Services/Offline`. |
| **M3 — Commerce Enhancements** | T-4 weeks | Expand `Features/Monetization` with Apple Pay / Stripe checkout UX and entitlement state handoffs. |

## Backlog Items
### M1 — Navigation Shell Alignment
1. Create `Features/Navigate` target/folder with coordinator + entry view integrating `RideTelemetryHUD`, `TurnCueEngine`, and `SpeechCueEngine`.
2. Move existing previews from `Features/UX` into the new module; expose protocols for HUD interactions to keep services testable.
3. Update `AppCoordinator` to route ride start/stop into the new feature shell (respect background safety requirements).
4. Add unit coverage for navigation state machine (idle → counting down → active → completed/paused) and cue dispatch throttling.

### M2 — Offline Pack UI
1. Scaffold `Features/OfflinePacks` with SwiftUI list + detail surfaces that wrap `OfflineRouteStore`, `OfflineTileManager`, and `CacheManager`.
2. Implement download/update/delete flows with progress indicators, storage warnings, and background refresh handling.
3. Add integration tests simulating pack lifecycle using existing GPX fixtures and stubbed tile manifests.
4. Wire Pro entitlement checks (`Core/Entitlements`) and surface upgrade CTA via `Features/Monetization` when locked.

### M3 — Commerce Enhancements
1. Extend `Features/Monetization` to include Apple Pay / Stripe checkout flows for physical goods using `Services/StoreKit` + new payment bridges.
2. Implement receipt validation and fulfillment hooks inside `Services/StoreKit` and `Services/Rewards` for merch/ticket purchases.
3. Localize paywall/checkout copy, including accessibility voiceover hints and haptic confirmations.
4. Add telemetry instrumentation (`Services/Analytics`) for paywall impressions, conversion funnels, and checkout outcomes.

## Dependencies & Risks
- Requires coordination with navigation engine owners to avoid regressions in cue timing.
- Offline pack UI depends on finalized storage quota policies and API shape for tile manifests.
- Commerce work assumes legal approval for Apple Pay/Stripe messaging and fulfillment SLAs.

## Acceptance
- Project structure matches README/WHITEPAPER module map.
- All new feature folders compile within the `SkateRoute` scheme with unit + UI coverage per charter testing expectations.
- Release checklist reflects availability of navigation shell, offline management, and monetization flows ahead of 1.0 freeze.
