#!/usr/bin/env bash
# parallel-wrapper.sh
#
# Executes wrapper.sh in parallel for each immediate subdirectory of a given directory
#
# Usage:
#   ./parallel-wrapper.sh [OPTIONS] /path/to/parent/directory /absolute/path/to/music_library_root
#
# Options:
#   --max-jobs N          : Maximum number of parallel jobs (default: number of CPU cores)
#   --dry-run             : Pass dry-run flag to wrapper.sh
#   --beets-config PATH   : Pass beets config path to wrapper.sh
#   --convert-only        : Pass convert-only mode to wrapper.sh
#   --import-only         : Pass import-only mode to wrapper.sh
#   --order-only          : Pass order-only mode to wrapper.sh
#   --tag-only            : Pass tag-only mode to wrapper.sh
#   --verbose             : Enable verbose output
#   -h, --help            : Show this help message

set -eo pipefail
IFS=$'\n\t'

###############################################################################
# Logging helpers
###############################################################################

_init_colors() {
  RED=""
  GREEN=""
  ORANGE=""
  RESET=""

  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  if [[ "${TERM:-}" == *256color* ]]; then
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
  else
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      GREEN="$(tput setaf 2 2>/dev/null || true)"
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
      [ -z "$GREEN" ] && GREEN=$'\033[32m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
      GREEN=$'\033[32m'
    fi
  fi

  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    GREEN=""
    RESET=""
  fi
}

_init_colors

time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }
success() { printf '%s %sSUCCESS:%s %s\n' "$(time_stamp)" "$GREEN" "$RESET" "$*"; }

###############################################################################
# Defaults
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="$SCRIPT_DIR/wrapper.sh"

# Detect number of CPU cores
if command -v nproc >/dev/null 2>&1; then
  MAX_JOBS=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  MAX_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
  MAX_JOBS=4
fi

# Arguments to pass to wrapper.sh
WRAPPER_ARGS=()

###############################################################################
# Help
###############################################################################

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] /path/to/parent/directory /absolute/path/to/music_library_root

Executes wrapper.sh in parallel for each immediate subdirectory.

Options:
  --max-jobs N          : Maximum number of parallel jobs (default: $MAX_JOBS)
  --dry-run             : Pass dry-run flag to wrapper.sh
  --beets-config PATH   : Pass beets config path to wrapper.sh
  --convert-only        : Pass convert-only mode to wrapper.sh
  --import-only         : Pass import-only mode to wrapper.sh
  --order-only          : Pass order-only mode to wrapper.sh
  --tag-only            : Pass tag-only mode to wrapper.sh
  --verbose             : Enable verbose output
  -h, --help            : Show this help message

Examples:
  # Process all subdirectories with default settings
  $(basename "$0") /path/to/albums /music/library

  # Limit to 2 parallel jobs
  $(basename "$0") --max-jobs 2 /path/to/albums /music/library

  # Dry run with verbose output
  $(basename "$0") --dry-run --verbose /path/to/albums /music/library
EOF
}

###############################################################################
# Argument parsing
###############################################################################

POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --max-jobs)
      MAX_JOBS="$2"
      shift 2
      ;;
    --dry-run|--convert-only|--import-only|--order-only|--tag-only|--verbose)
      WRAPPER_ARGS+=("$1")
      shift
      ;;
    --beets-config)
      WRAPPER_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      err "Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  err "Parent directory and music library root required."
  usage
  exit 2
fi

PARENT_DIR="$1"
MUSIC_LIBRARY="$2"

###############################################################################
# Validation
###############################################################################

if [ ! -d "$PARENT_DIR" ]; then
  err "Parent directory does not exist: $PARENT_DIR"
  exit 3
fi

if [[ "$MUSIC_LIBRARY" != /* ]]; then
  err "Music library must be an absolute path."
  exit 8
fi

if [ ! -x "$WRAPPER_SCRIPT" ]; then
  err "Wrapper script not found or not executable: $WRAPPER_SCRIPT"
  exit 4
fi

# Validate max-jobs is a positive integer
if ! [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] || [ "$MAX_JOBS" -lt 1 ]; then
  err "Invalid --max-jobs value: $MAX_JOBS (must be a positive integer)"
  exit 5
fi

###############################################################################
# Find subdirectories
###############################################################################

info "=== Parallel Execution Setup ==="
info "Parent directory:   $PARENT_DIR"
info "Music library root: $MUSIC_LIBRARY"
info "Wrapper script:     $WRAPPER_SCRIPT"
info "Max parallel jobs:  $MAX_JOBS"
info "Wrapper arguments:  ${WRAPPER_ARGS[*]:-none}"
info "================================"
info ""

# Find all immediate subdirectories (not hidden)
# Use while loop instead of mapfile for compatibility with Bash 3.2 (macOS default)
SUBDIRS=()
while IFS= read -r dir; do
  SUBDIRS+=("$dir")
done < <(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)

if [ "${#SUBDIRS[@]}" -eq 0 ]; then
  warn "No subdirectories found in $PARENT_DIR"
  exit 0
fi

info "Found ${#SUBDIRS[@]} subdirectories to process"
info ""

###############################################################################
# Parallel execution tracking
###############################################################################

# Arrays to track job status
declare -a RUNNING_JOBS=()
declare -a FAILED_JOBS=()
declare -a COMPLETED_JOBS=()

# Create log directory for individual job logs
LOG_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t parallel_logs_XXXXXX)"
info "Job logs will be saved to: $LOG_DIR"
info ""

# Cleanup function
cleanup() {
  info ""
  info "=== Execution Summary ==="
  info "Total subdirectories: ${#SUBDIRS[@]}"
  info "Completed:            ${#COMPLETED_JOBS[@]}"
  info "Failed:               ${#FAILED_JOBS[@]}"
  
  if [ "${#FAILED_JOBS[@]}" -gt 0 ]; then
    warn "Failed jobs:"
    for job in "${FAILED_JOBS[@]}"; do
      warn "  - $job"
    done
  fi
  
  info "Job logs available at: $LOG_DIR"
  
  # Clean up Docker resources
  info "Cleaning docker resources..."
  docker system prune -f --volumes 2>/dev/null || warn "Docker cleanup had issues (safe to ignore)"
  
  info "========================="
  
  # Exit with error if any jobs failed
  if [ "${#FAILED_JOBS[@]}" -gt 0 ]; then
    exit 1
  fi
}

trap cleanup EXIT

###############################################################################
# Job execution function
###############################################################################

# Execute wrapper.sh for a single subdirectory
# Args:
#   $1 - Subdirectory path
run_job() {
  local subdir="$1"
  local subdir_name
  subdir_name="$(basename "$subdir")"
  local log_file="$LOG_DIR/${subdir_name}.log"
  
  info "[START] Processing: $subdir_name"
  
  # Run wrapper.sh and capture output to log file
  # Handle empty WRAPPER_ARGS array for Bash 3.2 compatibility
  if [ "${#WRAPPER_ARGS[@]}" -eq 0 ]; then
    if "$WRAPPER_SCRIPT" "$subdir" "$MUSIC_LIBRARY" >"$log_file" 2>&1; then
      success "[DONE] $subdir_name"
      echo "$subdir_name" >> "$LOG_DIR/.completed"
    else
      exit_code=$?
      err "[FAILED] $subdir_name (exit code: $exit_code, log: $log_file)"
      echo "$subdir_name" >> "$LOG_DIR/.failed"
      return $exit_code
    fi
  else
    if "$WRAPPER_SCRIPT" "${WRAPPER_ARGS[@]}" "$subdir" "$MUSIC_LIBRARY" >"$log_file" 2>&1; then
      success "[DONE] $subdir_name"
      echo "$subdir_name" >> "$LOG_DIR/.completed"
    else
      exit_code=$?
      err "[FAILED] $subdir_name (exit code: $exit_code, log: $log_file)"
      echo "$subdir_name" >> "$LOG_DIR/.failed"
      return $exit_code
    fi
  fi
}

###############################################################################
# Parallel execution with job limit
###############################################################################

# Process all subdirectories with controlled parallelism
for subdir in "${SUBDIRS[@]}"; do
  # Wait if we've reached max parallel jobs
  while [ "${#RUNNING_JOBS[@]}" -ge "$MAX_JOBS" ]; do
    # Check for completed jobs and remove them from running list
    new_running=()
    for pid in "${RUNNING_JOBS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        # Job still running
        new_running+=("$pid")
      fi
    done
    RUNNING_JOBS=("${new_running[@]}")
    
    # Brief sleep to avoid busy waiting
    sleep 0.5
  done
  
  # Start new job in background
  run_job "$subdir" &
  RUNNING_JOBS+=($!)
done

# Wait for all remaining jobs to complete
info ""
info "Waiting for remaining jobs to complete..."
wait

# Read completed and failed jobs from temporary files
if [ -f "$LOG_DIR/.completed" ]; then
  while IFS= read -r job; do
    COMPLETED_JOBS+=("$job")
  done < "$LOG_DIR/.completed"
fi

if [ -f "$LOG_DIR/.failed" ]; then
  while IFS= read -r job; do
    FAILED_JOBS+=("$job")
  done < "$LOG_DIR/.failed"
fi

info ""
info "All jobs finished!"