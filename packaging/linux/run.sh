#!/bin/sh
set -eu
bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
model_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/nexus-remote/models
if [ -z "${NEXUS_REMOTE_MODEL:-}" ]; then
    NEXUS_REMOTE_MODEL=$(python3 "$bundle_dir/models/install.py" quality --directory "$model_dir")
fi
NEXUS_REMOTE_WORKER="$bundle_dir/nexus-remote-speech-worker"
export NEXUS_REMOTE_MODEL NEXUS_REMOTE_WORKER
exec "$bundle_dir/nexus-remote-companion"
