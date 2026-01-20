#!/bin/sh
set -eu

# ============================================================================
# Caddy entrypoint - reads password hash from secret for basicauth
# ============================================================================

read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Read password hash from secret
HASH_VALUE="$(read_secret caddy_auth_password_hash)"
if [ -n "$HASH_VALUE" ]; then
  export CADDY_AUTH_PASSWORD_HASH="$HASH_VALUE"
fi

# Execute the original Caddy command
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile "$@"
