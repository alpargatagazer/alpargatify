#!/bin/sh
set -eu

# ============================================================================
# WUD entrypoint - reads password hash from secret
# ============================================================================

read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Read password hash from secret
HASH_VALUE="$(read_secret wud_admin_password_hash)"
if [ -n "$HASH_VALUE" ]; then
  export WUD_AUTH_BASIC_ADMIN_HASH="$HASH_VALUE"
fi

# Execute the original WUD entrypoint
exec node index.js "$@"
