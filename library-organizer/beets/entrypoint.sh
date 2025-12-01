#!/usr/bin/env bash
#
# Beets Docker Entrypoint
# Executes beets import with configurable modes and retry logic
#

set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# Configuration
# ============================================================================

readonly CONFIG_PATH="/config.yaml"
readonly IMPORT_SRC_PATH="/import"
readonly TEMP_IMPORT_PATH="/tmp/beets_import_backup"
readonly MAX_RETRIES=5

# ============================================================================
# Functions
# ============================================================================

# Logs a message to stderr with timestamp
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Logs an error message and exits
error_exit() {
  log "ERROR: $1"
  exit "${2:-1}"
}

# Restores files from temporary backup to original location
restore_files() {
  if [[ "$IMPORT_MODE" != "tag-only" ]] || [[ ! -d "$TEMP_IMPORT_PATH" ]]; then
    return 0
  fi

  log "Restoring files from backup to original location..."
  
  if [[ -n "$(ls -A "$TEMP_IMPORT_PATH" 2>/dev/null)" ]]; then
    cp -rf "$TEMP_IMPORT_PATH"/* "$IMPORT_SRC_PATH"/ || {
      log "WARNING: Failed to restore some files"
      return 1
    }
    rm -rf "$TEMP_IMPORT_PATH"
    log "Files restored successfully"
  else
    log "No files to restore"
  fi
}

# Creates backup of files for tag-only mode
backup_files() {
  log "Tag-only mode: backing up files from $IMPORT_SRC_PATH..."
  
  mkdir -p "$TEMP_IMPORT_PATH"
  
  if [[ -n "$(ls -A "$IMPORT_SRC_PATH" 2>/dev/null)" ]]; then
    mv "$IMPORT_SRC_PATH"/* "$TEMP_IMPORT_PATH"/ || \
      error_exit "Failed to backup files" 3
    
    # Ensure files are restored even if script fails
    trap restore_files EXIT
    
    log "Files moved to $TEMP_IMPORT_PATH"
  else
    log "No files found in $IMPORT_SRC_PATH to backup"
  fi
}

# Builds the beets command array based on configuration
build_beets_command() {
  BEET_CMD=(beet -c "$CONFIG_PATH")
  
  # Add verbose flag if requested
  [[ "${VERBOSE:-no}" == "yes" ]] && BEET_CMD+=(-v)
  
  BEET_CMD+=(import)
  
  # Add dry-run flag if requested
  [[ "${DRY_RUN:-no}" == "yes" ]] && BEET_CMD+=(--pretend)
  
  # Configure mode-specific flags
  case "${IMPORT_MODE:-full}" in
    full)
      # Default behavior: move files + autotag
      BEET_CMD+=("$IMPORT_SRC_PATH")
      ;;
      
    order-only)
      # Move files without autotagging or writing tags
      BEET_CMD+=(-A -W "$IMPORT_SRC_PATH")
      ;;
      
    tag-only)
      # Autotag/write tags without moving files
      backup_files
      BEET_CMD+=(-C --from-scratch "$TEMP_IMPORT_PATH")
      ;;
      
    *)
      error_exit "Unknown IMPORT_MODE: ${IMPORT_MODE:-unset}" 2
      ;;
  esac
}

# Executes beets command with retry logic
execute_with_retry() {
  local attempt=0
  local exit_code=1
  
  # Display command with proper spacing (temporarily change IFS)
  local OLD_IFS="$IFS"
  IFS=' '
  log "Running: ${BEET_CMD[*]}"
  IFS="$OLD_IFS"
  
  while (( attempt < MAX_RETRIES )); do
    set +e
    "${BEET_CMD[@]}"
    exit_code=$?
    set -e
    
    if (( exit_code == 0 )); then
      log "Beets completed successfully"
      return 0
    fi
    
    ((attempt++))
    
    if (( attempt < MAX_RETRIES )); then
      local wait_time=$((attempt * 5))
      log "Attempt $attempt/$MAX_RETRIES failed — retrying in ${wait_time}s..."
      sleep "$wait_time"
    fi
  done
  
  log "Beets failed after $MAX_RETRIES attempts with exit code $exit_code"
  return "$exit_code"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  # Validate required paths exist
  [[ -f "$CONFIG_PATH" ]] || error_exit "Config file not found: $CONFIG_PATH"
  [[ -d "$IMPORT_SRC_PATH" ]] || error_exit "Import directory not found: $IMPORT_SRC_PATH"
  
  # Build command (BEET_CMD is now a global array)
  build_beets_command
  
  # Execute with retry logic
  execute_with_retry
  local final_exit=$?
  
  exit "$final_exit"
}

main "$@"