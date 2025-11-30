#!/bin/sh
set -eu

# Environment variables with defaults
: "${GUI_USER:=}"
: "${GUI_PASSWORD:=}"
: "${CONFIG_HOME:=/var/syncthing/config}"
: "${MUSIC_FOLDER_LABEL:=Navidrome Library}"
: "${MUSIC_PATH:=/srv/music}"
: "${BACKUPS_FOLDER_LABEL:=Navidrome Backups}"
: "${BACKUPS_PATH:=/srv/backups}"

# ============================================================================
# 1) INITIALIZE SYNCTHING CONFIGURATION
# ============================================================================

mkdir -p "$CONFIG_HOME"
chown -R "${PUID:-0}:${PGID:-0}" "$CONFIG_HOME" || true

# Generate base config if missing
if [ ! -f "$CONFIG_HOME/config.xml" ]; then
  echo "No config.xml found — generating base config with syncthing generate..."
  if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
    syncthing generate --home "$CONFIG_HOME" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD"
  else
    syncthing generate --home "$CONFIG_HOME"
  fi
  echo "Generated config.xml."
fi

# ============================================================================
# 2) SETUP MUSIC FOLDER
# ============================================================================

# Ensure music path exists
mkdir -p "$MUSIC_PATH"

# Configure .stignore for music folder to ignore macOS .DS_Store files
# Use the (?d) prefix so these OS-generated files are allowed to be removed
# Use the (?d) prefix so these OS-generated files are allowed to be removed
# if they block directory deletion (per Syncthing docs).
STIGNORE_FILE="${MUSIC_PATH}/.stignore"
STIGNORE_PATTERN='(?d).DS_Store'

# Create .stignore if missing, or append the pattern if not present.
# Use fixed-string grep (-F) to avoid regex interpretation of the pattern.
if [ -f "$STIGNORE_FILE" ]; then
  if ! grep -Fqx "$STIGNORE_PATTERN" "$STIGNORE_FILE"; then
    echo "$STIGNORE_PATTERN" >> "$STIGNORE_FILE"
    # ensure file is owned by the container user so Syncthing can read it
    chown "${PUID:-0}:${PGID:-0}" "$STIGNORE_FILE" || true
    echo "Appended .DS_Store ignore pattern to $STIGNORE_FILE"
  else
    echo ".stignore already contains .DS_Store ignore pattern — skipping."
  fi
else
  printf "%s\n" "$STIGNORE_PATTERN" > "$STIGNORE_FILE"
  chown "${PUID:-0}:${PGID:-0}" "$STIGNORE_FILE" || true
  echo "Created $STIGNORE_FILE with .DS_Store ignore pattern."
fi

# 2b) Ensure backups path exists
mkdir -p "$BACKUPS_PATH"

# 2c) Ensure the backups folder also ignores macOS .DS_Store files
BACKUPS_STIGNORE_FILE="${BACKUPS_PATH}/.stignore"
if [ -f "$BACKUPS_STIGNORE_FILE" ]; then
  if ! grep -Fqx "$STIGNORE_PATTERN" "$BACKUPS_STIGNORE_FILE"; then
    echo "$STIGNORE_PATTERN" >> "$BACKUPS_STIGNORE_FILE"
    chown "${PUID:-0}:${PGID:-0}" "$BACKUPS_STIGNORE_FILE" || true
    echo "Appended .DS_Store ignore pattern to $BACKUPS_STIGNORE_FILE"
  else
    echo "Backups .stignore already contains .DS_Store ignore pattern — skipping."
  fi
else
  printf "%s\n" "$STIGNORE_PATTERN" > "$BACKUPS_STIGNORE_FILE"
  chown "${PUID:-0}:${PGID:-0}" "$BACKUPS_STIGNORE_FILE" || true
  echo "Created $BACKUPS_STIGNORE_FILE with .DS_Store ignore pattern."
fi

# 3a) enerate folder ID for music (always unique)
MUSIC_FOLDER_LABEL=$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')

# 3b) Generate folder ID for backups (always unique)
BACKUPS_FOLDER_ID=$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')

CONFIG_XML="$CONFIG_HOME/config.xml"

# 4) Check whether config.xml already contains the music folder (idempotent)
if grep -qE "<folder[^>]+path=[\"']${MUSIC_PATH}[\"']" "$CONFIG_XML" || \
   grep -qE "<folder[^>]+label=[\"']${FOLDER_LABEL}[\"']" "$CONFIG_XML"; then
  echo "Music folder already present in config.xml (by path or label) — skipping injection."
else
  echo "Adding music folder entry to config.xml (id=$MUSIC_FOLDER_LABEL, path=$MUSIC_PATH, label=$FOLDER_LABEL)."

  # Build minimal folder XML block (Syncthing will add local device id automatically)
  read -r -d '' FOLDER_BLOCK <<EOF || true
    <folder id="${MUSIC_FOLDER_LABEL}" label="${FOLDER_LABEL}" path="${MUSIC_PATH}" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" ignorePerms="false" autoNormalize="true">
      <filesystemType>basic</filesystemType>
    </folder>
EOF

  # Insert the folder block before the closing </configuration> tag.
  # Use a safe temp file and atomic move.
  TMP="$(mktemp)"
  awk -v block="$FOLDER_BLOCK" '{
    if ($0 ~ /<\/configuration>/ && !inserted) {
      print block
      inserted=1
    }
    print
  }' "$CONFIG_XML" > "$TMP" && mv "$TMP" "$CONFIG_XML"
  echo "Injected music folder block into config.xml."
fi

# 4b) Check whether config.xml already contains the backups folder (idempotent)
if grep -qE "<folder[^>]+path=[\"']${BACKUPS_PATH}[\"']" "$CONFIG_XML" || \
   grep -qE "<folder[^>]+label=[\"']Navidrome Backups[\"']" "$CONFIG_XML"; then
  echo "Backups folder already present in config.xml (by path or label) — skipping injection."
else
  echo "Adding backups folder entry to config.xml (id=$BACKUPS_FOLDER_ID, path=$BACKUPS_PATH, label=Navidrome Backups)."

  # Build minimal folder XML block for backups
  read -r -d '' BACKUPS_FOLDER_BLOCK <<EOF || true
    <folder id="${BACKUPS_FOLDER_ID}" label="Navidrome Backups" path="${BACKUPS_PATH}" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" ignorePerms="false" autoNormalize="true">
      <filesystemType>basic</filesystemType>
    </folder>
EOF

  # Insert the folder block before the closing </configuration> tag.
  TMP="$(mktemp)"
  awk -v block="$BACKUPS_FOLDER_BLOCK" '{
    if ($0 ~ /<\/configuration>/ && !inserted) {
      print block
      inserted=1
    }
    print
  }' "$CONFIG_XML" > "$TMP" && mv "$TMP" "$CONFIG_XML"
  echo "Injected backups folder block into config.xml."
fi

# 4c) Update GUI user/password if both GUI_USER and GUI_PASSWORD are provided.
# We generate a temp config (using syncthing itself) to obtain the correctly hashed password,
# then replace the <gui>...</gui> block in the real config.xml. This preserves the rest.
# Update GUI user/password if both are provided
# Generate a temp config to obtain the correctly hashed password,
# then replace the <gui>...</gui> block in the real config.xml
if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
  echo "Ensuring GUI user/password in config.xml match env vars..."

  TMP_HOME="$(mktemp -d)"
  trap 'rm -rf "$TMP_HOME"' EXIT INT TERM

  echo "Generating a temporary config to produce hashed password..."
  syncthing generate --home "$TMP_HOME" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD"

  TMP_CONFIG="$TMP_HOME/config.xml"
  if [ ! -f "$TMP_CONFIG" ]; then
    echo "Error: temporary config generation failed." >&2
  else
    # Extract <gui>...</gui> block from temporary config
    TMP_GUI_BLOCK="$(awk '/<gui/{flag=1} flag{print} /<\/gui>/{flag=0}' "$TMP_CONFIG" || true)"

    if [ -z "$TMP_GUI_BLOCK" ]; then
      echo "Warning: couldn't extract <gui> block from generated config; skipping GUI update." >&2
    else
      # Replace or insert the <gui> block in the real config
      if grep -q "<gui" "$CONFIG_XML"; then
        # Replace existing <gui> block
        TMP="$(mktemp)"
        awk -v newblock="$TMP_GUI_BLOCK" '
          BEGIN {inside=0; replaced=0}
          /<gui/ && !replaced {inside=1; print newblock; replaced=1; next}
          /<\/gui>/ && inside {inside=0; next}
          { if (!inside) print }
        ' "$CONFIG_XML" > "$TMP" && mv "$TMP" "$CONFIG_XML"
        echo "Replaced existing <gui> block in config.xml with new credentials."
      else
        # Insert new <gui> block before </configuration>
        TMP="$(mktemp)"
        awk -v newblock="$TMP_GUI_BLOCK" '{
          if ($0 ~ /<\/configuration>/ && !inserted) {
            print newblock
            inserted=1
          }
          print
        }' "$CONFIG_XML" > "$TMP" && mv "$TMP" "$CONFIG_XML"
        echo "Inserted <gui> block into config.xml with new credentials."
      fi
    fi
  fi

  # Cleanup temp directory
  rm -rf "$TMP_HOME" || true
  trap - EXIT INT TERM
fi

# ============================================================================
# 7) START SYNCTHING
# ============================================================================

echo "Starting syncthing (foreground) with --home ${CONFIG_HOME} ..."
exec syncthing --home "$CONFIG_HOME"