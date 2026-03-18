#!/bin/sh
set -eu

# ============================================================================
# SFTP entrypoint - reads password secret and constructs user credentials
# ============================================================================

read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Read password from secret
SFTP_PASSWORD_VALUE="$(read_secret sftp_password)"
if [ -z "$SFTP_PASSWORD_VALUE" ]; then
  echo "ERROR: sftp_password secret not found or empty" >&2
  if [ -n "$SFTP_PASSWORD" ]; then
    echo "Fallback to SFTP_PASSWORD env var" >&2
    SFTP_PASSWORD_VALUE="$SFTP_PASSWORD"
  fi
fi

# Export for logging entrypoint usage
export SFTP_PASSWORD="$SFTP_PASSWORD_VALUE"

# Execute original atmoz/sftp entrypoint with user credentials
# Format: user:password:uid:gid
exec /entrypoint "${SFTP_USER}:${SFTP_PASSWORD_VALUE}:${PUID}:${PGID}" 2>&1 | tee /var/log/sftp/access.log
