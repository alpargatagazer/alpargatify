#!/bin/sh
set -eu

# ============================================================================
# Navidrome entrypoint - reads secrets and exports as environment variables
# ============================================================================

# Read secret from file, stripping newlines
read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Export secrets as environment variables
LASTFM_SECRET_VALUE="$(read_secret lastfm_secret)"
if [ -n "$LASTFM_SECRET_VALUE" ]; then
  export ND_LASTFM_SECRET="$LASTFM_SECRET_VALUE"
fi

ENCRYPTION_KEY_VALUE="$(read_secret navidrome_encryption_key)"
if [ -n "$ENCRYPTION_KEY_VALUE" ]; then
  export ND_PASSWORDENCRYPTIONKEY="$ENCRYPTION_KEY_VALUE"
fi

# Execute the original Navidrome binary
exec /app/navidrome "$@"
