#!/usr/bin/env bash
# Build the Android APK into dist/nexus-remote-<version>-android.apk.
# The Nexus TV app moved to the Imac repo (mobile/, scripts/build-phone-app.sh).
# Builds from a copy on the Linux disk: gradlew can't be executed from this repo's NTFS drive.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^version: \([^+]*\)+.*/\1/p' "$root/mobile/pubspec.yaml")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rsync -a --exclude build --exclude .dart_tool --exclude android/.gradle "$root/mobile/" "$work/"
chmod +x "$work/android/gradlew"
cd "$work"
flutter=${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}
rm -f "$root/dist/nexus-remote-$version-"*
"$flutter" build apk --release
cp build/app/outputs/flutter-apk/app-release.apk "$root/dist/nexus-remote-$version-android.apk"
(cd "$root/dist" && sha256sum "nexus-remote-$version-android.apk" > "nexus-remote-$version-SHA256SUMS.txt")
ls -la "$root/dist/"*"-$version-"*
