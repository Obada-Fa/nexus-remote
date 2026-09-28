#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir=${1:-"${TMPDIR:-/tmp}/nexus-remote-linux-build"}
mkdir -p "$build_dir"
CARGO_TARGET_DIR="$build_dir/cargo"
export CARGO_TARGET_DIR
cargo build --release --manifest-path "$root/companion/Cargo.toml"
cmake -S "$root/speech-worker" -B "$build_dir/worker" -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir/worker" --target nexus-remote-speech-worker -j 8
stage="$build_dir/nexus-remote-linux-x11-dev"
mkdir -p "$stage/models"
cp "$CARGO_TARGET_DIR/release/nexus-remote-companion" "$stage/"
cp "$build_dir/worker/nexus-remote-speech-worker" "$stage/"
cp -a "$build_dir/worker/bin/"lib*.so* "$stage/"
cp "$root/packaging/linux/run.sh" "$root/packaging/linux/README.txt" "$stage/"
cp "$root/models/install.py" "$root/models/manifest.json" "$stage/models/"
chmod +x "$stage/run.sh"
tar -C "$build_dir" -czf "$build_dir/nexus-remote-linux-x11-dev.tar.gz" nexus-remote-linux-x11-dev
