#!/bin/sh
set -eu

: "${GUI_USER:=}"
: "${GUI_PASSWORD:=}"
: "${FOLDER_ID:=}"
: "${FOLDER_LABEL:=Navidrome Library}"
: "${CONFIG_HOME:=/var/syncthing/config}"
: "${MUSIC_PATH:=/srv/music}"

mkdir -p "$CONFIG_HOME"
# optionally set perms here if needed:
chown -R "${PUID:-0}:${PGID:-0}" "$CONFIG_HOME" || true

# 1) generate base config if missing
if [ ! -f "$CONFIG_HOME/config.xml" ]; then
  echo "No config.xml found — generating base config with syncthing generate..."
  # Pass username/password only if provided (don't accidentally pass empty args)
  if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
    syncthing generate --home "$CONFIG_HOME" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD"
  else
    syncthing generate --home "$CONFIG_HOME"
  fi
  echo "Generated config.xml."
fi

# 2) Ensure music path exists (so Syncthing won't fail to use it)
mkdir -p "$MUSIC_PATH"

# 2a) Ensure the synced folder ignores macOS .DS_Store files.
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

# 3) Decide on folder id (generate if empty)
if [ -z "$FOLDER_ID" ]; then
  # 40 hex-ish chars; unique enough for folder id
  FOLDER_ID=$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

# 4) Check whether config.xml already contains that path or label (idempotent)
CONFIG_XML="$CONFIG_HOME/config.xml"
if grep -qE "<folder[^>]+path=[\"']${MUSIC_PATH}[\"']" "$CONFIG_XML" || \
   grep -qE "<folder[^>]+label=[\"']${FOLDER_LABEL}[\"']" "$CONFIG_XML"; then
  echo "Folder already present in config.xml (by path or label) — skipping injection."
else
  echo "Adding folder entry to config.xml (id=$FOLDER_ID, path=$MUSIC_PATH, label=$FOLDER_LABEL)."

  # Build minimal folder XML block (Syncthing will add local device id automatically)
  read -r -d '' FOLDER_BLOCK <<EOF || true
    <folder id="${FOLDER_ID}" label="${FOLDER_LABEL}" path="${MUSIC_PATH}" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" ignorePerms="false" autoNormalize="true">
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
  echo "Injected folder block into config.xml."
fi

# 4b) Update GUI user/password if both GUI_USER and GUI_PASSWORD are provided.
# We generate a temp config (using syncthing itself) to obtain the correctly hashed password,
# then replace the <gui>...</gui> block in the real config.xml. This preserves the rest.
if [ -n "$GUI_USER" ] && [ -n "$GUI_PASSWORD" ]; then
  echo "Ensuring GUI user/password in config.xml match env vars..."
  # extract current GUI user (if any) so we can skip work if unchanged
  CURRENT_GUI_USER=$(sed -n 's:.*<user>\(.*\)</user>.*:\1:p' "$CONFIG_XML" || true)

  # If username equals desired and there is a password tag, we still update because password changed.
  # We'll always create a temp config and copy the <gui> block to ensure password hash matches.
  TMP_HOME="$(mktemp -d)"
  trap 'rm -rf "$TMP_HOME"' EXIT INT TERM

  echo "Generating a temporary config to produce hashed password..."
  syncthing generate --home "$TMP_HOME" --gui-user="$GUI_USER" --gui-password="$GUI_PASSWORD"

  TMP_CONFIG="$TMP_HOME/config.xml"
  if [ ! -f "$TMP_CONFIG" ]; then
    echo "Error: temporary config generation failed." >&2
  else
    # extract <gui>...</gui> block from temporary config
    # This sed approach takes everything from <gui ...> to </gui> (inclusive)
    TMP_GUI_BLOCK="$(awk '/<gui/{flag=1} flag{print} /<\/gui>/{flag=0}' "$TMP_CONFIG" || true)"

    if [ -z "$TMP_GUI_BLOCK" ]; then
      echo "Warning: couldn't extract <gui> block from generated config; skipping GUI update." >&2
    else
      # If real config contains a <gui> block, replace it. Otherwise insert before </configuration>
      if grep -q "<gui" "$CONFIG_XML"; then
        # Use awk to replace the first <gui>...</gui> block with the new one.
        TMP="$(mktemp)"
        awk -v newblock="$TMP_GUI_BLOCK" '
          BEGIN {inside=0; replaced=0}
          /<gui/ && !replaced {inside=1; print newblock; replaced=1; next}
          /<\/gui>/ && inside {inside=0; next}
          { if (!inside) print }
        ' "$CONFIG_XML" > "$TMP" && mv "$TMP" "$CONFIG_XML"
        echo "Replaced existing <gui> block in config.xml with new credentials."
      else
        # Insert the new <gui> block before </configuration>
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

  # cleanup temp dir (trap will also clean)
  rm -rf "$TMP_HOME" || true
  trap - EXIT INT TERM
fi

# 5) Exec Syncthing in foreground (use --home explicitly)
echo "Starting syncthing (foreground) with --home ${CONFIG_HOME} ..."
exec syncthing --home "$CONFIG_HOME"
