#!/bin/sh
set -eu

# ============================================================================
# Syncthing entrypoint with Docker secrets support
# - Reads GUI_PASSWORD from secret if available
# - Original functionality from syncthing-entrypoint.sh preserved
# ============================================================================

# Read secret from file
read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Try to read password from secret first, fallback to env var
SECRET_PASSWORD="$(read_secret syncthing_gui_password)"
if [ -n "$SECRET_PASSWORD" ]; then
  GUI_PASSWORD="$SECRET_PASSWORD"
fi

# Environment variables with defaults
: "${GUI_USER:=}"
: "${GUI_PASSWORD:=}"
: "${CONFIG_HOME:=/var/syncthing/config}"
: "${MUSIC_FOLDER_LABEL:=Navidrome Library}"
: "${MUSIC_PATH:=/srv/music}"
: "${BACKUPS_FOLDER_LABEL:=Navidrome Backups}"
: "${BACKUPS_PATH:=/srv/backups}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Configure .stignore for a given path
setup_stignore() {
  local path="$1"
  local stignore_file="${path}/.stignore"
  local pattern='(?d).DS_Store'

  if [ -f "$stignore_file" ]; then
    if ! grep -Fqx "$pattern" "$stignore_file"; then
      echo "$pattern" >> "$stignore_file"
      chown "${PUID:-0}:${PGID:-0}" "$stignore_file" 2>/dev/null || true
      log "Appended .DS_Store ignore pattern to $stignore_file"
    fi
  else
    printf "%s\n" "$pattern" > "$stignore_file"
    chown "${PUID:-0}:${PGID:-0}" "$stignore_file" 2>/dev/null || true
    log "Created $stignore_file with .DS_Store ignore pattern"
  fi
}

# Add folder to Syncthing config if not present
add_folder() {
  local id="$1"
  local label="$2"
  local path="$3"
  local config_xml="$CONFIG_HOME/config.xml"

  # Check if folder already exists by path or label
  if grep -qE "<folder[^>]+path=[\"']${path}[\"']" "$config_xml" || \
     grep -qE "<folder[^>]+label=[\"']${label}[\"']" "$config_xml"; then
    log "Folder '$label' already present in config — skipping"
    return
  fi

  log "Adding folder '$label' (id=$id, path=$path)"

  local block
  read -r -d '' block <<EOF || true
    <folder id="${id}" label="${label}" path="${path}" type="sendreceive"
            rescanIntervalS="3600" fsWatcherEnabled="true"
            ignorePerms="false" autoNormalize="true">
      <filesystemType>basic</filesystemType>
      <versioning type="trashcan">
        <param key="cleanoutDays" val="3"></param>
        <cleanupIntervalS>3600</cleanupIntervalS>
        <fsPath></fsPath>
        <fsType>basic</fsType>
      </versioning>
    </folder>
EOF

  local tmp
  tmp="$(mktemp)"
  awk -v block="$block" '{
    if ($0 ~ /<\/configuration>/ && !inserted) {
      print block
      inserted=1
    }
    print
  }' "$config_xml" > "$tmp" && mv "$tmp" "$config_xml"

  log "Inserted folder '$label' into config"
}

# Ensure versioning is present for a given path
ensure_versioning() {
  local path="$1"
  local config_xml="$CONFIG_HOME/config.xml"

  # Check if the folder at this path already has versioning
  if sed -n "/path=\"$path\"/,/<\/folder>/p" "$config_xml" | grep -q "<versioning"; then
    log "Versioning already present for folder at '$path' — skipping"
    return
  fi

  log "Adding versioning to existing folder at '$path'"

  local versioning_block
  read -r -d '' versioning_block <<EOF || true
      <versioning type="trashcan">
        <param key="cleanoutDays" val="7"></param>
        <cleanupIntervalS>3600</cleanupIntervalS>
        <fsPath></fsPath>
        <fsType>basic</fsType>
      </versioning>
EOF

  local tmp
  tmp="$(mktemp)"
  # Insert the versioning block before </folder> for the section matching the path
  awk -v path="$path" -v block="$versioning_block" '
    BEGIN { inside=0; found=0 }
    $0 ~ "path=\"" path "\"" { inside=1 }
    inside && /<\/folder>/ && !found {
      print block
      found=1
      inside=0
    }
    /<\/folder>/ { inside=0 }
    { print }
  ' "$config_xml" > "$tmp" && mv "$tmp" "$config_xml"
}

# ============================================================================
# 1) INITIALIZE SYNCTHING CONFIGURATION
# ============================================================================

log "Initializing Syncthing configuration..."

mkdir -p "$CONFIG_HOME"
chown -R "${PUID:-0}:${PGID:-0}" "$CONFIG_HOME" 2>/dev/null || true

# Generate base config if missing
if [ ! -f "$CONFIG_HOME/config.xml" ]; then
  log "No config.xml found — generating base config..."
  if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
    syncthing generate --home "$CONFIG_HOME" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD"
  else
    syncthing generate --home "$CONFIG_HOME"
  fi
  log "Generated config.xml"
fi

# ============================================================================
# 2) SETUP FOLDERS
# ============================================================================

log "Setting up sync folders..."

# Ensure paths exist
mkdir -p "$MUSIC_PATH" "$BACKUPS_PATH"

# Setup .stignore for both folders
setup_stignore "$MUSIC_PATH"
setup_stignore "$BACKUPS_PATH"

# Generate unique folder IDs
MUSIC_FOLDER_ID=$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')
BACKUPS_FOLDER_ID=$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')

# Add folders to config
add_folder "$MUSIC_FOLDER_ID" "$MUSIC_FOLDER_LABEL" "$MUSIC_PATH"
add_folder "$BACKUPS_FOLDER_ID" "$BACKUPS_FOLDER_LABEL" "$BACKUPS_PATH"

# Ensure versioning is enabled for existing folders
ensure_versioning "$MUSIC_PATH"
ensure_versioning "$BACKUPS_PATH"

# ============================================================================
# 3) UPDATE GUI CREDENTIALS
# ============================================================================

if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
  log "Updating GUI credentials..."

  tmp_home="$(mktemp -d)"
  trap 'rm -rf "$tmp_home"' EXIT INT TERM

  syncthing generate --home "$tmp_home" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD" 2>/dev/null

  tmp_config="$tmp_home/config.xml"
  if [ ! -f "$tmp_config" ]; then
    log "ERROR: temporary config generation failed" >&2
  else
    # Extract <gui>...</gui> block from temporary config
    tmp_gui_block="$(awk '/<gui/{flag=1} flag{print} /<\/gui>/{flag=0}' "$tmp_config" 2>/dev/null || true)"

    if [ -z "$tmp_gui_block" ]; then
      log "WARNING: couldn't extract GUI block from generated config" >&2
    else
      config_xml="$CONFIG_HOME/config.xml"
      tmp_file="$(mktemp)"
      
      if grep -q "<gui" "$config_xml"; then
        # Replace existing <gui> block
        awk -v newblock="$tmp_gui_block" '
          BEGIN {inside=0; replaced=0}
          /<gui/ && !replaced {inside=1; print newblock; replaced=1; next}
          /<\/gui>/ && inside {inside=0; next}
          { if (!inside) print }
        ' "$config_xml" > "$tmp_file" && mv "$tmp_file" "$config_xml"
        log "Updated GUI credentials in config"
      else
        # Insert new <gui> block
        awk -v newblock="$tmp_gui_block" '{
          if ($0 ~ /<\/configuration>/ && !inserted) {
            print newblock
            inserted=1
          }
          print
        }' "$config_xml" > "$tmp_file" && mv "$tmp_file" "$config_xml"
        log "Inserted GUI credentials into config"
      fi
    fi
  fi

  rm -rf "$tmp_home" 2>/dev/null || true
  trap - EXIT INT TERM
fi

# ============================================================================
# 4) START SYNCTHING
# ============================================================================

log "Starting Syncthing..."
exec syncthing --home "$CONFIG_HOME"
