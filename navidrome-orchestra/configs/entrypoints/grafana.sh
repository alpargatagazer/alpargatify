#!/bin/sh
set -eu

# ============================================================================
# Grafana entrypoint - reads secret and exports as environment variable
# ============================================================================

read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

PASSWORD_VALUE="$(read_secret grafana_admin_password)"
if [ -n "$PASSWORD_VALUE" ]; then
  export GF_SECURITY_ADMIN_PASSWORD="$PASSWORD_VALUE"
fi

# Execute the original Grafana entrypoint
exec /run.sh "$@"
