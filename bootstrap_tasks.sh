#!/usr/bin/env bash
set -euo pipefail

# Portable, idempotent bootstrapper for the "coverage snapshot" tasks.
# Only creates files that DO NOT already exist. No overwrites, no dupes.
# Usage:
#   chmod +x bootstrap_tasks.sh
#   ./bootstrap_tasks.sh [APP_DIR] [UNIT_TESTS_DIR]
#
# It will try to auto-detect APP_DIR via nearest Info.plist if not supplied.

APP_DIR="${1:-}"
UNIT_TESTS_DIR="${2:-}"

log() { printf "[bootstrap] %s\n" "$*"; }
skip() { printf "[skip] %s\n" "$*"; }

detect_app_dir() {
  if [[ -n "${APP_DIR}" && -d "${APP_DIR}" ]]; then
    echo "${APP_DIR}"; return
  fi
  local plist
  plist="$(find . -name 'Info.plist' -print -quit 2>/dev/null || true)"
  if [[ -n "${plist}" ]]; then
    dirname "${plist}"; return
  fi
  if [[ -d "SKATEROUTE/SKATEROUTE/SKATEROUTE" ]]; then
    echo "SKATEROUTE/SKATEROUTE/SKATEROUTE"; return
  fi
  echo "."
}

detect_unit_tests_dir() {
  if [[ -n "${UNIT_TESTS_DIR}" && -d "${UNIT_TESTS_DIR}" ]]; then
    echo "${UNIT_TESTS_DIR}"; return
  fi
  local guess
  guess="$(find . -type d -name '*UnitTests' -print -quit 2>/dev/null || true)"
  if [[ -n "${guess}" ]]; then
    echo "${guess}"; return
  fi
  # Fallback: create a default UnitTests folder at repo root
  echo "./UnitTests"
}

write_if_missing() {
  local path="$1"; shift
  local content="$*"
  if [[ -f "${path}" ]]; then
    skip "exists: ${path}"; return
  fi
  from_path = path  # noqa: F821 (for readability in the generated script)
  mkdir -p "$(dirname "${path}")"
  printf "%s" "${content}" > "${path}"
  log "created: ${path}"
}

APP_DIR="$(detect_app_dir)"
UNIT_TESTS_DIR="$(detect_unit_tests_dir)"

log "APP_DIR=${APP_DIR}"
log "UNIT_TESTS_DIR=${UNIT_TESTS_DIR}"

# -----------------------------
# Navigation Engine & Budgets
# -----------------------------
write_if_missing "${APP_DIR}/Services/Routing/RoutingEngine.swift" $'import Foundation\nimport CoreLocation\n\npublic protocol RoutingEngine {\n    func variants(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [RoutingVariant]\n}\n\npublic struct RoutingVariant: Sendable, Equatable {\n    public let id: UUID = UUID()\n    public let name: String\n    public let distanceMeters: Double\n    public let expectedSeconds: Double\n    public let elevationGain: Double\n    public let skateability: SkateabilityScore\n}\n\npublic final class RoutingEngineStub: RoutingEngine {\n    public init() {}\n    public func variants(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [RoutingVariant] {\n        let s = SkateabilityScore(value: 80)\n        return [RoutingVariant(name: \"Chill\", distanceMeters: 3200, expectedSeconds: 900, elevationGain: 40, skateability: s)]\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/Routing/RerouteController.swift" $'import Foundation\n\npublic protocol RerouteController { func shouldReroute(distanceOff: Double, headingDelta: Double, seconds: TimeInterval) -> Bool }\n\npublic struct ReroutePolicyDefault: RerouteController {\n    public init() {}\n    public func shouldReroute(distanceOff: Double, headingDelta: Double, seconds: TimeInterval) -> Bool {\n        (distanceOff > 25 && seconds > 5) || headingDelta > 50\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/Routing/OfflineTileService.swift" $'import Foundation\n\npublic protocol OfflineTileService { func downloadPack(id: String, mbBudget: Int) async throws; func hasPack(id: String) -> Bool }\n\npublic final class OfflineTileServiceNoop: OfflineTileService {\n    private var packs: Set<String> = []\n    public init() {}\n    public func downloadPack(id: String, mbBudget: Int) async throws { packs.insert(id) }\n    public func hasPack(id: String) -> Bool { packs.contains(id) }\n}\n'

write_if_missing "${APP_DIR}/Services/Routing/BatteryGPSBudgetGuard.swift" $'import Foundation\n\npublic protocol BudgetGuard { func shouldDimHUD(after idleSeconds: Int) -> Bool }\n\npublic final class BatteryGPSBudgetGuard: BudgetGuard {\n    public init() {}\n    public func shouldDimHUD(after idleSeconds: Int) -> Bool { idleSeconds >= 10 }\n}\n'

# -----------------------------
# Elevation & Overlays
# -----------------------------
write_if_missing "${APP_DIR}/Services/Overlays/ElevationOverlayService.swift" $'import Foundation\n\npublic protocol ElevationOverlayService { func ribbonHeightsAhead() -> [Double] }\n\npublic final class ElevationOverlayServiceStub: ElevationOverlayService {\n    public init() {}\n    public func ribbonHeightsAhead() -> [Double] { [0, 2, 3, 1, -1, -2, 0] }\n}\n'

# -----------------------------
# Hazards & Live Safety
# -----------------------------
write_if_missing "${APP_DIR}/Services/Hazards/HazardStore.swift" $'import Foundation\nimport CoreLocation\n\npublic protocol HazardStore {\n    func create(_ hazard: Hazard) async throws\n    func nearby(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [Hazard]\n}\n\npublic final class HazardStoreMemory: HazardStore {\n    private var items: [Hazard] = []\n    public init() {}\n    public func create(_ hazard: Hazard) async throws { items.append(hazard) }\n    public func nearby(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [Hazard] {\n        items.filter { _ in true }\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/Hazards/HazardAlertService.swift" $'import Foundation\nimport CoreLocation\n\npublic protocol HazardAlertService {\n    func upcomingHazards(from location: CLLocation, heading: CLHeading?) async -> [Hazard]\n}\n\npublic final class HazardAlertServiceStub: HazardAlertService {\n    public init() {}\n    public func upcomingHazards(from location: CLLocation, heading: CLHeading?) async -> [Hazard] { [] }\n}\n'

write_if_missing "${APP_DIR}/Services/Hazards/GeofenceMonitor.swift" $'import Foundation\nimport CoreLocation\n\npublic protocol GeofenceMonitor { func register(_ region: CLCircularRegion); func clearAll() }\n\npublic final class GeofenceMonitorNoop: GeofenceMonitor {\n    public init() {}\n    public func register(_ region: CLCircularRegion) {}\n    public func clearAll() {}\n}\n'

# -----------------------------
# Spots & Discovery
# -----------------------------
write_if_missing "${APP_DIR}/Services/Spots/SpotsStore.swift" $'import Foundation\nimport CoreLocation\n\npublic protocol SpotsStore {\n    func add(_ spot: Spot) async throws\n    func nearby(center: CLLocationCoordinate2D, radiusMeters: Double, tags: [String]) async throws -> [Spot]\n}\n\npublic final class SpotsStoreMemory: SpotsStore {\n    private var items: [Spot] = []\n    public init() {}\n    public func add(_ spot: Spot) async throws { items.append(spot) }\n    public func nearby(center: CLLocationCoordinate2D, radiusMeters: Double, tags: [String]) async throws -> [Spot] { items }\n}\n'

# -----------------------------
# Social & Content
# -----------------------------
write_if_missing "${APP_DIR}/Services/Social/SocialGraphService.swift" $'import Foundation\n\npublic protocol SocialGraphService {\n    func follow(userId: String) async\n    func unfollow(userId: String) async\n}\n\npublic final class SocialGraphServiceNoop: SocialGraphService {\n    public init() {}\n    public func follow(userId: String) async {}\n    public func unfollow(userId: String) async {}\n}\n'

write_if_missing "${APP_DIR}/Services/Social/SessionRecorder.swift" $'import Foundation\nimport CoreLocation\n\npublic struct SessionSample: Sendable { public let ts: TimeInterval; public let location: CLLocation }\n\npublic protocol SessionRecorder { func start(); func stop() -> [SessionSample]; func append(_ location: CLLocation) }\n\npublic final class SessionRecorderMemory: SessionRecorder {\n    private var samples: [SessionSample] = []\n    private var running = false\n    public init() {}\n    public func start() { running = true; samples.removeAll() }\n    public func stop() -> [SessionSample] { running = false; return samples }\n    public func append(_ location: CLLocation) { guard running else { return }; samples.append(.init(ts: Date().timeIntervalSince1970, location: location)) }\n}\n'

# -----------------------------
# Profiles, Badges, Leaderboards
# -----------------------------
write_if_missing "${APP_DIR}/Services/Profiles/ProfileStore.swift" $'import Foundation\n\npublic protocol ProfileStore { func me() async -> Profile; func save(_ profile: Profile) async }\n\npublic final class ProfileStoreMemory: ProfileStore {\n    private var profile = Profile(id: \"me\", displayName: \"Skater\")\n    public init() {}\n    public func me() async -> Profile { profile }\n    public func save(_ profile: Profile) async { self.profile = profile }\n}\n'

write_if_missing "${APP_DIR}/Services/Gamification/BadgeEngine.swift" $'import Foundation\n\npublic protocol BadgeEngine { func evaluateAndAward(for km: Double) async -> [Badge] }\n\npublic final class BadgeEngineSimple: BadgeEngine {\n    public init() {}\n    public func evaluateAndAward(for km: Double) async -> [Badge] {\n        if km >= 100 { return [Badge(id: \"100k\", title: \"100 km club\", description: \"Skated 100 km\")] }\n        return []\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/Leaderboards/LeaderboardStore.swift" $'import Foundation\n\npublic struct LeaderboardEntry: Identifiable, Sendable { public let id = UUID(); public let name: String; public let score: Int }\n\npublic protocol LeaderboardStore { func top(kind: String) async -> [LeaderboardEntry] }\n\npublic final class LeaderboardStoreMemory: LeaderboardStore {\n    public init() {}\n    public func top(kind: String) async -> [LeaderboardEntry] { [LeaderboardEntry(name: \"You\", score: 42)] }\n}\n'

# -----------------------------
# Monetization & Growth
# -----------------------------
write_if_missing "${APP_DIR}/Services/Monetization/ProductCatalog.swift" $'import Foundation\n\npublic struct ProductCatalog { public let proMonthly = \"skateroute.pro.monthly\"; public let proYearly = \"skateroute.pro.yearly\" }\n'

write_if_missing "${APP_DIR}/Services/Monetization/PaywallCoordinator.swift" $'import Foundation\n\npublic protocol PaywallCoordinator { func purchaseMonthly() async -> Bool }\n\npublic final class PaywallCoordinatorDefault: PaywallCoordinator {\n    private let iap: IAPService\n    private let catalog: ProductCatalog\n    public init(iap: IAPService, catalog: ProductCatalog = .init()) { self.iap = iap; self.catalog = catalog }\n    public func purchaseMonthly() async -> Bool { switch await iap.purchase(productId: catalog.proMonthly) { case .purchased: return true; default: return false } }\n}\n'

# -----------------------------
# Onboarding & Reliability
# -----------------------------
write_if_missing "${APP_DIR}/Services/Onboarding/AppStateRestorer.swift" $'import Foundation\n\npublic protocol AppStateRestorer { func save(key: String, state: [String: Any]); func restore(key: String) -> [String: Any]? }\n\npublic final class AppStateRestorerDefaults: AppStateRestorer {\n    public init() {}\n    public func save(key: String, state: [String : Any]) { UserDefaults.standard.set(state, forKey: key) }\n    public func restore(key: String) -> [String : Any]? { UserDefaults.standard.dictionary(forKey: key) }\n}\n'

# -----------------------------
# Data, Security, Ops
# -----------------------------
write_if_missing "${APP_DIR}/Services/Ops/KeychainStore.swift" $'import Foundation\nimport Security\n\npublic protocol KeychainStore { func set(_ data: Data, for key: String) -> Bool; func get(_ key: String) -> Data? }\n\npublic final class KeychainStoreSimple: KeychainStore {\n    public init() {}\n    public func set(_ data: Data, for key: String) -> Bool {\n        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]\n        SecItemDelete(query as CFDictionary)\n        var add = query; add[kSecValueData as String] = data\n        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess\n    }\n    public func get(_ key: String) -> Data? {\n        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]\n        var out: CFTypeRef? = nil\n        let status = SecItemCopyMatching(query as CFDictionary, &out)\n        guard status == errSecSuccess else { return nil }\n        return (out as? Data)\n    }\n}\n'

# -----------------------------
# Accessibility & Internationalization
# -----------------------------
write_if_missing "${APP_DIR}/Resources/en.lproj/Localizable.strings" $'\"go_pro\" = \"Go Pro\";\n\"search_placeholder\" = \"Search\";\n\"record\" = \"Record\";\n\"export\" = \"Export\";\n'

# -----------------------------
# Unit Tests (minimal)
# -----------------------------
write_if_missing "${UNIT_TESTS_DIR}/ReroutePolicyTests.swift" $'import XCTest\n@testable import SKATEROUTE\n\nfinal class ReroutePolicyTests: XCTestCase {\n    func test_Reroute_Triggers_When_OffByDistanceAndTime() {\n        let p = ReroutePolicyDefault()\n        XCTAssertTrue(p.shouldReroute(distanceOff: 30, headingDelta: 0, seconds: 6))\n    }\n}\n'

write_if_missing "${UNIT_TESTS_DIR}/LocationAnomalyDetectorTests.swift" $'import XCTest\nimport CoreLocation\n@testable import SKATEROUTE\n\nfinal class LocationAnomalyDetectorTests: XCTestCase {\n    func test_NoSpike_ReturnsFalse() {\n        let det = LocationAnomalyDetector()\n        let now = Date()\n        let l1 = CLLocation(coordinate: .init(latitude: 0, longitude: 0), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now)\n        let l2 = CLLocation(coordinate: .init(latitude: 0.0001, longitude: 0.0001), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(10))\n        XCTAssertFalse(det.isImplausible([l1, l2]))\n    }\n}\n'

write_if_missing "${UNIT_TESTS_DIR}/BadgeEngineTests.swift" $'import XCTest\n@testable import SKATEROUTE\n\nfinal class BadgeEngineTests: XCTestCase {\n    func test_Award_100km() async {\n        let engine = BadgeEngineSimple()\n        let badges = await engine.evaluateAndAward(for: 100)\n        XCTAssertEqual(badges.first?.id, \"100k\")\n    }\n}\n'

write_if_missing "${UNIT_TESTS_DIR}/FeatureFlagServiceTests.swift" $'import XCTest\n@testable import SKATEROUTE\n\nfinal class FeatureFlagServiceTests: XCTestCase {\n    func test_Defaults() {\n        let ff = FeatureFlagServiceDefaults()\n        XCTAssertTrue(ff.isEnabled(\"rc_hazards_v2\"))\n        XCTAssertFalse(ff.isEnabled(\"rc_paywall_variant\"))\n    }\n}\n'

log "Done. Add files to target membership as needed and build."
