#!/usr/bin/env bash
set -euo pipefail

# Inputs
VERSION="${MARKETING_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(git ls-files -z | xargs -0 -n1 | grep -m1 Info.plist)")}"
COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD)}"
DATE="$(date +%Y-%m-%d)"

SRC_DIR="Resources/Legal"
OUT_DIR="LegalSnapshots/${VERSION}/${COMMIT}"

mkdir -p "${OUT_DIR}"

# Replace {{GIT_COMMIT}} and Effective date lines while copying
for f in PrivacyPolicy.md TermsOfUse.md; do
  [ -s "${SRC_DIR}/${f}" ] || { echo "Missing ${SRC_DIR}/${f}"; exit 1; }
  sed \
    -e "s/{{GIT_COMMIT}}/${COMMIT}/g" \
    -e "s/^\\*\\*Effective date:\\*\\*.*/**Effective date:** ${DATE}/" \
    "${SRC_DIR}/${f}" > "${OUT_DIR}/${f}"
done

echo "Snapshot written to ${OUT_DIR}"