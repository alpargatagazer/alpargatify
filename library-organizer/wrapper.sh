#!/usr/bin/env bash
# wrapper.sh
#  - Runs flac-to-aac.sh converter into a temporary directory (preserving paths)
#  - Then runs a single Docker Compose service: beets, which imports from the temp dir
#
# Modes:
#   Default (no mode flags): convert -> beets import (move + autotag)
#   --convert-only         : run converter only, then exit
#   --import-only          : skip conversion, run beets import (full)
#   --order-only           : run beets to only move files into library (no autotag / no tag writes)
#   --tag-only             : run beets to only autotag (write tags) but do not move/copy files
#
# Usage:
#   ./wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] \
#                [--convert-only|--import-only|--order-only|--tag-only] \
#                /path/to/source /absolute/path/to/music_library_root

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
BEETS_CONFIG="$SCRIPT_DIR/docker/beets/beets_config.yaml"
FORCE="no"
DRY_RUN="no"

# Mode flags (mutually exclusive)
MODE="full"  # values: full, convert-only, import-only, order-only, tag-only

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--beets-config /path/to/beets_config.yaml] \
       [--convert-only | --import-only | --order-only | --tag-only] \
       /path/to/source /absolute/path/to/music_library_root

Modes (mutually exclusive):
 - (default) full         : convert -> beets import (move + autotag)
 - --convert-only         : run converter only, then exit
 - --import-only          : skip conversion; run beets import (move + autotag)
 - --order-only           : run beets import but only move files into library (no autotag / no tag writes)
 - --tag-only             : run beets autotag / write tags but do not move files

Notes:
 - Destination must be the root of your music library (where beets will place files).
 - The converter will write into a temporary directory; beets will read from that temp dir and move files into the destination library (unless you choose tag-only).
EOF
}

# Parse args
POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --force) FORCE="yes"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --beets-config) BEETS_CONFIG="$2"; shift 2 ;;
    --convert-only) MODE="convert-only"; shift ;;
    --import-only) MODE="import-only"; shift ;;
    --order-only) MODE="order-only"; shift ;;
    --tag-only) MODE="tag-only"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  echo "Error: source and destination required." >&2
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

# Sanity checks
if [ ! -d "$SRC" ]; then
  echo "Error: source directory does not exist: $SRC" >&2
  exit 3
fi

# Ensure DEST is absolute path
if [[ "$DEST" != /* ]]; then
  echo "Error: destination must be an absolute path (root of your music library)." >&2
  exit 8
fi
mkdir -p "$DEST"

CONVERTER="$SCRIPT_DIR/flac-to-aac.sh"
if [ ! -x "$CONVERTER" ]; then
  echo "Error: converter script not found or not executable at: $CONVERTER" >&2
  exit 4
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH. Docker is required." >&2
  exit 5
fi

# Compose command check (docker compose or docker-compose)
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found. Install Docker Compose." >&2
  exit 6
fi

# Confirm beets config exists (warning if not)
if [ -n "$BEETS_CONFIG" ]; then
  if [ -f "$BEETS_CONFIG" ]; then
    echo "Using beets config: $BEETS_CONFIG"
  else
    echo "Warning: beets_config not found at $BEETS_CONFIG. The beets container will run with its default config." >&2
  fi
fi

echo "=== Settings ==="
echo "Script dir:         $SCRIPT_DIR"
echo "Source (input):     $SRC"
echo "Music library root: $DEST"
echo "Converter:          $CONVERTER"
echo "Beets config:       $BEETS_CONFIG"
echo "Force:              $FORCE"
echo "Dry run:            $DRY_RUN"
echo "Mode:               $MODE"
echo "Docker compose:     $COMPOSE_CMD"
echo "================"
echo

# Create temporary directory for converter output
TMP_DEST="$(mktemp -d -t beets_import_XXXXXX)"
echo "Temporary converter destination: $TMP_DEST"

# Ensure tempdir cleanup on exit (unless leaving for inspection in dry-run)
cleanup() {
  if [ "$DRY_RUN" = "yes" ]; then
    echo "Dry-run mode: leaving temporary directory for inspection: $TMP_DEST"
  else
    echo "Cleaning up temporary directory: $TMP_DEST"
    rm -rf "$TMP_DEST" || true
  fi
}
trap cleanup EXIT

# Helper: run converter (writes into TMP_DEST)
run_converter() {
  conv_args=()
  [ "$FORCE" = "yes" ] && conv_args+=(--force)
  [ "$DRY_RUN" = "yes" ] && conv_args+=(--dry-run)
  conv_args+=( "$SRC" "$TMP_DEST" )

  echo "-> running converter (output -> temp dir)"
  echo "Running: $CONVERTER ${conv_args[*]}"
  "$CONVERTER" "${conv_args[@]}"
  echo "-> converter finished."
  echo
}

# If convert-only: run converter then exit
if [ "$MODE" = "convert-only" ]; then
  run_converter
  cp -r "$TMP_DEST" "$DEST" && mv "$DEST/$(basename $TMP_DEST)" "$DEST/$(basename $SRC)"
  echo "convert-only mode: done. Files copied to destination: $DEST/$(basename $SRC)"
  exit 0
fi

# If not convert-only and mode is not import-only, we want to convert by default (for full, order-only, tag-only)
if [ "$MODE" == "full" ]; then
  run_converter
else
  echo "Skipping converter; using existing files at source."
  # In import-only mode, we'll set IMPORT_SRC to the provided source (not the tempdir)
  rm -rf "$TMP_DEST"
  TMP_DEST=""
fi

# Step 2: run beets import service (single service)
COMPOSE_FILE="$SCRIPT_DIR/docker/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: docker compose file not found at $COMPOSE_FILE" >&2
  exit 7
fi

# Compose environment mapping for import mode:
# full -> default import (move + autotag)
# order-only -> move but no autotag/no tag writes
# tag-only -> autotag/write tags but do not move (no copy)
if [ "$MODE" = "order-only" ]; then
  IMPORT_MODE="order-only"
elif [ "$MODE" = "tag-only" ]; then
  IMPORT_MODE="tag-only"
else
  # full or import-only
  IMPORT_MODE="full"
fi

# Export env vars used by docker-compose
export DEST_PATH="$DEST"
# IMPORT_SRC = absolute path to the temporary converter output (or the original source for import-only)
if [ -n "$TMP_DEST" ]; then
  export IMPORT_SRC="$TMP_DEST"
else
  # import-only used original source
  export IMPORT_SRC="$SRC"
fi
export BEETS_CONFIG="$BEETS_CONFIG"

# Compose / container use DRY_RUN and IMPORT_MODE
export DRY_RUN="$DRY_RUN"
export IMPORT_MODE="$IMPORT_MODE"

echo "-> invoking docker compose (beets import)"
pushd "$SCRIPT_DIR/docker" >/dev/null

# Use --abort-on-container-exit so compose stops after the one-shot service finishes
if [ "$COMPOSE_CMD" = "docker compose" ]; then
  docker compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
else
  docker-compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
fi

popd >/dev/null

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Beets (docker compose) finished with non-zero exit code: $EXIT_CODE" >&2
  exit $EXIT_CODE
fi

echo "-> finished. All done."
exit 0
