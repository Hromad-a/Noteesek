#!/usr/bin/env bash
#
# Build a release APK and publish it as a GitHub Release asset for remote
# (on-phone) sideload testing. No GitHub Actions involved — the build is local
# and `gh` only uploads the artifact.
#
# Repo is private, so to install on a phone: open github.com in the phone
# browser, sign in, go to Releases, and tap the .apk (the session cookie
# authenticates the download).
#
# Requirements: flutter, gh (GitHub CLI, authenticated — `gh auth login`).
# Usage: ./scripts/release-apk.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"

# --- preflight ----------------------------------------------------------------
command -v flutter >/dev/null || { echo "error: flutter not found on PATH" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found. Install: brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated. Run: gh auth login" >&2; exit 1; }

# --- build (arm64-v8a split) --------------------------------------------------
echo "==> Building release APK (arm64-v8a)..."
cd "$APP_DIR"
# Stamp the build with its commit + date (shown in Settings → About). No
# BUILD_SOURCE: this is a local sideload build, so About reads "Local build".
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --dart-define=GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo '')" \
  --dart-define=BUILD_DATE="$(date -u +%Y-%m-%d)"

APK_SRC="$APP_DIR/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
[ -f "$APK_SRC" ] || { echo "error: expected APK not found at $APK_SRC" >&2; exit 1; }

# --- name + upload ------------------------------------------------------------
TAG="test-$(date +%Y%m%d-%H%M)"
# include the pubspec version in the asset name for sanity, tag stays time-based
APP_VERSION="$(grep -m1 '^version:' "$APP_DIR/pubspec.yaml" | awk '{print $2}')"
ASSET_NAME="noteesek-${APP_VERSION//+/_}-arm64-v8a.apk"
ASSET_PATH="$(dirname "$APK_SRC")/$ASSET_NAME"
cp "$APK_SRC" "$ASSET_PATH"

echo "==> Creating GitHub Release $TAG ..."
gh release create "$TAG" "$ASSET_PATH" \
  --repo Hromad-a/Noteesek \
  --title "Test build $TAG (v$APP_VERSION)" \
  --notes "Sideload test build. arm64-v8a, debug-signed. Built $(date '+%Y-%m-%d %H:%M %Z')." \
  --target "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"

echo
echo "==> Done. Release page:"
gh release view "$TAG" --repo Hromad-a/Noteesek --web --json url --jq '.url' 2>/dev/null \
  || gh release view "$TAG" --repo Hromad-a/Noteesek --json url --jq '.url'
echo "    Open that on your phone (signed into GitHub) and tap the .apk to install."
