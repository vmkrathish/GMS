#!/usr/bin/env bash
# ─────────────────────────────────────────────
# scripts/bump_version.sh — run this before each release build.
#
# pubspec.yaml's `version: X.Y.Z+N` line is the ONE place the whole
# app's version comes from — the About screen, and now the APK's own
# filename (see android/app/build.gradle.kts), both read it
# automatically. This script just increments the build number (+N)
# for you, since Flutter has no fully-automatic way to do that on its
# own and Play Store / most install methods require every release to
# have a strictly higher build number than the last.
#
# Usage:
#   ./scripts/bump_version.sh            # bumps the build number only (1.0.0+1 -> 1.0.0+2)
#   ./scripts/bump_version.sh patch      # bumps patch + build number (1.0.0+1 -> 1.0.1+2)
#   ./scripts/bump_version.sh minor      # bumps minor + resets patch (1.0.0+1 -> 1.1.0+2)
#   ./scripts/bump_version.sh major      # bumps major + resets minor/patch (1.0.0+1 -> 2.0.0+2)
# ─────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

PUBSPEC="pubspec.yaml"
CURRENT=$(grep -E "^version:" "$PUBSPEC" | sed -E 's/version:\s*//')
VERSION_PART="${CURRENT%+*}"
BUILD_PART="${CURRENT#*+}"

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION_PART"
NEW_BUILD=$((BUILD_PART + 1))

case "${1:-}" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  "") : ;; # build number only
  *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}+${NEW_BUILD}"
sed -i.bak -E "s/^version:.*/version: ${NEW_VERSION}/" "$PUBSPEC"
rm -f "${PUBSPEC}.bak"

echo "Version bumped: ${CURRENT} → ${NEW_VERSION}"
echo "Now run: flutter build apk --release"
echo "Output will be: build/app/outputs/flutter-apk/GMS-v${MAJOR}.${MINOR}.${PATCH}.apk"
