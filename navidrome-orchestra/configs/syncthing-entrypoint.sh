#!/bin/sh
set -eu

: "${GUI_USER:=}"
: "${GUI_PASSWORD:=}"
: "${FOLDER_ID:=}"
: "${FOLDER_LABEL:=Navidrome Library}"
: "${CONFIG_HOME:=/var/syncthing/config}"
: "${MUSIC_PATH:=/var/syncthing/music}"

mkdir -p "$CONFIG_HOME"
# optional: try to set ownership if running as root with PUID/PGID env handling done elsewhere
# chown -R "${PUID:-0}:${PGID:-0}" "$CONFIG_HOME" || true

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

# 5) Exec Syncthing in foreground (use --home explicitly; avoid background dance)
echo "Starting syncthing (foreground) with --home ${CONFIG_HOME} ..."
exec syncthing --home "$CONFIG_HOME"
