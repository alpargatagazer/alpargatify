#!/usr/bin/env bash
#
# Beets Docker Entrypoint
# Executes beets import folder by folder with configurable modes and retry logic
# Supports multi-disc albums by detecting disc folders and processing from parent
#

set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# Configuration
# ============================================================================

readonly CONFIG_PATH="/config.yaml"
readonly IMPORT_SRC_PATH="/import"
readonly TEMP_IMPORT_PATH="/tmp/beets_import_backup"
readonly MAX_RETRIES=10

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

# Detects if a directory is a disc folder (CD1, Disc 1, etc.)
is_disc_folder() {
  local folder_name="$1"
  
  # Common patterns for disc folders (case-insensitive)
  if [[ "$folder_name" =~ ^[Cc][Dd][[:space:]]*[0-9]+$ ]] || \
     [[ "$folder_name" =~ ^[Dd]is[ck][[:space:]]*[0-9]+$ ]] || \
     [[ "$folder_name" =~ ^[Dd]is[ck][[:space:]]+[0-9]+[[:space:]]*-.*$ ]]; then
    return 0
  fi
  return 1
}

# Checks if a folder contains multi-disc subfolders
has_disc_subfolders() {
  local folder_path="$1"
  local disc_count=0
  
  while IFS= read -r subfolder; do
    local subfolder_name
    subfolder_name="$(basename "$subfolder")"
    if is_disc_folder "$subfolder_name"; then
      ((disc_count++))
    fi
  done < <(find "$folder_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  
  # If we found at least 2 disc folders, it's a multi-disc album
  (( disc_count >= 2 ))
}

# Restores files from temporary backup to original location
restore_files() {
  local folder_path="$1"
  local folder_backup="${TEMP_IMPORT_PATH}/$(basename "$folder_path")"
  
  if [[ "$IMPORT_MODE" != "tag-only" ]] || [[ ! -d "$folder_backup" ]]; then
    return 0
  fi

  log "Restoring files from backup to $folder_path..."
  
  if [[ -n "$(ls -A "$folder_backup" 2>/dev/null)" ]]; then
    cp -rf "$folder_backup"/* "$folder_path"/ || {
      log "WARNING: Failed to restore some files. We ignore it..."
    }
    rm -rf "$folder_backup"
    log "Files restored successfully"
  else
    log "No files to restore"
  fi
}

# Creates backup of files for tag-only mode
backup_files() {
  local folder_path="$1"
  local folder_name
  folder_name="$(basename "$folder_path")"
  local folder_backup="${TEMP_IMPORT_PATH}/${folder_name}"
  
  log "Tag-only mode: backing up files from $folder_path..."
  
  mkdir -p "$folder_backup"
  
  # Backup all files recursively (important for multi-disc)
  if [[ -n "$(find "$folder_path" -type f 2>/dev/null)" ]]; then
    cp -rf "$folder_path"/* "$folder_backup"/ || \
      error_exit "Failed to backup files from $folder_path" 3
    
    # Remove the files from original location
    find "$folder_path" -mindepth 1 -delete || \
      error_exit "Failed to clear original folder" 3
    
    log "Files moved to $folder_backup"
    echo "$folder_backup"
  else
    log "No files found in $folder_path to backup"
    echo ""
  fi
}

# Builds the beets command array based on configuration
build_beets_command() {
  local target_path="$1"
  
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
      BEET_CMD+=("$target_path")
      ;;
      
    order-only)
      # Move files without autotagging or writing tags
      BEET_CMD+=(-A -W "$target_path")
      ;;
      
    tag-only)
      # Autotag/write tags without moving files
      local backup_path
      backup_path=$(backup_files "$target_path")
      if [[ -n "$backup_path" ]]; then
        BEET_CMD+=(-C --from-scratch "$backup_path")
      else
        return 1
      fi
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
  
  while [ "$attempt" -lt "$MAX_RETRIES" ]; do
    
    attempt=$((attempt+1))
    set +e
    "${BEET_CMD[@]}"
    exit_code=$?
    set -e
    
    if (( exit_code == 0 )); then
      log "Beets completed successfully"
      return 0
    fi
    
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      local wait_time=$((attempt * 5))
      log "Attempt $attempt/$MAX_RETRIES failed — retrying in ${wait_time}s..."
      sleep "$wait_time"
    fi
  done
  
  log "Beets failed after $MAX_RETRIES attempts with exit code $exit_code"
  return "$exit_code"
}

# Process a single folder
process_folder() {
  local folder_path="$1"
  local folder_name
  folder_name="$(basename "$folder_path")"
  
  log "=========================================="
  log "Processing folder: $folder_name"
  log "=========================================="
  
  # Build command for this specific folder
  if ! build_beets_command "$folder_path"; then
    log "Skipping folder (no files to process): $folder_name"
    return 0
  fi
  
  # Execute with retry logic
  local exit_code=0
  execute_with_retry || exit_code=$?
  
  # Restore files if in tag-only mode
  if [[ "$IMPORT_MODE" == "tag-only" ]]; then
    restore_files "$folder_path"
  fi
  
  if (( exit_code == 0 )); then
    log "✓ Folder processed successfully: $folder_name"
  else
    log "✗ Folder failed: $folder_name (exit code: $exit_code)"
  fi
  
  return "$exit_code"
}

# Get album folders to process (handles multi-disc detection)
get_album_folders() {
  local folders=()
  local processed_parents=()
  
  # First, check if IMPORT_SRC_PATH itself is an album (no subdirs or only disc subdirs)
  local has_subdirs
  has_subdirs=$(find "$IMPORT_SRC_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  
  if (( has_subdirs == 0 )); then
    # No subdirectories, so IMPORT_SRC_PATH itself is the album folder
    echo "$IMPORT_SRC_PATH"
    return 0
  fi
  
  # Check if IMPORT_SRC_PATH contains disc folders (it's a multi-disc album at root)
  if has_disc_subfolders "$IMPORT_SRC_PATH"; then
    log "Detected multi-disc album at root level"
    echo "$IMPORT_SRC_PATH"
    return 0
  fi
  
  # Find all leaf directories (folders without subdirectories)
  local all_leaves=()
  while IFS= read -r dir; do
    local subdir_count
    subdir_count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if (( subdir_count == 0 )); then
      all_leaves+=("$dir")
    fi
  done < <(find "$IMPORT_SRC_PATH" -mindepth 1 -type d | sort)
  
  # Process each leaf directory
  for leaf in "${all_leaves[@]}"; do
    local leaf_name
    leaf_name="$(basename "$leaf")"
    local parent_dir
    parent_dir="$(dirname "$leaf")"
    
    # Check if this leaf is a disc folder
    if is_disc_folder "$leaf_name"; then
      # Check if parent has already been processed
      local already_processed=0
      for processed in "${processed_parents[@]}"; do
        if [[ "$processed" == "$parent_dir" ]]; then
          already_processed=1
          break
        fi
      done
      
      if (( already_processed == 0 )); then
        # Verify parent actually has multiple disc folders
        if has_disc_subfolders "$parent_dir"; then
          log "Detected multi-disc album: $(basename "$parent_dir")"
          echo "$parent_dir"
          processed_parents+=("$parent_dir")
        else
          # Parent doesn't have multiple discs, process leaf normally
          echo "$leaf"
        fi
      fi
      # else: parent already added, skip this disc folder
    else
      # Not a disc folder, process it normally
      echo "$leaf"
    fi
  done
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  # Validate required paths exist
  [[ -f "$CONFIG_PATH" ]] || error_exit "Config file not found: $CONFIG_PATH"
  [[ -d "$IMPORT_SRC_PATH" ]] || error_exit "Import directory not found: $IMPORT_SRC_PATH"
  
  # Create temp directory for tag-only mode
  mkdir -p "$TEMP_IMPORT_PATH"
  
  # Get all album folders (with multi-disc detection)
  local folders
  mapfile -t folders < <(get_album_folders)
  
  if (( ${#folders[@]} == 0 )); then
    log "No folders found to process in $IMPORT_SRC_PATH"
    exit 0
  fi
  
  log "Found ${#folders[@]} album(s) to process"
  
  # Process each folder
  local failed_folders=()
  local successful_folders=()
  
  for folder in "${folders[@]}"; do
    if process_folder "$folder"; then
      successful_folders+=("$(basename "$folder")")
    else
      failed_folders+=("$(basename "$folder")")
    fi
  done
  
  # Summary
  log "=========================================="
  log "PROCESSING SUMMARY"
  log "=========================================="
  log "Total albums: ${#folders[@]}"
  log "Successful: ${#successful_folders[@]}"
  log "Failed: ${#failed_folders[@]}"
  
  if (( ${#failed_folders[@]} > 0 )); then
    log ""
    log "Failed albums:"
    for folder in "${failed_folders[@]}"; do
      log "  - $folder"
    done
    exit 1
  fi
  
  log ""
  log "All albums processed successfully!"
  exit 0
}

main "$@"