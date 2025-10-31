# frozen_string_literal: true

# SKATEROUTE — Ruby gems for Release Automation, CI, and Code Quality
# ----------------------------------------------------------------------------
# Purpose
#  • Provide a reproducible toolchain for TestFlight distribution (one command)
#  • Keep CI and local developer environments in sync via Bundler
#  • Pin critical versions to avoid unexpected breaking changes
#
# How to use
#  1) Ensure Ruby 3.2+ (see .ruby-version if present)
#  2) Install Bundler once:    gem install bundler:2.5.7
#  3) Install deps:            bundle install
#  4) Ship to TestFlight:      bundle exec fastlane beta
#  5) CI runs lanes via:       bundle exec fastlane ci
# ----------------------------------------------------------------------------

source "https://rubygems.org"

# Recommended Ruby toolchain baseline
ruby ">= 3.2.0"

# Core release automation (deliver/pilot/gym/match/etc.)
# Use a lower-bounded constraint to allow security/bugfix updates while
# staying within the current major version.
gem "fastlane", ">= 2.220.0"

# Keep Bundler version modern & explicit for CI parity
gem "bundler", ">= 2.5"

# Developer Experience & CI helpers
# These are optional on local machines but extremely useful on CI. We keep them
# in a group so they can be excluded via `BUNDLE_WITHOUT` if desired.
# Example: BUNDLE_WITHOUT=lint bundle install

group :development, :ci do
  # Manage environment variables for lanes (API keys, bundle ids, etc.)
  gem "dotenv", ">= 2.8"

  # Pretty Xcode log output when not using xcbeautify (CI fallback)
  gem "xcpretty", ">= 0.3.0", require: false

  # PR automation (comments, changelog checks). Optional — enable on CI with token.
  gem "danger", ">= 9.0", require: false

  # Version bump helpers (semantic versioning from git, Info.plist updates). Optional.
  gem "fastlane-plugin-versioning", ">= 0.5", require: false

  # If you adopt CocoaPods later, uncomment the line below to pin a modern version.
  # gem "cocoapods", ">= 1.15", require: false
end

# Lint & Style (optional)
# SwiftLint is typically installed via Homebrew on macOS runners. We keep the
# Fastlane plugin here (commented) so it’s easy to enable later.
# group :lint do
#   gem "fastlane-plugin-swiftlint", ">= 0.33", require: false
# end

# Notes
#  • Fastlane plugins are best managed via `fastlane add_plugin ...`, which writes
#    to fastlane/Pluginfile. Keeping optional plugin gems commented here simply
#    documents choices and preferred version ranges for future enablement.
#  • Commit Gemfile and Gemfile.lock to lock the toolchain across the team & CI.
#  • Use `bundle exec` for every Fastlane/Danger/xcpretty invocation to guarantee
#    you’re using the locked versions from Gemfile.lock.