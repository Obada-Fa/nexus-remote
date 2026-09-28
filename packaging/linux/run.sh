#!/bin/sh
set -eu
bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
model_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/nexus-remote/models
NEXUS_REMOTE_MODEL=${NEXUS_REMOTE_MODEL:-"$model_dir/ggml-large-v3-turbo-q5_0.bin"}
NEXUS_REMOTE_WORKER="$bundle_dir/nexus-remote-speech-worker"
export NEXUS_REMOTE_MODEL NEXUS_REMOTE_WORKER
exec "$bundle_dir/nexus-remote-companion"
