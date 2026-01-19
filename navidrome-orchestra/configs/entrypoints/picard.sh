#!/bin/sh
set -eu

# ============================================================================
# Picard entrypoint - reads secret and exports as environment variable
# ============================================================================

read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

PASSWORD_VALUE="$(read_secret picard_admin_password)"
if [ -n "$PASSWORD_VALUE" ]; then
  export WEB_AUTHENTICATION_PASSWORD="$PASSWORD_VALUE"
fi

# Execute the original entrypoint from jlesage/musicbrainz-picard
exec /startapp.sh "$@"
