#!/usr/bin/env bash
set -euo pipefail

# Idempotent scaffolder: creates ONLY files that don't exist.
# Usage:
#   chmod +x scaffold_missing.sh
#   ./scaffold_missing.sh [APP_DIR] [UITESTS_DIR]
#
# Defaults:
#   APP_DIR      -> auto-detected by searching for the nearest Info.plist; fallback: ./SKATEROUTE/SKATEROUTE/SKATEROUTE
#   UITESTS_DIR  -> auto-detected as "*UITests" directory; fallback: ./SKATEROUTE/SKATEROUTE/SKATEROUTEUITests

APP_DIR="${1:-}"
UITESTS_DIR="${2:-}"

log() { printf "[scaffold] %s\n" "$*"; }
skip() { printf "[skip] %s\n" "$*"; }

detect_app_dir() {
  if [[ -n "${APP_DIR}" && -d "${APP_DIR}" ]]; then
    echo "${APP_DIR}"; return
  fi
  local plist
  plist="$(fd -HI -a '^Info\.plist$' . 2>/dev/null | head -n1)"
  if [[ -n "${plist}" ]]; then
    dirname "${plist}"
    return
  fi
  # fallback – matches the path seen in earlier error logs
  if [[ -d "SKATEROUTE/SKATEROUTE/SKATEROUTE" ]]; then
    echo "SKATEROUTE/SKATEROUTE/SKATEROUTE"; return
  fi
  # last resort
  echo "."
}

detect_ui_tests_dir() {
  if [[ -n "${UITESTS_DIR}" && -d "${UITESTS_DIR}" ]]; then
    echo "${UITESTS_DIR}"; return
  fi
  local guess
  guess="$(fd -HI -td '^.*UITests$' . 2>/dev/null | head -n1)"
  if [[ -n "${guess}" ]]; then
    echo "${guess}"; return
  fi
  # fallback near app dir
  local appdir="$1"
  if [[ -d "${appdir}UITests" ]]; then
    echo "${appdir}UITests"; return
  fi
  echo "./UITests"
}

write_if_missing() {
  local path="$1"; shift
  local content="$*"
  if [[ -f "${path}" ]]; then
    skip "exists: ${path}"
    return
  fi
  mkdir -p "$(dirname "${path}")"
  printf "%s" "${content}" > "${path}"
  log "created: ${path}"
}

APP_DIR="$(detect_app_dir)"
UITESTS_DIR="$(detect_ui_tests_dir "${APP_DIR%/}")"

log "APP_DIR=${APP_DIR}"
log "UITESTS_DIR=${UITESTS_DIR}"

# --- Models ---
write_if_missing "${APP_DIR}/Models/SkateabilityScore.swift" $'import Foundation\nimport CoreLocation\n\npublic struct SkateabilityScore: Sendable, Codable {\n    public let value: Int // 0...100\n    public let reasons: [String]\n\n    public init(value: Int, reasons: [String] = []) {\n        self.value = max(0, min(100, value))\n        self.reasons = reasons\n    }\n\n    public static func compute(gradePercent: Double, surfaceQuality: Double, hazardDensity: Double) -> SkateabilityScore {\n        let gradePenalty = max(0, min(1, gradePercent / 20.0))\n        let surfaceBoost = max(0, min(1, surfaceQuality))\n        let hazardPenalty = max(0, min(1, hazardDensity))\n        let raw = (0.55 * (1 - gradePenalty) + 0.35 * surfaceBoost + 0.10 * (1 - hazardPenalty)) * 100\n        return SkateabilityScore(value: Int(round(raw)), reasons: [])\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/RouteOption.swift" $'import Foundation\nimport CoreLocation\n\npublic struct RouteOption: Identifiable, Codable, Sendable {\n    public let id: UUID\n    public let name: String\n    public let distanceMeters: Double\n    public let expectedSeconds: Double\n    public let polyline: [CLLocationCoordinate2D]\n    public let elevationGain: Double\n    public let skateability: SkateabilityScore\n\n    public init(\n        id: UUID = UUID(),\n        name: String,\n        distanceMeters: Double,\n        expectedSeconds: Double,\n        polyline: [CLLocationCoordinate2D],\n        elevationGain: Double,\n        skateability: SkateabilityScore\n    ) {\n        self.id = id\n        self.name = name\n        self.distanceMeters = distanceMeters\n        self.expectedSeconds = expectedSeconds\n        self.polyline = polyline\n        self.elevationGain = elevationGain\n        self.skateability = skateability\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Hazard.swift" $'import Foundation\nimport CoreLocation\n\npublic enum HazardType: String, Codable, CaseIterable, Sendable { case pothole, debris, wet, traffic, rail, rough, unknown }\n\npublic struct Hazard: Identifiable, Codable, Sendable {\n    public let id: UUID\n    public let coordinate: CLLocationCoordinate2D\n    public let type: HazardType\n    public let confidence: Double\n    public let createdAt: Date\n\n    public init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, type: HazardType, confidence: Double, createdAt: Date = .init()) {\n        self.id = id\n        self.coordinate = coordinate\n        self.type = type\n        self.confidence = max(0, min(1, confidence))\n        self.createdAt = createdAt\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Spot.swift" $'import Foundation\nimport CoreLocation\n\npublic struct Spot: Identifiable, Codable, Sendable {\n    public let id: UUID\n    public let name: String\n    public let coordinate: CLLocationCoordinate2D\n    public let tags: [String]\n\n    public init(id: UUID = UUID(), name: String, coordinate: CLLocationCoordinate2D, tags: [String] = []) {\n        self.id = id\n        self.name = name\n        self.coordinate = coordinate\n        self.tags = tags\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Post.swift" $'import Foundation\n\npublic struct Post: Identifiable, Codable, Sendable {\n    public let id: UUID\n    public let authorId: String\n    public let mediaURL: URL?\n    public let caption: String\n    public let createdAt: Date\n\n    public init(id: UUID = UUID(), authorId: String, mediaURL: URL?, caption: String, createdAt: Date = .init()) {\n        self.id = id\n        self.authorId = authorId\n        self.mediaURL = mediaURL\n        self.caption = caption\n        self.createdAt = createdAt\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Profile.swift" $'import Foundation\n\npublic struct Profile: Identifiable, Codable, Sendable {\n    public let id: String\n    public var displayName: String\n    public var bio: String\n    public var badges: [Badge]\n\n    public init(id: String, displayName: String, bio: String = \"\", badges: [Badge] = []) {\n        self.id = id\n        self.displayName = displayName\n        self.bio = bio\n        self.badges = badges\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Badge.swift" $'import Foundation\n\npublic struct Badge: Identifiable, Codable, Sendable, Hashable {\n    public let id: String\n    public let title: String\n    public let description: String\n\n    public init(id: String, title: String, description: String) {\n        self.id = id\n        self.title = title\n        self.description = description\n    }\n}\n'

write_if_missing "${APP_DIR}/Models/Challenge.swift" $'import Foundation\n\npublic struct Challenge: Identifiable, Codable, Sendable {\n    public let id: String\n    public let title: String\n    public let rules: String\n    public let endsAt: Date\n\n    public init(id: String, title: String, rules: String, endsAt: Date) {\n        self.id = id\n        self.title = title\n        self.rules = rules\n        self.endsAt = endsAt\n    }\n}\n'

# --- Services (protocols + no-op) ---
write_if_missing "${APP_DIR}/Services/FirebaseService.swift" $'import Foundation\n\npublic protocol FirebaseService { func log(event: String, params: [String: Any]) }\npublic final class FirebaseServiceNoop: FirebaseService { public init() {} ; public func log(event: String, params: [String: Any]) {} }\n'

write_if_missing "${APP_DIR}/Services/MediaStore.swift" $'import Foundation\n\npublic protocol MediaStore { func tempURL(filename: String, ext: String) -> URL }\npublic final class MediaStoreDefault: MediaStore {\n    public init() {}\n    public func tempURL(filename: String, ext: String) -> URL {\n        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)\n        return dir.appendingPathComponent(filename).appendingPathExtension(ext)\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/MediaCaptureService.swift" $'import Foundation\nimport AVFoundation\n\npublic protocol MediaCaptureService { var isRecording: Bool { get }; func start() async throws; func stop() async throws -> URL }\npublic final class MediaCaptureServiceNoop: MediaCaptureService {\n    public private(set) var isRecording = false\n    public init() {}\n    public func start() async throws { isRecording = true }\n    public func stop() async throws -> URL { isRecording = false; return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(\"stub.mp4\") }\n}\n'

write_if_missing "${APP_DIR}/Services/MediaEditService.swift" $'import Foundation\n\npublic protocol MediaEditService { func export(input: URL, maxResolution: Int) async throws -> URL }\npublic final class MediaEditServiceNoop: MediaEditService { public init() {} ; public func export(input: URL, maxResolution: Int) async throws -> URL { input } }\n'

write_if_missing "${APP_DIR}/Services/VoiceGuidanceService.swift" $'import Foundation\nimport AVFoundation\n\npublic protocol VoiceGuidanceService { func speak(_ text: String) }\npublic final class VoiceGuidanceServiceSystem: VoiceGuidanceService { private let syn = AVSpeechSynthesizer(); public init() {} ; public func speak(_ text: String) { syn.speak(AVSpeechUtterance(string: text)) } }\n'

write_if_missing "${APP_DIR}/Services/RewardsService.swift" $'import Foundation\n\npublic protocol RewardsService { func award(badgeId: String) async }\npublic final class RewardsServiceNoop: RewardsService { public init() {} ; public func award(badgeId: String) async {} }\n'

write_if_missing "${APP_DIR}/Services/AttributionService.swift" $'import Foundation\n\npublic protocol AttributionService { func generateReferralLink(code: String) -> URL }\npublic final class AttributionServiceDefault: AttributionService { public init() {} ; public func generateReferralLink(code: String) -> URL { URL(string: \"https://skateroute.app/ref/\\(code)\")! } }\n'

write_if_missing "${APP_DIR}/Services/IAPService.swift" $'import Foundation\n\npublic enum IAPStatus { case idle, purchasing, purchased, failed(Error) }\npublic protocol IAPService { func purchase(productId: String) async -> IAPStatus; func restore() async -> Bool }\npublic final class IAPServiceNoop: IAPService { public init() {} ; public func purchase(productId: String) async -> IAPStatus { .purchased } ; public func restore() async -> Bool { true } }\n'

write_if_missing "${APP_DIR}/Services/AdService.swift" $'import Foundation\n\npublic protocol AdService { func preload(); func showIfAppropriate() -> Bool }\npublic final class AdServiceNoop: AdService { public init() {} ; public func preload() {} ; public func showIfAppropriate() -> Bool { false } }\n'

write_if_missing "${APP_DIR}/Services/PermissionCoachService.swift" $'import Foundation\n\npublic protocol PermissionCoachService { func shouldPrompt(for type: String) -> Bool }\npublic final class PermissionCoachServiceDefault: PermissionCoachService { public init() {} ; public func shouldPrompt(for type: String) -> Bool { true } }\n'

write_if_missing "${APP_DIR}/Services/PushService.swift" $'import Foundation\n\npublic protocol PushService { func registerForPush() }\npublic final class PushServiceNoop: PushService { public init() {} ; public func registerForPush() {} }\n'

write_if_missing "${APP_DIR}/Services/DeepLinkService.swift" $'import Foundation\n\npublic enum DeepLink: Equatable { case routePlanner, paywall, profile(userId: String), unknown }\npublic protocol DeepLinkService { func parse(url: URL) -> DeepLink }\npublic final class DeepLinkServiceDefault: DeepLinkService {\n    public init() {}\n    public func parse(url: URL) -> DeepLink {\n        guard let host = url.host else { return .unknown }\n        switch host { case \"route\": return .routePlanner\n        case \"paywall\": return .paywall\n        case \"profile\": return .profile(userId: url.lastPathComponent)\n        default: return .unknown }\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/ShareLinkService.swift" $'import Foundation\n\npublic protocol ShareLinkService { func makeShareURL(path: String, params: [String: String]) -> URL }\npublic final class ShareLinkServiceDefault: ShareLinkService {\n    public init() {}\n    public func makeShareURL(path: String, params: [String: String]) -> URL {\n        var comps = URLComponents(); comps.scheme = \"https\"; comps.host = \"skateroute.app\"; comps.path = \"/\\(path)\"\n        if !params.isEmpty { comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }\n        return comps.url ?? URL(string: \"https://skateroute.app\")!\n    }\n}\n'

write_if_missing "${APP_DIR}/Services/SettingsStore.swift" $'import Foundation\n\npublic protocol SettingsStore { var useMetric: Bool { get set } }\npublic final class SettingsStoreDefaults: SettingsStore { private let key = \"sr_use_metric\"; public init() {}\n    public var useMetric: Bool { get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }\n        set { UserDefaults.standard.set(newValue, forKey: key) } }\n}\n'

write_if_missing "${APP_DIR}/Services/SupportService.swift" $'import Foundation\n\npublic protocol SupportService { func submitDiagnostics(note: String) async -> Bool }\npublic final class SupportServiceNoop: SupportService { public init() {} ; public func submitDiagnostics(note: String) async -> Bool { true } }\n'

write_if_missing "${APP_DIR}/Services/AnalyticsService.swift" $'import Foundation\n\npublic protocol AnalyticsService { func track(_ event: String, _ params: [String: Any]) }\npublic final class AnalyticsServiceDefault: AnalyticsService { public init() {} ; public func track(_ event: String, _ params: [String: Any]) { #if DEBUG\n    print(\"ANALYTICS \\(event): \\(params)\")\n#endif } }\n'

write_if_missing "${APP_DIR}/Services/FeatureFlagService.swift" $'import Foundation\n\npublic protocol FeatureFlagService { func isEnabled(_ key: String) -> Bool }\npublic final class FeatureFlagServiceDefaults: FeatureFlagService {\n    private let defaults: [String: Bool]\n    public init(defaults: [String: Bool] = [\"rc_hazards_v2\": true, \"rc_skatability_formula\": true, \"rc_paywall_variant\": false, \"rc_ads_enabled\": false]) { self.defaults = defaults }\n    public func isEnabled(_ key: String) -> Bool { defaults[key] ?? false }\n}\n'

write_if_missing "${APP_DIR}/Services/LocationAnomalyDetector.swift" $'import Foundation\nimport CoreLocation\n\npublic struct LocationAnomalyDetector {\n    public init() {}\n    public func isImplausible(_ locations: [CLLocation]) -> Bool {\n        guard locations.count >= 2 else { return false }\n        for i in 1..<locations.count {\n            let dt = locations[i].timestamp.timeIntervalSince(locations[i-1].timestamp)\n            guard dt > 0 else { continue }\n            let dist = locations[i].distance(from: locations[i-1])\n            let speedKmh = (dist / dt) * 3.6\n            if speedKmh > 45 { return true }\n        }\n        return false\n    }\n}\n'

# --- Overlays ---
write_if_missing "${APP_DIR}/Overlays/HazardAnnotationView.swift" $'import MapKit\n#if canImport(UIKit)\nfinal class HazardAnnotationView: MKMarkerAnnotationView {\n    static let reuseID = \"HazardAnnotationView\"\n    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {\n        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)\n        glyphText = \"!\"; markerTintColor = .systemRed; accessibilityIdentifier = \"sr_hazard_marker\"\n    }\n    required init?(coder: NSCoder) { super.init(coder: coder) }\n}\n#endif\n'

write_if_missing "${APP_DIR}/Overlays/SpotAnnotationView.swift" $'import MapKit\n#if canImport(UIKit)\nfinal class SpotAnnotationView: MKMarkerAnnotationView {\n    static let reuseID = \"SpotAnnotationView\"\n    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {\n        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)\n        glyphText = \"★\"; markerTintColor = .systemBlue; accessibilityIdentifier = \"sr_spot_marker\"\n    }\n    required init?(coder: NSCoder) { super.init(coder: coder) }\n}\n#endif\n'

# --- ViewModels ---
write_if_missing "${APP_DIR}/Features/RoutePlanner/RoutePlannerViewModel.swift" $'import Foundation\nimport Combine\nimport CoreLocation\n\n@MainActor\nfinal class RoutePlannerViewModel: ObservableObject {\n    @Published var origin: String = \"\"\n    @Published var destination: String = \"\"\n    @Published var options: [RouteOption] = []\n    func loadMock() {\n        let coords = [CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)]\n        let score = SkateabilityScore(value: 82)\n        options = [RouteOption(name: \"Chill\", distanceMeters: 3200, expectedSeconds: 900, polyline: coords, elevationGain: 40, skateability: score)]\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Navigation/NavigationViewModel.swift" $'import Foundation\nimport Combine\n\n@MainActor\nfinal class NavigationViewModel: ObservableObject {\n    @Published var nextInstruction: String = \"Head north\"\n    @Published var distanceToNext: String = \"120 m\"\n    @Published var speedKmh: String = \"12\"\n}\n'

write_if_missing "${APP_DIR}/Features/Hazards/HazardReportViewModel.swift" $'import Foundation\nimport Combine\nimport CoreLocation\n\n@MainActor\nfinal class HazardReportViewModel: ObservableObject {\n    @Published var selectedType: HazardType = .unknown\n    @Published var confidence: Double = 0.7\n    @Published var coordinate: CLLocationCoordinate2D?\n    func submit() async -> Bool { true }\n}\n'

write_if_missing "${APP_DIR}/Features/Spots/SpotsViewModel.swift" $'import Foundation\nimport Combine\nimport CoreLocation\n\n@MainActor\nfinal class SpotsViewModel: ObservableObject {\n    @Published var spots: [Spot] = []\n    func loadNearby() { spots = [Spot(name: \"Plaza\", coordinate: CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12))] }\n}\n'

write_if_missing "${APP_DIR}/Features/Capture/CaptureViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class CaptureViewModel: ObservableObject { @Published var isRecording = false }\n'

write_if_missing "${APP_DIR}/Features/Editor/EditorViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class EditorViewModel: ObservableObject { @Published var exportProgress: Double = 0 }\n'

write_if_missing "${APP_DIR}/Features/Feed/FeedViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class FeedViewModel: ObservableObject { @Published var posts: [Post] = []; func load() { posts = [] } }\n'

write_if_missing "${APP_DIR}/Features/Profile/ProfileViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class ProfileViewModel: ObservableObject { @Published var profile = Profile(id: \"me\", displayName: \"Skater\", badges: []) }\n'

write_if_missing "${APP_DIR}/Features/Challenges/ChallengesViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class ChallengesViewModel: ObservableObject { @Published var challenges: [Challenge] = [] }\n'

write_if_missing "${APP_DIR}/Features/Leaderboard/LeaderboardViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class LeaderboardViewModel: ObservableObject { struct Entry: Identifiable { let id = UUID(); let name: String; let score: Int }\n    @Published var entries: [Entry] = [] }\n'

write_if_missing "${APP_DIR}/Features/Paywall/PaywallViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class PaywallViewModel: ObservableObject { @Published var isPro = false }\n'

write_if_missing "${APP_DIR}/Features/Referral/ReferralViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class ReferralViewModel: ObservableObject { @Published var code: String = \"SKATE123\"; @Published var link: String = \"https://skateroute.app/ref/SKATE123\" }\n'

write_if_missing "${APP_DIR}/Features/Onboarding/OnboardingViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class OnboardingViewModel: ObservableObject { @Published var step: Int = 0 }\n'

write_if_missing "${APP_DIR}/Features/Inbox/InboxViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class InboxViewModel: ObservableObject { struct Item: Identifiable { let id = UUID(); let title: String } ; @Published var items: [Item] = [Item(title: \"Welcome to SkateRoute\")] }\n'

write_if_missing "${APP_DIR}/Features/Settings/SettingsViewModel.swift" $'import Foundation\n\n@MainActor\nfinal class SettingsViewModel: ObservableObject { @Published var useMetric = true }\n'

# --- Views ---
write_if_missing "${APP_DIR}/Features/Search/SearchSheetView.swift" $'import SwiftUI\n\nstruct SearchSheetView: View {\n    @State private var query: String = \"\"\n    var onSelect: (String) -> Void = { _ in }\n    var body: some View {\n        VStack {\n            TextField(\"Search\", text: $query)\n                .textFieldStyle(.roundedBorder)\n                .accessibilityIdentifier(\"sr_search_pill\")\n            Button(\"Use \\\"\\(query)\\\"\") { onSelect(query) }\n                .buttonStyle(.borderedProminent)\n        }\n        .padding()\n    }\n}\n\n// Back-compat for existing reference\ntypealias PlaceSearchView = SearchSheetView\n'

write_if_missing "${APP_DIR}/Features/RoutePlanner/RoutePlannerView.swift" $'import SwiftUI\n\nstruct RoutePlannerView: View {\n    @StateObject private var vm = RoutePlannerViewModel()\n    var body: some View {\n        VStack(alignment: .leading, spacing: 12) {\n            HStack {\n                TextField(\"Origin\", text: $vm.origin).accessibilityIdentifier(\"sr_origin_chip\")\n                TextField(\"Destination\", text: $vm.destination).accessibilityIdentifier(\"sr_dest_chip\")\n            }\n            Button(\"Plan\") { vm.loadMock() }.accessibilityIdentifier(\"sr_cta_start\")\n            List(vm.options) { opt in\n                VStack(alignment: .leading) {\n                    Text(opt.name).bold()\n                    Text(\"\\(Int(opt.distanceMeters)) m • \\(Int(opt.expectedSeconds/60)) min • \\(opt.skateability.value)\")\n                }\n                .accessibilityIdentifier(\"sr_route_option_cell_\\(opt.id)\")\n            }\n        }\n        .padding()\n        .onAppear { vm.loadMock() }\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Navigation/NavigationHUDView.swift" $'import SwiftUI\n\nstruct NavigationHUDView: View {\n    @StateObject private var vm = NavigationViewModel()\n    var body: some View {\n        VStack(spacing: 8) {\n            Text(vm.nextInstruction).font(.title2).accessibilityIdentifier(\"sr_nav_next_turn\")\n            Text(vm.distanceToNext).accessibilityIdentifier(\"sr_nav_dist_to_turn\")\n            Text(\"Speed \\(vm.speedKmh) km/h\").accessibilityIdentifier(\"sr_nav_speed\")\n            HStack {\n                Button(\"Pause\"){}.accessibilityIdentifier(\"sr_nav_pause\")\n                Button(\"End\"){}.accessibilityIdentifier(\"sr_nav_end\")\n            }\n        }\n        .padding()\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Hazards/HazardReportView.swift" $'import SwiftUI\n\nstruct HazardReportView: View {\n    @StateObject private var vm = HazardReportViewModel()\n    var body: some View {\n        VStack {\n            Picker(\"Type\", selection: $vm.selectedType) {\n                ForEach(HazardType.allCases, id: \\.self) { Text($0.rawValue.capitalized).tag($0) }\n            }\n            .pickerStyle(.segmented)\n            .accessibilityIdentifier(\"sr_hazard_type_picker\")\n\n            Slider(value: $vm.confidence, in: 0...1)\n                .accessibilityIdentifier(\"sr_hazard_confidence\")\n\n            Button(\"Submit\") { Task { _ = await vm.submit() } }\n                .accessibilityIdentifier(\"sr_hazard_submit\")\n                .buttonStyle(.borderedProminent)\n        }\n        .padding()\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Spots/SpotsMapView.swift" $'import SwiftUI\nimport MapKit\n\nstruct SpotsMapView: View {\n    @StateObject private var vm = SpotsViewModel()\n    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12), span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))\n    var body: some View {\n        VStack {\n            Map(coordinateRegion: $region)\n                .accessibilityIdentifier(\"sr_spots_cluster\")\n            Button(\"Load Nearby\") { vm.loadNearby() }.accessibilityIdentifier(\"sr_spots_list_toggle\")\n            List(vm.spots) { spot in Text(spot.name).accessibilityIdentifier(\"sr_spot_card_\\(spot.id)\") }\n        }\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Spots/SpotDetailView.swift" $'import SwiftUI\n\nstruct SpotDetailView: View { let spot: Spot\n    var body: some View {\n        VStack(spacing: 12) {\n            Text(spot.name).font(.title)\n            HStack {\n                Button(\"Check In\"){}.accessibilityIdentifier(\"sr_spot_checkin\")\n                Button(\"Navigate\"){}.accessibilityIdentifier(\"sr_spot_navigate\")\n                Button(\"Add Media\"){}.accessibilityIdentifier(\"sr_spot_add_media\")\n            }\n        }.padding()\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Capture/CaptureView.swift" $'import SwiftUI\n\nstruct CaptureView: View { @StateObject private var vm = CaptureViewModel()\n    var body: some View {\n        VStack {\n            Rectangle().fill(.black).aspectRatio(9/16, contentMode: .fit)\n                .overlay(Text(vm.isRecording ? \"● REC\" : \"IDLE\").foregroundColor(.red))\n                .accessibilityIdentifier(\"sr_cam_preview\")\n            Button(vm.isRecording ? \"Stop\" : \"Record\") { vm.isRecording.toggle() }\n                .accessibilityIdentifier(\"sr_cam_record\")\n                .buttonStyle(.borderedProminent)\n        }.padding()\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Editor/EditorView.swift" $'import SwiftUI\n\nstruct EditorView: View { @StateObject private var vm = EditorViewModel()\n    var body: some View {\n        VStack {\n            Rectangle().strokeBorder().frame(height: 120).accessibilityIdentifier(\"sr_edit_timeline\")\n            Button(\"Export\") { vm.exportProgress = 1 }\n                .accessibilityIdentifier(\"sr_edit_export\")\n                .buttonStyle(.borderedProminent)\n        }.padding()\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Feed/FeedView.swift" $'import SwiftUI\n\nstruct FeedView: View { @StateObject private var vm = FeedViewModel()\n    var body: some View {\n        List(vm.posts) { post in PostCardView(post: post).accessibilityIdentifier(\"sr_feed_card\") }\n            .onAppear { vm.load() }\n            .accessibilityIdentifier(\"sr_feed_list\")\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Feed/PostCardView.swift" $'import SwiftUI\n\nstruct PostCardView: View { let post: Post\n    var body: some View {\n        VStack(alignment: .leading) {\n            Text(post.caption)\n            HStack { Button(\"Like\"){}.accessibilityIdentifier(\"sr_like_btn\"); Button(\"Comment\"){}.accessibilityIdentifier(\"sr_comment_btn\"); Button(\"Save\"){}.accessibilityIdentifier(\"sr_save_btn\") }\n        }.padding(.vertical, 8)\n    }\n}\n'

write_if_missing "${APP_DIR}/Features/Profile/ProfileView.swift" $'import SwiftUI\n\nstruct ProfileView: View { @StateObject private var vm = ProfileViewModel()\n    var body: some View { VStack { Text(vm.profile.displayName).font(.title).accessibilityIdentifier(\"sr_profile_header\"); Text(\"Badges: \\(vm.profile.badges.count)\") }.padding() }\n}\n'

write_if_missing "${APP_DIR}/Features/Challenges/ChallengesView.swift" $'import SwiftUI\n\nstruct ChallengesView: View { @StateObject private var vm = ChallengesViewModel()\n    var body: some View { List(vm.challenges) { c in VStack(alignment: .leading) { Text(c.title); Text(c.rules).font(.footnote) } }.accessibilityIdentifier(\"sr_challenge_carousel\") }\n}\n'

write_if_missing "${APP_DIR}/Features/Leaderboard/LeaderboardView.swift" $'import SwiftUI\n\nstruct LeaderboardView: View { @StateObject private var vm = LeaderboardViewModel()\n    var body: some View { List(vm.entries) { e in HStack { Text(e.name); Spacer(); Text(\"\\(e.score)\") }.accessibilityIdentifier(\"sr_lb_row_\\(e.id)\") } }\n}\n'

write_if_missing "${APP_DIR}/Features/Paywall/PaywallView.swift" $'import SwiftUI\n\nstruct PaywallView: View { @StateObject private var vm = PaywallViewModel()\n    var body: some View { VStack(spacing: 12) { Text(\"Go Pro\").font(.title); Button(\"Purchase\") { vm.isPro = true }.accessibilityIdentifier(\"sr_paywall_cta\"); Button(\"Restore\"){}.accessibilityIdentifier(\"sr_paywall_restore\") }.padding().accessibilityIdentifier(\"sr_paywall\") }\n}\n'

write_if_missing "${APP_DIR}/Features/Referral/ReferralView.swift" $'import SwiftUI\n\nstruct ReferralView: View { @StateObject private var vm = ReferralViewModel()\n    var body: some View { VStack { Text(\"Your code: \\(vm.code)\").accessibilityIdentifier(\"sr_ref_code\"); Text(vm.link).font(.footnote); Button(\"Share\"){}.accessibilityIdentifier(\"sr_ref_share_btn\") }.padding() }\n}\n'

write_if_missing "${APP_DIR}/Features/Onboarding/OnboardingView.swift" $'import SwiftUI\n\nstruct OnboardingView: View { @StateObject private var vm = OnboardingViewModel()\n    var body: some View { VStack { Text(\"Welcome • Step \\(vm.step + 1)/3\").accessibilityIdentifier(\"sr_onb_page_\\(vm.step)\"); Button(\"Next\") { vm.step = min(2, vm.step + 1) } }.padding() }\n}\n'

write_if_missing "${APP_DIR}/Features/Inbox/InboxView.swift" $'import SwiftUI\n\nstruct InboxView: View { @StateObject private var vm = InboxViewModel()\n    var body: some View { List(vm.items) { item in Text(item.title) }.accessibilityIdentifier(\"sr_inbox_list\") }\n}\n'

write_if_missing "${APP_DIR}/Features/Settings/SettingsView.swift" $'import SwiftUI\n\nstruct SettingsView: View { @StateObject private var vm = SettingsViewModel()\n    var body: some View { Form { Toggle(\"Use Metric\", isOn: $vm.useMetric) }.accessibilityIdentifier(\"sr_settings_form\") }\n}\n'

# --- UI Tests seed ---
write_if_missing "${UITESTS_DIR}/SkateRouteUITests.swift" $'import XCTest\n\nfinal class SkateRouteUITests: XCTestCase {\n    override func setUp() { continueAfterFailure = false }\n\n    func test_AppLaunches_Smoke() {\n        let app = XCUIApplication(); app.launchArguments += [\"--uitest-smoke\"]; app.launch(); XCTAssertEqual(app.state, .runningForeground)\n    }\n\n    func test_CommonIdentifiers_AreQueryable() {\n        let app = XCUIApplication(); app.launch()\n        let ids = [\"sr_map_canvas\", \"sr_search_pill\", \"sr_fab_go\", \"sr_origin_chip\", \"sr_dest_chip\", \"sr_cta_start\", \"sr_nav_next_turn\", \"sr_hazard_submit\", \"sr_spots_cluster\", \"sr_feed_list\", \"sr_profile_header\", \"sr_paywall\", \"sr_ref_code\", \"sr_onb_page_0\", \"sr_inbox_list\", \"sr_settings_form\"]\n        var foundAny = false\n        for id in ids { if app.descendants(matching: .any)[id].firstMatch.exists { foundAny = true; break } }\n        XCTAssertTrue(foundAny, \"Expected at least one known accessibilityIdentifier on launch.\")\n    }\n}\n'

log "Done. Review created paths above and add to target membership if needed."
