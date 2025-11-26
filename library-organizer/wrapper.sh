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
#   --verbose              : add debug logging
#
# Usage:
#   ./wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] \
#                [--convert-only|--import-only|--order-only|--tag-only] \
#                /path/to/source /absolute/path/to/music_library_root

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Logging helpers (same style/colors as flac-to-aac.sh)
###############################################################################
_init_colors() {
  RED=""
  ORANGE=""
  RESET=""

  # Prefer tput when available for reset
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  # Detect 256-color capable terminals (TERM contains 256color)
  if [[ "${TERM:-}" == *256color* ]]; then
    # Orange-like (color 208)
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    # Fallback to tput setaf or basic ANSI
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      # If tput failed return empty, fall back to ANSI
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  # If stderr not a terminal, disable colors to keep logs clean
  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

_init_colors
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }
debug(){ if [ "${VERBOSE:-no}" = "yes" ]; then printf '%s DEBUG: %s\n' "$(time_stamp)" "$*"; fi }

###############################################################################
# Defaults and usage
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEETS_CONFIG="$SCRIPT_DIR/beets/beets_config.yaml"
FORCE="no"
DRY_RUN="no"
MODE="full" # values: full, convert-only, import-only, order-only, tag-only
VERBOSE="no"

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
 - --verbose              : add debug logging

Notes:
 - Destination must be an absolute path (root of your music library).
EOF
}

# parse args
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
    --verbose) VERBOSE="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) err "Unknown option: $1"; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  err "source and destination required."
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

if [ ! -d "$SRC" ]; then err "source directory does not exist: $SRC"; exit 3; fi
if [[ "$DEST" != /* ]]; then err "destination must be an absolute path (root of your music library)."; exit 8; fi
mkdir -p "$DEST"

CONVERTER="$SCRIPT_DIR/flac-to-aac.sh"
if [ ! -x "$CONVERTER" ]; then err "converter script not found or not executable at: $CONVERTER"; exit 4; fi

if ! command -v docker >/dev/null 2>&1; then err "docker not found in PATH. Docker is required."; exit 5; fi

# Compose detection
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose "$@"; }
else
  err "Neither 'docker compose' nor 'docker-compose' found. Install Docker Compose."
  exit 6
fi

if [ -n "$BEETS_CONFIG" ] && [ -f "$BEETS_CONFIG" ]; then
  info "Using beets config: $BEETS_CONFIG"
else
  warn "beets_config not found at $BEETS_CONFIG. The beets container will run with its default config."
fi

info "=== Settings ==="
info "Script dir:         $SCRIPT_DIR"
info "Source (input):     $SRC"
info "Music library root: $DEST"
info "Converter:          $CONVERTER"
info "Beets config:       $BEETS_CONFIG"
info "Force:              $FORCE"
info "Dry run:            $DRY_RUN"
info "Mode:               $MODE"
info "================"
info ""

# Create temporary directory for converter output
TMP_DEST="$(mktemp -d 2>/dev/null || mktemp -d -t beets_import_XXXXXX 2>/dev/null || true)"
if [ -z "$TMP_DEST" ]; then err "could not create temporary directory"; exit 9; fi
info "Temporary converter destination: $TMP_DEST"

cleanup() {
  if [ "$DRY_RUN" = "yes" ]; then
    info "Dry-run mode: leaving temporary directory for inspection: $TMP_DEST"
  else
    info "Cleaning up temporary directory: $TMP_DEST"
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

  info "-> running converter (output -> temp dir)"
  debug "Running: $CONVERTER $(printf '%s ' "${conv_args[@]}" | sed -E 's/[[:space:]]+$//')"
  VERBOSE=${VERBOSE} "$CONVERTER" "${conv_args[@]}"
  info "-> converter finished."
  info ""
}

# MODE handling
if [ "$MODE" = "convert-only" ]; then
  run_converter
  # copy converted tree into destination preserving relative paths using rsync
  info "Copying converted files into destination (preserving paths)"
  # The TMP_DEST will contain the same relative tree as SRC; we'll rsync into DEST
  if [ "$DRY_RUN" = "yes" ]; then
    info "DRY RUN: rsync -av --remove-source-files '$TMP_DEST/' '$DEST/'"
  else
    command -v rsync >/dev/null 2>&1 || { warn "rsync not available; falling back to cp -a"; cp -a "$TMP_DEST/." "$DEST/"; }
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$TMP_DEST/" "$DEST/"
    fi
  fi
  info "convert-only mode: done. Files copied to destination."
  exit 0
fi

if [ "$MODE" = "full" ]; then
  run_converter
else
  info "Skipping converter; using existing files at source."
  # If skipping converter, we won't have TMP_DEST; remove it to avoid confusion
  rm -rf "$TMP_DEST" || true
  TMP_DEST=""
fi

# Prepare compose run
COMPOSE_FILE="$SCRIPT_DIR/beets/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then err "docker compose file not found at $COMPOSE_FILE"; exit 7; fi

if [ "$MODE" = "order-only" ]; then
  IMPORT_MODE="order-only"
elif [ "$MODE" = "tag-only" ]; then
  IMPORT_MODE="tag-only"
else
  IMPORT_MODE="full"
fi

export DEST_PATH="$DEST"
if [ -n "$TMP_DEST" ]; then export IMPORT_SRC="$TMP_DEST"; else export IMPORT_SRC="$SRC"; fi
export BEETS_CONFIG="$BEETS_CONFIG"
export DRY_RUN="$DRY_RUN"
export IMPORT_MODE="$IMPORT_MODE"

info "-> invoking docker compose (beets import)"
pushd "$SCRIPT_DIR/beets" >/dev/null

# Use --abort-on-container-exit so compose stops after the one-shot service finishes
compose -f docker-compose.yml up --build --abort-on-container-exit
EXIT_CODE=$?

popd >/dev/null

if [ "$EXIT_CODE" -ne 0 ]; then
  err "Beets (docker compose) finished with non-zero exit code: $EXIT_CODE"
  exit $EXIT_CODE
fi

info "-> finished. All done."
exit 0
