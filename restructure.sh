#!/usr/bin/env bash
set -euo pipefail

# Ensure we’re in the inner project folder (contains Swift files / .xcodeproj)
if [[ ! -d .git && -d ../.git ]]; then
  echo "Tip: you're likely in the right folder; git repo is one level up."
fi

# Make the destination folders that match your Xcode groups
mkdir -p Core \
         Features/Community/Models \
         Features/Community/Views \
         Features/Home \
         Features/Map/Views \
         Features/Search \
         Features/UX \
         Resources \
         Services \
         Support/Utilities \
         Info

# Safe move that prefers git mv (keeps history), falls back to mv
move() {
  local src="$1"
  local dest="$2"
  [[ -e "$src" ]] || { echo "skip (missing): $src"; return 0; }
  mkdir -p "$dest"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git mv -k "$src" "$dest/" 2>/dev/null || mv -n "$src" "$dest/"
  else
    mv -n "$src" "$dest/"
  fi
}

echo "== Core =="
move "AppCoordinator.swift" "Core"
move "AppDI.swift"          "Core"
move "AppRouter.swift"      "Core"

echo "== Features / Community =="
move "SurfaceRating.swift"  "Features/Community/Models"
move "QuickReportView.swift" "Features/Community/Views"

echo "== Features / Home =="
move "HomeView.swift"      "Features/Home"
move "HomeViewModel.swift" "Features/Home"

echo "== Features / Map =="
move "MapScreen.swift"              "Features/Map"
move "MapViewContainer.swift"       "Features/Map"
move "SmoothOverlayRenderer.swift"  "Features/Map"
# If these exist in your tree, we’ll place them under Views:
move "ElevationProfileView.swift"   "Features/Map/Views"
move "LayerToggleBar.swift"         "Features/Map/Views"
move "RoutePlannerView.swift"       "Features/Map/Views"
move "RoutePlannerViewModel.swift"  "Features/Map/Views"

echo "== Features / Search =="
move "PlaceSearchView.swift"       "Features/Search"
move "PlaceSearchViewModel.swift"  "Features/Search"

echo "== Features / UX =="
move "HapticCue.swift"         "Features/UX"
move "RideMode.swift"          "Features/UX"
move "RideTelemetryHUD.swift"  "Features/UX"
move "SpeedHUDView.swift"      "Features/UX"
move "TurnCueEngine.swift"     "Features/UX"

echo "== Resources =="
move "attrs-victoria.json"     "Resources"
move "PrivacyInfo.xcprivacy"   "Resources"

echo "== Services =="
move "AttributionService.swift"      "Services"
move "CacheManager.swift"            "Services"
move "ElevationService.swift"        "Services"
move "GeocoderService.swift"         "Services"
move "LocationManagerService.swift"  "Services"
move "Matcher.swift"                 "Services"
move "MatcherTypes.swift"            "Services"
move "MotionRoughnessService.swift"  "Services"
move "OfflineTileManager.swift"      "Services"
move "OfflineRouteStore.swift"       "Services"
move "RerouteController.swift"       "Services"
move "RideRecorder.swift"            "Services"
move "RouteContextBuilder.swift"     "Services"
move "RouteOptionsReducer.swift"     "Services"
move "RouteService.swift"            "Services"
move "SegmentStore.swift"            "Services"
move "SessionLogger.swift"           "Services"
move "SkateRouteScorer.swift"        "Services"
move "SmoothnessEngine.swift"        "Services"

echo "== Support / Utilities =="
move "AccuracyProfile.swift"   "Support/Utilities"
move "Geometry.swift"          "Support/Utilities"

echo "== Info (plist/entitlements) =="
move "Info.plist"                  "Info"
move "SKATEROUTE.entitlements"     "Info"

echo "== Done. =="
# Stage & commit if run inside a git repo
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "chore(tree): normalize layout into Core/Features/Services/Resources/Support/Info"
    echo "Committed tree restructure."
  else
    echo "Nothing to commit."
  fi
fi

echo "Tip: In Xcode, if any files show RED, remove old references (Keep Files), then drag the folders back in using 'Create groups' and tick your app target."
