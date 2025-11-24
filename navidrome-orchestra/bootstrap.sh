#!/usr/bin/env bash
# bootstrap.sh - prepare config, render a small set of templates safely, validate ownership, copy templates and launch docker-compose
# - creates config dir if missing
# - generates a random CUSTOM_METRICS_PATH for Prometheus to scrape micrservices
# - substitutes variables only in configs/prometheus.yml and configs/Caddyfile (not in docker-compose files)
# - exports PUID and PGID derived from NAVIDROME paths and other env vars for docker compose
# - runs all docker-compose*.yml files found next to the script (combined)
#
# Modes:
#   Default: bring services up (compose up -d)
#   --down : stop services (compose down)

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Helpers
###############################################################################
err()   { echo "ERROR: $*" >&2; }
info()  { echo "INFO: $*"; }
warn()  { echo "WARN: $*" >&2; }

cleanup_tmpfiles() {
  if [[ "${TMP_FILES_CREATED:-}" == "1" ]]; then
    for f in "${TMP_FILES[@]:-}"; do
      [[ -f "$f" ]] && rm -f "$f" || true
    done
  fi
}
trap cleanup_tmpfiles EXIT

###############################################################################
# Parse args (only mode flags)
###############################################################################
MODE="up" # values: up (default), down

usage() {
  cat <<EOF
Usage: $(basename "$0") [--down] [-h|--help]

Modes:
  (default)         : bring services up (docker compose up -d)
  --down            : stop services (docker compose down)

Examples:
  $(basename "$0")
  $(basename "$0") --down
EOF
}

POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --down) MODE="down"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

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
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

###############################################################################
# Required variables (basic validation)
###############################################################################
: "${DOMAIN:?"DOMAIN is not set in .env"}"
: "${NAVIDROME_VERSION:?"NAVIDROME_VERSION is not set in .env"}"
: "${NAVIDROME_MUSIC_PATH:?"NAVIDROME_MUSIC_PATH is not set in .env"}"
: "${NAVIDROME_PORT:?"NAVIDROME_PORT is not set in .env"}"
: "${GRAFANA_PORT:?"GRAFANA_PORT is not set in .env"}"
: "${PROMETHEUS_PORT:?"PROMETHEUS_PORT is not set in .env"}"
: "${CADVISOR_PORT:?"CADVISOR_PORT is not set in .env"}"
: "${NODE_EXPORTER_PORT:?"NODE_EXPORTER_PORT is not set in .env"}"

###############################################################################
# Show info
###############################################################################
echo
echo "==== Navidrome bootstrap - summary ===="
echo "Mode:                       ${MODE}"
echo "Navidrome version:          ${NAVIDROME_VERSION}"
echo "Navidrome music path:       ${NAVIDROME_MUSIC_PATH}"
echo "Microservice volume paths:  ${VOLUMES_PATH}"
echo "Script directory:           ${SCRIPT_DIR}"
echo "======================================"
echo

###############################################################################
# Ensure config and music directories exist
###############################################################################
# Path where music should be
if [[ ! -d "$NAVIDROME_MUSIC_PATH" ]]; then
  warn "Music directory does not exist; creating: $NAVIDROME_MUSIC_PATH"
  mkdir -p "$NAVIDROME_MUSIC_PATH"
else
  info "Music directory exists: $NAVIDROME_MUSIC_PATH"
fi
# Path where the volume of the services will be stored
VOLUMES_PATH="${VOLUMES_PATH:-$SCRIPT_DIR/volumes}"
if [[ ! -d "$VOLUMES_PATH" ]]; then
  warn "Volumes directory does not exist; creating: $VOLUMES_PATH"
  mkdir -p "$VOLUMES_PATH"
else
  info "Volumes directory exists: $VOLUMES_PATH"
fi
# Path where the backgrounds for Navidrome login page are saved
BACKGROUNDS_PATH="${BACKGROUNDS_PATH:-$SCRIPT_DIR/backgrounds}"
if [[ ! -d "$BACKGROUNDS_PATH" ]]; then
  warn "Backgrounds directory does not exist; creating: $BACKGROUNDS_PATH"
  mkdir -p "$BACKGROUNDS_PATH"
else
  info "Backgrounds directory exists: $BACKGROUNDS_PATH"
fi

###############################################################################
# Extract numeric uid/gid for both paths and ensure they match
###############################################################################
# Use stat -c '%u' '%g' for numeric user/group (POSIX)
if stat --version >/dev/null 2>&1; then
  # GNU stat
  MUSIC_UID="$(stat -c '%u' "$NAVIDROME_MUSIC_PATH")"
  MUSIC_GID="$(stat -c '%g' "$NAVIDROME_MUSIC_PATH")"
else
  # BSD/Mac stat
  MUSIC_UID="$(stat -f '%u' "$NAVIDROME_MUSIC_PATH")"
  MUSIC_GID="$(stat -f '%g' "$NAVIDROME_MUSIC_PATH")"
fi

info "Owner UID/GID of music path: ${MUSIC_UID}:${MUSIC_GID}"

###############################################################################
# Export PUID and PGID for docker-compose environment
###############################################################################
export PUID="$MUSIC_UID"
export PGID="$MUSIC_GID"
info "Exported PUID=${PUID}, PGID=${PGID}"

###############################################################################
# Generate random CUSTOM_METRICS_PATH for Prometheus to scrape microservices
# Example: /metrics-5f3a1b2c
###############################################################################
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  else
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

RAN_SUFFIX="$(rand_hex)"
CUSTOM_METRICS_PATH="/metrics-${RAN_SUFFIX}"
export CUSTOM_METRICS_PATH
info "Generated CUSTOM_METRICS_PATH=${CUSTOM_METRICS_PATH}"

###############################################################################
# Template expansion helper
# - we will only render the two config files: configs/prometheus.yml and configs/Caddyfile
# - first we replace the custom placeholders (e.g. <custom_metrics_path>, <domain>, <navidrome_port>, <prometheus_port>, <cadvisor_port>, <node_exporter_port>, <grafana_port>)
#   with ${VAR} style placeholders, then we expand environment variables.
#
# Expansion strategy:
# 1) Prefer envsubst if available.
# 2) Else use perl (recommended fallback).
# 3) Else final fallback: use a safe-ish eval echo per-line expansion (only as last resort).
###############################################################################
TMP_FILES_CREATED=0
TMP_FILES=()

expand_vars_file() {
  local src="$1"; local dst="$2"
  if [[ ! -f "$src" ]]; then
    err "Template not found: $src"; return 1
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/render.XXXXXX")"
  TMP_FILES_CREATED=1
  TMP_FILES+=("$tmp")

  # copy source to tmp
  cp -a "$src" "$tmp"

  # Replace angle-bracket placeholders with ${VAR} so expansion works
  sed -i.bak \
    -e 's|<custom_metrics_path>|${CUSTOM_METRICS_PATH}|g' \
    -e 's|<navidrome_port>|${NAVIDROME_PORT}|g' \
    -e 's|<prometheus_port>|${PROMETHEUS_PORT}|g' \
    -e 's|<cadvisor_port>|${CADVISOR_PORT}|g' \
    -e 's|<node_exporter_port>|${NODE_EXPORTER_PORT}|g' \
    -e 's|<domain>|${DOMAIN}|g' \
    -e 's|<grafana_port>|${GRAFANA_PORT}|g' \
    "$tmp" && rm -f "${tmp}.bak" || true

  # 1) Try envsubst
  if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$tmp" > "$dst"
    info "Rendered $src -> $dst using envsubst"
    return 0
  fi

  # 2) Try perl substitution using %ENV
  if command -v perl >/dev/null 2>&1; then
    # Replace ${VAR} or $VAR with the corresponding env value if present; otherwise leave as-is
    perl -0777 -pe 's/\$\{?([A-Z0-9_]+)\}?/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$tmp" > "$dst"
    info "Rendered $src -> $dst using perl"
    return 0
  fi

  # 3) Final fallback: line-by-line eval expansion.
  # NOTE: using eval is potentially risky if template contains untrusted content.
  # We only use it as last resort on user-controlled local files.
  warn "envsubst and perl not found; falling back to line-by-line eval expansion for $src"
  : > "$dst"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # escape backticks to reduce risk
    safe_line="${line//\`/\\\`}"
    # Use eval to expand variables like ${VAR} and $VAR
    # This purposely preserves whitespace and handles empty variables correctly
    eval "echo \"$safe_line\"" >> "$dst"
    echo >> "$dst"
  done < "$tmp"

  info "Rendered $src -> $dst using fallback eval"
  return 0
}

###############################################################################
# Render configs/prometheus.yml -> configs/prometheus.yml.custom
###############################################################################
PROM_SRC="$SCRIPT_DIR/configs/prometheus.yml"
PROM_DST="$SCRIPT_DIR/configs/prometheus.yml.custom"
if [[ -f "$PROM_SRC" ]]; then
  if ! expand_vars_file "$PROM_SRC" "$PROM_DST"; then
    warn "Failed to render prometheus.yml; copying original as fallback"
    cp -a "$PROM_SRC" "$PROM_DST"
  fi
else
  warn "configs/prometheus.yml not found; skipping rendering."
fi

###############################################################################
# Render configs/Caddyfile -> configs/Caddyfile.custom
###############################################################################
CADDY_SRC="$SCRIPT_DIR/configs/Caddyfile"
CADDY_DST="$SCRIPT_DIR/configs/Caddyfile.custom"
if [[ -f "$CADDY_SRC" ]]; then
  if ! expand_vars_file "$CADDY_SRC" "$CADDY_DST"; then
    warn "Failed to render Caddyfile; copying original as fallback"
    cp -a "$CADDY_SRC" "$CADDY_DST"
  fi
else
  warn "configs/Caddyfile not found; skipping rendering."
fi

###############################################################################
# Determine docker compose availability and create a compose() wrapper
# This avoids branching on every invocation.
###############################################################################
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose "$@"; }
else
  err "Neither 'docker compose' nor 'docker-compose' found. Install Docker Compose."
  exit 6
fi
info "Compose command wrapper is ready."

###############################################################################
# Gather docker-compose files (we will NOT render them; pass original files)
###############################################################################
shopt -s nullglob
compose_ymls=( "$SCRIPT_DIR"/docker-compose*.yml )
shopt -u nullglob

if [[ ${#compose_ymls[@]} -eq 0 ]]; then
  err "No docker-compose*.yml files found in script directory ($SCRIPT_DIR)."
  exit 7
fi

compose_args=()
for f in "${compose_ymls[@]}"; do
  compose_args+=(-f "$f")
done

###############################################################################
# Export env vars for compose
###############################################################################
export NAVIDROME_MUSIC_PATH
export VOLUMES_PATH
export BACKGROUNDS_PATH
export DOMAIN
export CUSTOM_METRICS_PATH
export NAVIDROME_PORT
export GRAFANA_PORT
export PROMETHEUS_PORT
export CADVISOR_PORT
export NODE_EXPORTER_PORT

###############################################################################
# Invoke compose with selected mode using original compose files
###############################################################################
info "Invoking docker compose mode: ${MODE}"

if [[ "$MODE" == "up" ]]; then
  # Force recreate so we make sure configuration stays correct
  compose "${compose_args[@]}" up -d --force-recreate	
  EXIT_CODE=$?
elif [[ "$MODE" == "down" ]]; then
  compose "${compose_args[@]}" down
  EXIT_CODE=$?
else
  err "Unknown MODE: $MODE"
  exit 2
fi

if [[ $EXIT_CODE -ne 0 ]]; then
  err "Docker compose command exited with code: $EXIT_CODE"
  exit $EXIT_CODE
fi

info "Compose command finished successfully."
info "Prometheus will scrape on path: ${CUSTOM_METRICS_PATH}"
