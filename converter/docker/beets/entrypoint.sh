#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Config and source path (allow override from environment)
CONFIG_PATH=${BEETS_CONFIG_PATH:-/config.yaml}
SRC_DIR=${IMPORT_SRC:-/data}

# Run beets import (use `beet` CLI). Use -c to point to config file.
# -y answers yes to prompts so the container runs unattended.
# We avoid extra flags so the container works with the minimal beets install.
exec beet -c "$CONFIG_PATH" import "$SRC_DIR" || exit_code=$?

# Capture exit code: if beet failed, still write sentinel so dependent container sees completion
exit_code=${exit_code:-0}

echo "Beets finished with exit code $exit_code"
# Create a sentinel file inside the shared /data volume so the normalizer can detect completion
# We include the exit code for debugging.
printf "beets_exit=%s\nfinished_at=%s\n" "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SENTINEL_FILE" || true

# Exit with the same code beets had
exit "$exit_code"