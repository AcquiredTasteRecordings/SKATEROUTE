# frozen_string_literal: true
#
# SKATEROUTE – Fastlane configuration
# ----------------------------------------------------------------------------
# Goals
#  • One-command shipment to TestFlight (lane: `beta`)
#  • Consistent local + CI behavior (always use `bundle exec` on CI)
#  • Clear hooks for code signing, changelogs, artifacts, and promotions
#  • Senior-engineer friendly with explicit env var usage and safe defaults
# ----------------------------------------------------------------------------

# --- Platform -----------------------------------------------------------------

default_platform(:ios)

# --- Conventions & Environment ------------------------------------------------
# Configure these via repository secrets / local .env files (dotenv supported):
#   APP_IDENTIFIER            e.g. "com.yourorg.skateroute"
#   APPLE_TEAM_ID             e.g. "ABCDE12345"
#   ASC_KEY_ID                App Store Connect API key id
#   ASC_ISSUER_ID             App Store Connect issuer id
#   ASC_KEY                   Base64-encoded .p8 contents (no newlines)
#   APP_STORE_CONNECT_USER    (fallback if API key not provided)
#   TESTFLIGHT_GROUPS         Comma-separated list, e.g. "Internal,Friends"
#   BETA_FEEDBACK_EMAIL       Email for TestFlight feedback
#   BETA_DESCRIPTION          Release notes text override
#   SCHEME                    Xcode scheme (default: SKATEROUTE)
#   PROJECT                   Xcode project (default: SKATEROUTE.xcodeproj)
#   EXPORT_METHOD             export method (default: app-store)
#   FORCE_FULL_BUILD          if "1", perform a clean build
# -----------------------------------------------------------------------------

# Helper to read env with fallback
def env_or(key, fallback)
  (ENV[key] && !ENV[key].empty?) ? ENV[key] : fallback
end

# Shared config
APP_ID        = env_or('APP_IDENTIFIER', 'com.example.skateroute')
TEAM_ID       = env_or('APPLE_TEAM_ID',  'ABCDE12345')
SCHEME        = env_or('SCHEME',         'SKATEROUTE')
PROJECT       = env_or('PROJECT',        'SKATEROUTE.xcodeproj')
EXPORT_METHOD = env_or('EXPORT_METHOD',  'app-store')

# Directories
BUILD_DIR     = File.join(Dir.pwd, 'build')
ARTIFACTS_DIR = File.join(BUILD_DIR, 'artifacts')

platform :ios do
  before_all do
    UI.message("🏁 Starting Fastlane for #{SCHEME} (#{APP_ID})…")
    FileUtils.mkdir_p(ARTIFACTS_DIR)
  end

  after_all do |lane|
    UI.success("✅ Lane #{lane} finished. Artifacts in: #{ARTIFACTS_DIR}")
  end

  error do |lane, exception|
    UI.error("❌ Lane #{lane} failed: #{exception.message}")
    UI.user_error!("Build failed – check logs and xcresult in #{ARTIFACTS_DIR}")
  end

  # --- Private helpers --------------------------------------------------------

  private_lane :asc_api_key do
    if ENV['ASC_KEY_ID'] && ENV['ASC_ISSUER_ID'] && ENV['ASC_KEY']
      UI.message('🔐 Using App Store Connect API key from environment')
      app_store_connect_api_key(
        key_id: ENV['ASC_KEY_ID'],
        issuer_id: ENV['ASC_ISSUER_ID'],
        key_content: ENV['ASC_KEY'],
        is_key_content_base64: true
      )
    else
      UI.important('No ASC API key configured – Fastlane may prompt for Apple ID')
      nil
    end
  end

  private_lane :derive_changelog do
    # Use commit messages since the last tag; fallback to a generic note
    notes = changelog_from_git_commits(
      include_merges: false,
      pretty: "• %h %s",
      date_format: "short",
      between: [last_git_tag, 'HEAD']
    ) rescue nil
    if notes.nil? || notes.strip.empty?
      notes = env_or('BETA_DESCRIPTION', 'Downhill-first routing + smoothness scoring improvements and stability fixes.')
    end
    UI.message("📝 Changelog prepared (#{notes.length} chars)")
    notes
  end

  private_lane :build_number_bump do
    increment_build_number(
      xcodeproj: PROJECT
    )
  end

  private_lane :compile do |options|
    result_bundle = File.join(ARTIFACTS_DIR, 'build.xcresult')

    xcodebuild_flags = [
      "PRODUCT_BUNDLE_IDENTIFIER=#{APP_ID}",
      "DEVELOPMENT_TEAM=#{TEAM_ID}"
    ]

    clean_build = ENV['FORCE_FULL_BUILD'] == '1'

    build_app(
      scheme: SCHEME,
      project: PROJECT,
      export_method: EXPORT_METHOD,
      output_directory: BUILD_DIR,
      include_bitcode: false,
      include_symbols: true,
      result_bundle: true,
      xcargs: xcodebuild_flags.join(' '),
      clean: clean_build
    )

    # Move the latest .xcresult into artifacts
    Dir[File.join(BUILD_DIR, '*.xcresult')].each do |xc|
      FileUtils.mv(xc, result_bundle) rescue nil
    end

    # Stash dSYM zips
    Dir[File.join(BUILD_DIR, '*.dSYM.zip')].each do |dsym|
      FileUtils.mv(dsym, ARTIFACTS_DIR) rescue nil
    end

    # Return path to the generated IPA (or app bundle on macOS runners)
    Dir[File.join(BUILD_DIR, '*.ipa')].first || Dir[File.join(BUILD_DIR, '*.app')].first
  end

  # --- Lanes ------------------------------------------------------------------

  desc 'Run unit tests on the default simulator (for CI preflight)'
  lane :test do
    scan(
      project: PROJECT,
      scheme: SCHEME,
      devices: ['iPhone 16 Pro'],
      code_coverage: true,
      clean: true,
      result_bundle: true,
      output_directory: ARTIFACTS_DIR
    )
  end

  desc 'Build only (no upload). Produces IPA, dSYM, and xcresult artifacts.'
  lane :build do
    build_number_bump
    compile
  end

  desc 'Build & upload to TestFlight (one command to ship)'
  lane :beta do
    api_key = asc_api_key
    build_number_bump

    ipa_path = compile

    notes    = derive_changelog
    groups   = env_or('TESTFLIGHT_GROUPS', 'Internal').split(',').map(&:strip)
    feedback = env_or('BETA_FEEDBACK_EMAIL', 'you@example.com')

    upload_to_testflight(
      ipa: ipa_path,
      api_key: api_key,
      skip_waiting_for_build_processing: true,
      distribute_external: true,
      groups: groups,
      changelog: notes,
      beta_app_description: env_or('BETA_DESCRIPTION', 'SkateRoute beta: downhill-first routing + smoothness scoring.'),
      beta_app_feedback_email: feedback,
      notify_external_testers: true
    )

    UI.success('🚀 Uploaded to TestFlight!')
  end

  desc 'Promote the latest TestFlight build to App Store (manual review by default)'
  lane :promote do
    api_key = asc_api_key

    precheck(api_key: api_key)

    deliver(
      api_key: api_key,
      submit_for_review: false,
      automatic_release: false,
      force: true,
      skip_screenshots: true,
      skip_metadata: true
    )

    UI.success('📦 Metadata validated. Ready for manual App Store submission in ASC.')
  end

  desc 'CI entry point – runs tests then archives on main'
  lane :ci do
    lane_context[:CI] = true
    test
    build if Actions.git_branch == 'main'
  end
end
