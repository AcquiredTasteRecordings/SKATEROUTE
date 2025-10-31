
# SKATEROUTE Pull Request

> **Title:** <concise, user-centric change summary>
> **Type:** Feature / Bugfix / Refactor / Docs / Infra
> **Scope:** App / Services / Map / UX / Build / CI

---

## 1) Summary (What)
Explain the change in 2–4 sentences in plain English. Focus on user-visible value and the core technical move.

- Primary capability enabled:
- Entry points (screens / services / routes):
- Feature flag (if any): `flag_name` default: On/Off

## 2) Context & Why (User Value / Problem)
- Problem statement / user story:
- Links: Issue/Ticket, Design spec, Slack thread, Customer feedback, Crash report
- Non-goals / Out of scope:

## 3) Technical Approach (How)
- Key classes/files touched:
- New types added:
- Data models / migrations:
- Algorithms / heuristics (routing, scoring, matching):
- Concurrency / actors / isolation:
- Dependency updates:

### Map & Routing impact (SKATEROUTE-specific)
- RouteService changes:
- Smoothness / roughness attribution:
- Elevation & grade computation:
- Overlays (colors, braking dashes):
- Background location behavior:

## 4) Risk, Tradeoffs & Mitigations
- Regressions most likely where?
- Failure/timeout handling:
- Edge cases covered (permission denied, no GPS, offline tiles, zero-speed, no route, DEM gaps):
- Rollback plan: (revert SHA / kill-switch flag / remote config)

## 5) Testing
### Automated
- [ ] Unit tests added/updated
- [ ] UI / snapshot tests
- [ ] Integration tests (routing/elevation/matcher)
- Describe coverage:

### Manual Test Plan (copy/paste runnable steps)
1. Launch → grant location When In Use → start ride → verify speed HUD updates.
2. Set source/destination → route draws → per-step coloring appears.
3. Simulate movement (Debug → Location) → roughness events attribute to steps.
4. Background the app 60s → ensure logging continues if allowed.
5. Deny location permission → friendly error state shown.

**Device matrix**
- iPhone 15 Pro (iOS 18) sim ✅
- iPhone 12 (iOS 17) device ✅
- Low-power mode ✅ / No motion permissions ✅

## 6) Performance, Battery & Memory
- Rendering/overlay changes cost:
- CPU/GPU hotspots:
- Logging sampling rates:
- Startup time impact:

## 7) Privacy, Permissions & Compliance
- Info.plist usage strings changed?  `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`
- PrivacyInfo.xcprivacy updated?
- Data retention & export path (SessionLogger):

## 8) Accessibility & Localization
- VoiceOver / Dynamic Type / Contrast:
- Motion/animation sensitivity:
- Localized strings updated:

## 9) Security
- Secrets / keys handled via CI or ASC API keys only
- No PII stored; logs anonymized
- Network transport (TLS / pinned hosts) if applicable

## 10) Analytics / Telemetry
- New events:
- Event parameters:
- Dashboard(s) to update:

## 11) Screenshots / Videos / Diffs
(Attach images or quick screen recordings. Before/After if visual.)

---

## ✅ Merge Checklist
- [ ] CI green on PR (build + tests on iOS 17/18 sim)
- [ ] SwiftLint clean (or documented waivers)
- [ ] Unit/UI tests passing locally
- [ ] No `print`/`NSLog` left (use `os.Logger` / `SessionLogger`)
- [ ] No secrets committed (passes secret scan)
- [ ] Info.plist & PrivacyInfo.xcprivacy accurate
- [ ] Accessibility pass for new UI
- [ ] Public API & error messages documented
- [ ] Changelog / Release notes updated
- [ ] Fastlane `beta` lane verified (if shipping)

### Optional (but recommended)
- [ ] Performance checked (Instruments, time profile)
- [ ] Energy impact checked (Energy Log)
- [ ] Offline behavior verified

---

## Post-merge Tasks
- [ ] Tag release (e.g., `v0.8.0-beta`)
- [ ] `fastlane beta` to TestFlight, fill notes
- [ ] Announce in #release with GIF/video

> _Template tuned for a production navigation app (MapKit, background location, motion, overlays). Keep it crisp; link out to deep detail when needed._