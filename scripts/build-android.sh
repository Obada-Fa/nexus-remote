#!/usr/bin/env bash
# Build the Android APKs into dist/: nexus-remote-<version>-android.apk and nexus-tv-<version>-android.apk.
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
rm -f "$root/dist/nexus-"{remote,tv}"-$version-"*
build() {   # flavor entry file output name
  "$flutter" build apk --release --flavor "$1" -t "$2"
  cp "build/app/outputs/flutter-apk/app-$1-release.apk" "$root/dist/$3-$version-android.apk"
  (cd "$root/dist" && sha256sum "$3-$version-android.apk" > "$3-$version-SHA256SUMS.txt")
}
build full lib/main.dart nexus-remote
build tv lib/main_tv.dart nexus-tv
ls -la "$root/dist/"*"-$version-"*
