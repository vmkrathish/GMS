#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  tools/verify_push_fixes.sh — runs every check for the push-notification
#  fixes. READ-ONLY with respect to production: it never deploys, never
#  touches Render/Supabase/Firebase, and needs no credentials.
#
#    ./tools/verify_push_fixes.sh                 # everything available
#    SKIP_FLUTTER=1 ./tools/verify_push_fixes.sh  # backend + service worker only
#
#  Backend tests need a THROWAWAY PostgreSQL whose name contains "test":
#    export TEST_DATABASE_URL=postgresql+psycopg2://USER:PASS@localhost:5432/gms_test
#
#  Exit code 0 only if nothing failed. Skipped sections are listed, never
#  silently counted as passes.
# ═══════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIPPED=()

step() {   # step "name" cmd...
  local name="$1"; shift
  echo; echo "── $name"
  if "$@"; then echo "   ✔ PASS: $name"; PASS=$((PASS+1)); else echo "   ✘ FAIL: $name"; FAIL=$((FAIL+1)); fi
}
skip() { echo; echo "── $1"; echo "   ⏭ SKIPPED: $2"; SKIPPED+=("$1 — $2"); }

# ── Flutter: analyze, unit tests, Web build (+ service worker check), Android APK
if [[ -n "${SKIP_FLUTTER:-}" ]]; then
  skip "Flutter checks" "SKIP_FLUTTER is set"
elif ! command -v flutter >/dev/null 2>&1; then
  skip "Flutter checks" "flutter is not on PATH"
else
  pushd "$ROOT/frontend" >/dev/null
  step "flutter pub get"            flutter pub get
  step "flutter analyze"            flutter analyze
  step "flutter test (push fixes)"  flutter test test/push_registrar_test.dart test/device_identity_test.dart
  step "flutter build web --release" flutter build web --release
  step "built web bundle contains the service worker, identical to source" \
       cmp web/firebase-messaging-sw.js build/web/firebase-messaging-sw.js
  if [[ -n "${SKIP_APK:-}" ]]; then
    # The APK build is the heaviest step (Gradle -Xmx4g + Kotlin daemon).
    # SKIP_APK=1 runs everything else; build the APK separately when the
    # machine has the memory for it.
    skip "flutter build apk" "SKIP_APK is set"
  elif [[ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]] || command -v adb >/dev/null 2>&1; then
    step "flutter build apk --release" flutter build apk --release
  else
    skip "flutter build apk" "no Android SDK detected (set ANDROID_HOME)"
  fi
  popd >/dev/null
fi

# ── Service worker (executes the real file in a mocked worker scope)
if command -v node >/dev/null 2>&1; then
  step "service worker tests" node --test "$ROOT/frontend/test/web_sw/firebase_messaging_sw.test.js"
else
  skip "service worker tests" "node is not installed"
fi

# ── Backend (real PostgreSQL)
if [[ -z "${TEST_DATABASE_URL:-}" ]]; then
  skip "backend tests" "TEST_DATABASE_URL is not set"
elif ! python3 -c "import pytest, fastapi, httpx, firebase_admin" >/dev/null 2>&1; then
  skip "backend tests" "missing Python deps: pip install -r backend/requirements.txt pytest httpx"
else
  pushd "$ROOT/backend" >/dev/null
  step "backend tests (pytest)" python3 -m pytest -q
  popd >/dev/null
fi

echo; echo "════════ SUMMARY ════════"
echo "passed: $PASS   failed: $FAIL   skipped: ${#SKIPPED[@]}"
for s in "${SKIPPED[@]:-}"; do [[ -n "$s" ]] && echo "  skipped → $s"; done
[[ $FAIL -eq 0 ]] || { echo "RESULT: FAILED"; exit 1; }
if [[ ${#SKIPPED[@]} -eq 0 ]]; then
  echo "RESULT: ALL CHECKS PASSED"
elif [[ -n "${ALLOW_SKIPS:-}" ]]; then
  echo "RESULT: no failures; some checks were SKIPPED (ALLOW_SKIPS set)"
else
  echo "RESULT: no failures, but some checks were SKIPPED (not verified) -> exit 2"
  echo "        (set ALLOW_SKIPS=1 to accept skips, e.g. on a machine without Flutter)"
  exit 2
fi
