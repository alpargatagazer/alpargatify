#!/usr/bin/env bash
# wrapper.sh
#
# Orchestrates FLAC to AAC conversion and beets music library import
# This wrapper script:
#   1. Runs flac-to-aac.sh converter into a temporary directory (preserving paths)
#   2. Runs a Docker Compose service (beets) to import from the temp directory
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
#   ./wrapper.sh [--dry-run] [--beets-config /abs/path/to/beets-config.yaml] \
#                [--convert-only|--import-only|--order-only|--tag-only] \
#                /path/to/source /absolute/path/to/music_library_root

set -euo pipefail  # Exit on error, undefined variables, or pipe failures
IFS=$'\n\t'        # Set Internal Field Separator to newline and tab

###############################################################################
# Logging helpers (matches style/colors from flac-to-aac.sh)
###############################################################################

# Initialize color codes for terminal output
# Sets RED, ORANGE, and RESET variables based on terminal capabilities
# Disables colors if stderr is not a TTY
_init_colors() {
  RED=""
  ORANGE=""
  RESET=""

  # Prefer tput when available for reliable reset code
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  # Detect 256-color capable terminals (TERM contains 256color)
  if [[ "${TERM:-}" == *256color* ]]; then
    # Orange-like (color 208) and standard red
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    # Fallback to tput setaf or basic ANSI codes
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      # If tput failed and returned empty, fall back to ANSI
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  # If stderr is not a terminal, disable colors to keep logs clean
  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

_init_colors

# Get current timestamp in YYYY-MM-DD HH:MM:SS format
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Log error message to stderr in red
# Args:
#   $* - Error message to log
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }

# Log warning message to stderr in orange
# Args:
#   $* - Warning message to log
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }

# Log info message to stdout
# Args:
#   $* - Info message to log
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }

# Log debug message to stdout if VERBOSE is enabled
# Args:
#   $* - Debug message to log
debug(){ if [ "${VERBOSE:-no}" = "yes" ]; then printf '%s DEBUG: %s\n' "$(time_stamp)" "$*"; fi }

###############################################################################
# Defaults and global variables
###############################################################################
# Determine script directory (for locating related files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default beets configuration file path
BEETS_CONFIG="$SCRIPT_DIR/beets/beets-config.yaml"

# Dry-run mode: show actions without executing them
DRY_RUN="no"

# Operation mode: full, convert-only, import-only, order-only, tag-only
MODE="full"

# Enable verbose debug output
VERBOSE="no"

###############################################################################
# Help and usage
###############################################################################

# Display usage information and exit
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--beets-config /path/to/beets-config.yaml] \
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

###############################################################################
# Argument parsing
###############################################################################

# Parse command-line arguments and set global variables
# Args:
#   $@ - All command-line arguments
# Sets:
#   SRC - Source directory path
#   DEST - Destination directory path (music library root)
#   BEETS_CONFIG - Path to beets configuration file
#   DRY_RUN - Whether to run in dry-run mode
#   MODE - Operation mode (full, convert-only, import-only, order-only, tag-only)
#   VERBOSE - Whether to enable verbose output
POSITIONAL=()
while (( "$#" )); do
  case "$1" in
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

# Restore positional arguments
set -- "${POSITIONAL[@]:-}"

# Validate that exactly 2 positional arguments were provided
if [ "${#}" -ne 2 ]; then
  err "source and destination required."
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

###############################################################################
# Validation and system checks
###############################################################################

# Validate source directory exists
if [ ! -d "$SRC" ]; then 
  err "source directory does not exist: $SRC"
  exit 3
fi

# Validate destination is an absolute path
if [[ "$DEST" != /* ]]; then 
  err "destination must be an absolute path (root of your music library)."
  exit 8
fi

# Create destination directory if it doesn't exist
mkdir -p "$DEST"

# Check converter script exists and is executable
CONVERTER="$SCRIPT_DIR/flac-to-aac.sh"
if [ ! -x "$CONVERTER" ]; then 
  err "converter script not found or not executable at: $CONVERTER"
  exit 4
fi

# Check Docker is installed
if ! command -v docker >/dev/null 2>&1; then 
  err "docker not found in PATH. Docker is required."
  exit 5
fi

# Detect Docker Compose (v2 plugin or standalone binary)
# Creates a wrapper function 'compose' for either variant
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose "$@"; }
else
  err "Neither 'docker compose' nor 'docker-compose' found. Install Docker Compose."
  exit 6
fi

# Validate or warn about beets config file
if [ -n "$BEETS_CONFIG" ] && [ -f "$BEETS_CONFIG" ]; then
  info "Using beets config: $BEETS_CONFIG"
else
  warn "beets_config not found at $BEETS_CONFIG. The beets container will run with its default config."
fi

###############################################################################
# Configuration summary
###############################################################################

# Display current settings for user confirmation
info "=== Settings ==="
info "Script dir:         $SCRIPT_DIR"
info "Source (input):     $SRC"
info "Music library root: $DEST"
info "Converter:          $CONVERTER"
info "Beets config:       $BEETS_CONFIG"
info "Dry run:            $DRY_RUN"
info "Mode:               $MODE"
info "================"
info ""

###############################################################################
# Temporary directory setup
###############################################################################

# Create temporary directory for converter output
# This preserves the source directory structure during conversion
TMP_DEST="$(mktemp -d 2>/dev/null || mktemp -d -t beets_import_XXXXXX 2>/dev/null || true)"
if [ -z "$TMP_DEST" ]; then 
  err "could not create temporary directory"
  exit 9
fi
info "Temporary converter destination: $TMP_DEST"

# Cleanup function to remove temporary directory
# In dry-run mode, leaves directory for inspection
cleanup() {
  if [ "$DRY_RUN" = "yes" ]; then
    info "Dry-run mode: leaving temporary directory for inspection: $TMP_DEST"
  else
    info "Cleaning up temporary directory: $TMP_DEST"
    rm -rf "$TMP_DEST" || true
  fi
}

# Register cleanup function to run on script exit
trap cleanup EXIT

###############################################################################
# Core functions
###############################################################################

# Run the FLAC to AAC converter
# Writes converted files into TMP_DEST, preserving source directory structure
# Uses flac-to-aac.sh script with appropriate flags
run_converter() {
  conv_args=()
  
  # Pass dry-run flag to converter if enabled
  [ "$DRY_RUN" = "yes" ] && conv_args+=(--dry-run)
  
  # Add source and temporary destination
  conv_args+=( "$SRC" "$TMP_DEST" )

  info "-> running converter (output -> temp dir)"
  debug "Running: $CONVERTER $(printf '%s ' "${conv_args[@]}" | sed -E 's/[[:space:]]+$//')"
  
  # Pass VERBOSE environment variable to converter
  VERBOSE=${VERBOSE} "$CONVERTER" "${conv_args[@]}"
  
  info "-> converter finished."
  info ""
}

###############################################################################
# Mode handling: convert-only
###############################################################################

# In convert-only mode: run converter, copy files to destination, then exit
if [ "$MODE" = "convert-only" ]; then
  run_converter
  
  # Copy converted tree into destination preserving relative paths using rsync
  info "Copying converted files into destination (preserving paths)"
  # The TMP_DEST will contain the same relative tree as SRC; we'll rsync into DEST
  
  if [ "$DRY_RUN" = "yes" ]; then
    info "DRY RUN: rsync -av --remove-source-files '$TMP_DEST/' '$DEST/'"
  else
    # Check if rsync is available, fall back to cp if not
    command -v rsync >/dev/null 2>&1 || { 
      warn "rsync not available; falling back to cp -a"
      cp -a "$TMP_DEST/." "$DEST/"
    }
    
    # Use rsync if available (preserves permissions and handles updates better)
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$TMP_DEST/" "$DEST/"
    fi
  fi
  
  info "convert-only mode: done. Files copied to destination."
  exit 0
fi

###############################################################################
# Mode handling: full vs import-only
###############################################################################

# In full mode: run converter first
# In import-only mode: skip converter and use source files directly
if [ "$MODE" = "full" ]; then
  run_converter
else
  info "Skipping converter; using existing files at source."
  # If skipping converter, we won't have TMP_DEST; remove it to avoid confusion
  rm -rf "$TMP_DEST" || true
  TMP_DEST=""
fi

###############################################################################
# Beets import preparation
###############################################################################

# Validate Docker Compose file exists
COMPOSE_FILE="$SCRIPT_DIR/beets/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then 
  err "docker compose file not found at $COMPOSE_FILE"
  exit 7
fi

# Determine import mode for beets based on selected mode
if [ "$MODE" = "order-only" ]; then
  IMPORT_MODE="order-only"
elif [ "$MODE" = "tag-only" ]; then
  IMPORT_MODE="tag-only"
else
  IMPORT_MODE="full"
fi

# Export environment variables for Docker Compose
# These are referenced in docker-compose.yml
export DEST_PATH="$DEST"                                          # Music library root
if [ -n "$TMP_DEST" ]; then 
  export IMPORT_SRC="$TMP_DEST"                                   # Import from temp dir (converted files)
else 
  export IMPORT_SRC="$SRC"                                        # Import from source (skip conversion)
fi
export BEETS_CONFIG="$BEETS_CONFIG"                               # Beets configuration file path
export DRY_RUN="$DRY_RUN"                                         # Pass dry-run mode to container
export IMPORT_MODE="$IMPORT_MODE"                                 # Beets import mode

###############################################################################
# Docker Compose execution
###############################################################################

# Run beets import via Docker Compose
info "-> invoking docker compose (beets import)"

# Change to beets directory (where docker-compose.yml is located)
pushd "$SCRIPT_DIR/beets" >/dev/null

# Create unique project name to allow parallel executions
export PROJECT_NAME=$(basename "$SRC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//')

# Run compose with unique project name
VERBOSE=${VERBOSE} compose -p "$PROJECT_NAME" -f docker-compose.yml up --build --abort-on-container-exit
EXIT_CODE=$?

# Cleanup Docker resources (containers, networks, volumes)
info "-> cleaning up docker resources"
compose -p "$PROJECT_NAME" -f docker-compose.yml down --volumes --remove-orphans 2>/dev/null || {
  warn "Docker cleanup encountered issues (this is usually safe to ignore)"
}

# Return to original directory
popd >/dev/null

# Check if beets import succeeded
if [ "$EXIT_CODE" -eq 2 ]; then
  warn "Beets import completed with some skippings."
elif [ "$EXIT_CODE" -ne 0 ]; then
  err "Beets (docker compose) finished with non-zero exit code: $EXIT_CODE"
  exit $EXIT_CODE
fi

###############################################################################
# Completion
###############################################################################

info "-> finished. All done."
exit 0