#!/usr/bin/env bash
# bootstrap.sh - prepare config, validate ownership, copy templates and launch docker-compose
# - creates config dir if missing
# - substitutes simple template variables in docker-compose files
# - exports PUID and PGID derived from NAVIDROME paths
# - copies navidrome.toml and background directory into config path
# - runs all docker-compose*.yml files found next to the script (combined)

set -euo pipefail

###############################################################################
# Helpers
###############################################################################
err() {
  echo "ERROR: $*" >&2
}

info() {
  echo "INFO: $*"
}

warn() {
  echo "WARN: $*" >&2
}

cleanup_tmpfiles() {
  if [[ "${TMP_FILES_CREATED:-}" == "1" ]]; then
    rm -f "${TMP_FILES[@]:-}" || true
  fi
}
trap cleanup_tmpfiles EXIT

###############################################################################
# Locate script dir and load .env
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found in script directory ($SCRIPT_DIR). Please create it before running."
  exit 2
fi

# Export variables from .env safely (ignores commented lines)
# Using set -a / source to allow variable expansion in dotenv values
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

###############################################################################
# Required variables (basic validation)
###############################################################################
: "${NAVIDROME_VERSION:?"NAVIDROME_VERSION is not set in .env"}"
: "${NAVIDROME_CONFIG_PATH:?"NAVIDROME_CONFIG_PATH is not set in .env"}"
: "${NAVIDROME_MUSIC_PATH:?"NAVIDROME_MUSIC_PATH is not set in .env"}"

###############################################################################
# Show information to user (what will be used)
###############################################################################
echo
echo "==== Navidrome bootstrap - summary ===="
echo "Navidrome version: ${NAVIDROME_VERSION}"
echo "Navidrome music path: ${NAVIDROME_MUSIC_PATH}"
echo "Navidrome config path: ${NAVIDROME_CONFIG_PATH}"
echo "Script directory: $SCRIPT_DIR"
echo "======================================"
echo

###############################################################################
# Ensure config directory exists (create if missing)
###############################################################################
if [[ ! -d "$NAVIDROME_CONFIG_PATH" ]]; then
  info "Config directory does not exist; creating: $NAVIDROME_CONFIG_PATH"
  mkdir -p "$NAVIDROME_CONFIG_PATH"
else
  info "Config directory exists: $NAVIDROME_CONFIG_PATH"
fi

###############################################################################
# Ensure music directory exists (create if missing) - we create it so we can
# reliably read numeric uid/gid. If user prefers not to create it, they can
# create beforehand and re-run.
###############################################################################
if [[ ! -d "$NAVIDROME_MUSIC_PATH" ]]; then
  warn "Music directory does not exist; creating: $NAVIDROME_MUSIC_PATH"
  mkdir -p "$NAVIDROME_MUSIC_PATH"
else
  info "Music directory exists: $NAVIDROME_MUSIC_PATH"
fi

###############################################################################
# Extract numeric uid/gid for both paths and ensure they match
###############################################################################
# Use stat -c '%u' '%g' for numeric user/group (POSIX)
if stat --version >/dev/null 2>&1; then
  # GNU stat
  MUSIC_UID="$(stat -c '%u' "$NAVIDROME_MUSIC_PATH")"
  MUSIC_GID="$(stat -c '%g' "$NAVIDROME_MUSIC_PATH")"
  CONFIG_UID="$(stat -c '%u' "$NAVIDROME_CONFIG_PATH")"
  CONFIG_GID="$(stat -c '%g' "$NAVIDROME_CONFIG_PATH")"
else
  # BSD/Mac stat
  MUSIC_UID="$(stat -f '%u' "$NAVIDROME_MUSIC_PATH")"
  MUSIC_GID="$(stat -f '%g' "$NAVIDROME_MUSIC_PATH")"
  CONFIG_UID="$(stat -f '%u' "$NAVIDROME_CONFIG_PATH")"
  CONFIG_GID="$(stat -f '%g' "$NAVIDROME_CONFIG_PATH")"
fi

info "Owner UID/GID of music path: ${MUSIC_UID}:${MUSIC_GID}"
info "Owner UID/GID of config path: ${CONFIG_UID}:${CONFIG_GID}"

if [[ "$MUSIC_UID" != "$CONFIG_UID" || "$MUSIC_GID" != "$CONFIG_GID" ]]; then
  err "UID/GID mismatch between music and config paths."
  err "Music: ${MUSIC_UID}:${MUSIC_GID}  Config: ${CONFIG_UID}:${CONFIG_GID}"
  err "Please ensure both directories have the same owner (numeric uid/gid), or adjust permissions."
  exit 3
fi

###############################################################################
# Export PUID and PGID for docker-compose environment
###############################################################################
export PUID="$MUSIC_UID"
export PGID="$MUSIC_GID"
info "Exported PUID=${PUID}, PGID=${PGID}"

###############################################################################
# Copy navidrome.toml and background directory into config path
###############################################################################
TOML_SRC="$SCRIPT_DIR/configs/navidrome.toml"
BACKGROUND_SRC="$SCRIPT_DIR/background"

if [[ -f "$TOML_SRC" ]]; then
  info "Copying navidrome.toml to ${NAVIDROME_CONFIG_PATH}/navidrome.toml"
  cp -a "$TOML_SRC" "${NAVIDROME_CONFIG_PATH}/navidrome.toml"
else
  warn "navidrome.toml not found in $SCRIPT_DIR. Skipping copy."
fi

if [[ -d "$BACKGROUND_SRC" ]]; then
  info "Copying background directory to ${NAVIDROME_CONFIG_PATH}/background"
  # use rsync if available for reliable recursive copy preserving attributes
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$BACKGROUND_SRC"/ "${NAVIDROME_CONFIG_PATH}/background"/
  else
    # fallback to cp -a
    mkdir -p "${NAVIDROME_CONFIG_PATH}/background"
    cp -a "$BACKGROUND_SRC"/. "${NAVIDROME_CONFIG_PATH}/background"/
  fi
else
  warn "Template background directory not found in $SCRIPT_DIR. Skipping copy."
fi

# Launch all compose within the script directory
compose_files=()
for f in "$SCRIPT_DIR"/docker-compose*.yml; do
    compose_files+=(-f "$f")
done

docker-compose "${compose_files[@]}" up -d
