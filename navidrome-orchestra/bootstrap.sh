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
#
# Profiles (compose):
#   By default the script will ENABLE all known profiles so profile-tagged services are started.
#   Known profiles (as of this script): "extra-storage", "wud", "monitoring", "picard"
#
#   You can selectively DISABLE any of those profiles using flags:
#     --no-wud             : disable the "wud" profile
#     --no-extra-storage   : disable the "extra-storage" profile
#     --no-monitoring      : disable the "monitoring" profile
#     --no-picard          : disable the "picard" profile
#
#   Behavior:
#     - Default behavior: all three profiles are enabled and any service in those profiles
#       will be started.
#     - If you pass e.g. --no-wud, no services that belong to the "wud" profile will be
#       started. If you pass multiple --no-* flags, the corresponding profiles will be
#       disabled (for example `--no-extra-storage --no-monitoring` will prevent any service
#       in either "extra-storage" or "monitoring" from starting).
#
#   Implementation notes:
#     - The script will pass --profile NAME to the compose up command for each enabled profile
#       when the compose implementation supports it. If the compose binary does not support
#       profiles, the script will warn and continue (services without profiles will still start).
#
# Examples:
#   $(basename "$0")
#   $(basename "$0") --down
#   $(basename "$0") --no-wud --no-monitoring
#
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Colors (portable-ish): red for error, orange-ish for warn if possible
###############################################################################
_init_colors() {
  RED=""
  ORANGE=""
  RESET=""

  # Prefer tput when available for reset
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  # Detect 256-color capable terminals (TERM contains 256color)
  if [[ "${TERM:-}" == *256color* ]]; then
    # Orange-like (color 208)
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    # Fallback to tput setaf or basic ANSI
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      # If tput failed return empty, fall back to ANSI
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  # If stderr not a terminal, disable colors to keep logs clean
  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

_init_colors
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }

cleanup_tmpfiles() {
  if [[ "${TMP_FILES_CREATED:-}" == "1" ]]; then
    for f in "${TMP_FILES[@]:-}"; do
      [[ -f "$f" ]] && rm -f "$f" || true
    done
  fi
}
trap cleanup_tmpfiles EXIT

###############################################################################
# Parse args (only mode flags + profile disable flags)
###############################################################################
MODE="up" # values: up (default), down

# Profile enable flags (defaults: enabled)
ENABLE_WUD=1
ENABLE_EXTRA_STORAGE=1
ENABLE_MONITORING=1
ENABLE_PICARD=1
ENABLE_DOZZLE=1
# - local: default behavior, <protocol>="http"
# - prod:  production behavior, <protocol>="https"
PROD_MODE=0   # 0=local, 1=prod

usage() {
  cat <<EOF
Usage: $(basename "$0") [--down] [--no-wud] [--no-extra-storage] [--no-monitoring] [--no-picard] [-h|--help]

Modes:
  (default)         : bring services up (docker compose up -d)
  --down            : stop services (docker compose down)

Profile control (defaults: all enabled):
  --no-wud          : disable the "wud" profile (services in this profile will not be started)
  --no-extra-storage: disable the "extra-storage" profile
  --no-monitoring   : disable the "monitoring" profile
  --no-picard       : disable the "picard" profile
  --no-dozzle       : disable the "dozzle" profile
  --prod            : Caddy starts using HTTPS

Examples:
  $(basename "$0")
  $(basename "$0") --down
  $(basename "$0") --no-wud --no-monitoring
EOF
}

POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --down) MODE="down"; shift ;;
    --prod) PROD_MODE=1; shift ;; 
    --no-wud) ENABLE_WUD=0; shift ;;
    --no-extra-storage) ENABLE_EXTRA_STORAGE=0; shift ;;
    --no-monitoring) ENABLE_MONITORING=0; shift ;;
    --no-picard) ENABLE_PICARD=0; shift ;;
    --no-dozzle) ENABLE_DOZZLE=0; shift ;;
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
: "${NAVIDROME_MUSIC_PATH:?"NAVIDROME_MUSIC_PATH is not set in .env"}"

if [ -z "${SFTP_USER:-}" ] ||  [ -z "${SFTP_PASSWORD:-}" ]; then
  err "SFTP_USER and SFTP_PASSWORD must be set in .env. Exiting."
  exit 3
fi

if [ -z "${WUD_ADMIN_USER:-}" ] || [ -z "${WUD_ADMIN_PASSWORD:-}" ] && [ $ENABLE_WUD -eq 1 ]; then
  warn "WUD_ADMIN_USER and WUD_ADMIN_PASSWORD must be set in .env. Exiting."
  exit 3
fi

if [ -z "${GRAFANA_ADMIN_USER:-}" ] || [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ] && [ $ENABLE_MONITORING -eq 1 ]; then
  warn "GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD must be set in .env. Exiting."
  exit 3
fi

if [ -z "${SYNCTHING_GUI_USER:-}" ] || [ -z "${SYNCTHING_GUI_PASSWORD:-}" ] && [ $ENABLE_EXTRA_STORAGE -eq 1 ]; then
  warn "SYNCTHING_GUI_USER and SYNCTHING_GUI_PASSWORD must be set in .env. Exiting."
  exit 3
fi

if [ -z "${FILEBROWSER_ADMIN_USER:-}" ] || [ -z "${FILEBROWSER_ADMIN_PASSWORD:-}" ] && [ $ENABLE_EXTRA_STORAGE -eq 1 ]; then
  warn "FILEBROWSER_ADMIN_USER and FILEBROWSER_ADMIN_PASSWORD must be set in .env. Exiting."
  exit 3
fi

if [ -z "${PICARD_ADMIN_USER:-}" ] || [ -z "${PICARD_ADMIN_PASSWORD:-}" ] && [ $ENABLE_PICARD -eq 1 ]; then
  warn "PICARD_ADMIN_USER and PICARD_ADMIN_PASSWORD must be set in .env if Picard is enabled. Exiting."
  exit 3
fi

# Caddy Basic Auth credentials (required for WUD, Syncthing, and Grafana)
if [ -z "${CADDY_AUTH_USER:-}" ] || [ -z "${CADDY_AUTH_PASSWORD:-}" ]; then
  err "CADDY_AUTH_USER and CADDY_AUTH_PASSWORD must be set in .env. These are used for additional protection on WUD, Syncthing, and Grafana. Exiting."
  exit 3
fi

###############################################################################
# Collect and validate all *_PORT variables dynamically
# - builds PORT_VARS array containing variable names (e.g. PROMETHEUS_PORT)
# - optionally validates they are non-empty and numeric
###############################################################################
PORT_VARS=()
while IFS='=' read -r name _; do
  if [[ "$name" =~ _PORT$ ]]; then
    PORT_VARS+=("$name")
  fi
done < <(env)

for pv in "${PORT_VARS[@]:-}"; do
  val="${!pv:-}"
  if [[ -z "$val" ]]; then
    warn "Port var $pv is empty or not set."
  else
    # basic numeric check
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
      err "Port variable $pv has a non-numeric value: '$val'. Ports must be numeric."
      exit 4
    fi
  fi
done

###############################################################################
# Determine protocol based on PROD_MODE (local vs prod)
###############################################################################
if [[ $PROD_MODE -eq 1 ]]; then
  PROTOCOL="https"
else
  PROTOCOL="http"
fi
export PROTOCOL
info "Running in $( [[ $PROD_MODE -eq 1 ]] && echo "PROD" || echo "LOCAL" ) mode. Protocol=${PROTOCOL}"

###############################################################################
# Show info (avoid printing secrets)
###############################################################################
echo
echo "==== Navidrome bootstrap - summary ===="
echo "Timezone:                   ${TZ}"
echo "Mode:                       ${MODE}"
echo "Navidrome music path:       ${NAVIDROME_MUSIC_PATH}"
echo "Microservice volume paths:  ${VOLUMES_PATH:-<not set>}"
echo "Script directory:           ${SCRIPT_DIR}"
if [[ ${#PORT_VARS[@]} -gt 0 ]]; then
  echo "Discovered *_PORT variables:"
  for pv in "${PORT_VARS[@]}"; do
    printf "  - %s=%s\n" "$pv" "${!pv:-<unset>}"
  done
else
  echo "No *_PORT variables detected in environment."
fi

# Show which secrets are present without printing their values
echo "Secrets present:"
for s in WUD_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD SFTP_PASSWORD SYNCTHING_GUI_PASSWORD FILEBROWSER_ADMIN_PASSWORD PICARD_ADMIN_PASSWORD CADDY_AUTH_PASSWORD; do
  if [[ -n "${!s:-}" ]]; then
    echo "  - ${s}=<set>"
  else
    echo "  - ${s}=<not set>"
  fi
done

# show profile enablement
echo "Compose profiles (defaults: enabled):"
printf "  - extra-storage: %s\n" "$( [[ $ENABLE_EXTRA_STORAGE -eq 1 ]] && echo "enabled" || echo "disabled" )"
printf "  - wud          : %s\n" "$( [[ $ENABLE_WUD -eq 1 ]] && echo "enabled" || echo "disabled" )"
printf "  - monitoring   : %s\n" "$( [[ $ENABLE_MONITORING -eq 1 ]] && echo "enabled" || echo "disabled" )"
printf "  - picard       : %s\n" "$( [[ $ENABLE_PICARD -eq 1 ]] && echo "enabled" || echo "disabled" )"

echo "======================================"
echo

###############################################################################
# Ensure NAVIDROME_PASSWORDENCRYPTIONKEY exists during first boot
###############################################################################
if [[ ! -d "$VOLUMES_PATH/navidrome" ]] && [[ -z "${NAVIDROME_PASSWORDENCRYPTIONKEY}" ]]; then
  error "Variable NAVIDROME_PASSWORDENCRYPTIONKEY is not set in .env. Necessary during first boot."
  exit 3
fi

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
if [[ -z "$NAVIDROME_EXTRA_LIBRARIES_PATH" ]]; then
  NAVIDROME_EXTRA_LIBRARIES_PATH="/tmp/fake_nd_extra_libraries"
  warn "Variable NAVIDROME_EXTRA_LIBRARIES_PATH is not set. Needed for multilibrary feature. Please add it if you plan to create different libraries for different users. Now set to $NAVIDROME_EXTRA_LIBRARIES_PATH"
  export NAVIDROME_EXTRA_LIBRARIES_PATH
else
  if [[ ! -d "$NAVIDROME_EXTRA_LIBRARIES_PATH" ]]; then
    warn "Extra music directory does not exist; creating: $NAVIDROME_EXTRA_LIBRARIES_PATH"
    mkdir -p "$NAVIDROME_EXTRA_LIBRARIES_PATH"
  else
    info "Extra music directory exists: $NAVIDROME_EXTRA_LIBRARIES_PATH"
  fi
fi
# Path where the volume of the services will be stored
VOLUMES_PATH="${VOLUMES_PATH:-$SCRIPT_DIR/volumes}"
if [[ ! -d "$VOLUMES_PATH" ]]; then
  warn "Volumes directory does not exist; creating: $VOLUMES_PATH"
  mkdir -p "$VOLUMES_PATH"
else
  info "Volumes directory exists: $VOLUMES_PATH"
fi
export VOLUMES_PATH

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
# Generate Navidrome metrics password (random) and export it
# - This is used in configs/prometheus.yml for the navidrome job's basic_auth
# - We do not print the password to logs
###############################################################################
generate_random_password() {
  # try openssl for secure random; fallback to hex from /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 12
  else
    od -An -N12 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-16
  fi
}

NAVIDROME_METRICS_PASSWORD="$(generate_random_password)"
export NAVIDROME_METRICS_PASSWORD
info "Generated NAVIDROME_METRICS_PASSWORD (hidden)."

###############################################################################
# Generate Htpasswd-compliant hash for WUD_ADMIN_PASSWORD and export it
# - Preferred: openssl passwd -apr1 (Apache MD5)
# - Fallback: use htpasswd (bcrypt) if available
###############################################################################
# Purpose: Generate hash for WUD (Apache MD5 preferred for compatibility)
generate_wud_hash() {
  local user="$1"; local pass="$2"; local hash=""

  # 1) openssl passwd -apr1 -> Apache MD5 ($apr1$...)
  # This is the standard for many basic auth implementations like WUD
  if command -v openssl >/dev/null 2>&1; then
    if hash="$(openssl passwd -apr1 "$pass" 2>/dev/null)"; then
      echo "$hash"
      return 0
    fi
  fi

  # 2) htpasswd fallback (bcrypt)
  if command -v htpasswd >/dev/null 2>&1; then
    hash_line="$(htpasswd -nbB "$user" "$pass" 2>/dev/null || true)"
    hash="${hash_line#*:}"
    if [[ -n "$hash" ]]; then
      echo "$hash"
      return 0
    fi
  fi

  return 1
}

# Purpose: Generate hash specifically for Caddy (Must be Bcrypt)
generate_caddy_hash() {
  local user="$1"; local pass="$2"; local hash=""

  # 1) Try using the Caddy container itself (Best for compatibility)
  if command -v docker >/dev/null 2>&1; then
    if hash="$(docker run --rm caddy:2.11 caddy hash-password --plaintext "$pass" 2>/dev/null)"; then
      if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
      fi
    fi
  fi

  # 2) htpasswd with -B (Bcrypt)
  if command -v htpasswd >/dev/null 2>&1; then
    hash_line="$(htpasswd -nbB "$user" "$pass" 2>/dev/null || true)"
    hash="${hash_line#*:}"
    if [[ -n "$hash" ]]; then
      echo "$hash"
      return 0
    fi
  fi
  
  return 1
}

# Create the hashed password for WUD
if [[ -n "${WUD_ADMIN_PASSWORD:-}" ]]; then
  WUD_ADMIN_PASSWORD_HASH="$(generate_wud_hash "$WUD_ADMIN_USER" "$WUD_ADMIN_PASSWORD" || true)"
  if [[ -z "${WUD_ADMIN_PASSWORD_HASH:-}" ]]; then
    err "Failed to generate htpasswd-compliant hash for WUD_ADMIN_PASSWORD. Ensure 'htpasswd' or 'openssl' is available."
    exit 5
  fi
  export WUD_ADMIN_PASSWORD_HASH
  info "Generated WUD_ADMIN_PASSWORD_HASH (hidden)."

else
  err "WUD_ADMIN_PASSWORD is empty; cannot generate hash."
  exit 3
fi

# Create the Caddy auth hash and export
if [[ -n "${CADDY_AUTH_PASSWORD:-}" ]]; then
  CADDY_AUTH_PASSWORD_HASH="$(generate_caddy_hash "$CADDY_AUTH_USER" "$CADDY_AUTH_PASSWORD" || true)"
  if [[ -z "${CADDY_AUTH_PASSWORD_HASH:-}" ]]; then
    err "Failed to generate htpasswd-compliant hash for CADDY_AUTH_PASSWORD. Ensure 'htpasswd' or 'openssl' is available."
    exit 5
  fi
  export CADDY_AUTH_PASSWORD_HASH
  info "Generated CADDY_AUTH_PASSWORD_HASH (hidden)."
else
  err "CADDY_AUTH_PASSWORD is empty; cannot generate hash."
  exit 3
fi

###############################################################################
# Template expansion helper (dynamic PORT placeholder handling)
# - we will only render the two config files: configs/prometheus.yml and configs/Caddyfile
# - dynamically build sed replacements for all discovered *_PORT variables
# - also always replace <custom_metrics_path> and <domain>
# - also ensure <wud_admin_user>, <wud_admin_password>, <navidrome_metrics_password> are replaced
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

  # Build sed arguments dynamically
  # Start with known placeholders
  sed_args=()
  sed_args+=( -e "s|<custom_metrics_path>|\\\${CUSTOM_METRICS_PATH}|g" )
  sed_args+=( -e "s|<domain>|\\\${DOMAIN}|g" )
  sed_args+=( -e "s|<protocol>|\\\${PROTOCOL}|g" )
  sed_args+=( -e "s|<wud_admin_user>|\\\${WUD_ADMIN_USER}|g" )
  sed_args+=( -e "s|<wud_admin_password>|\\\${WUD_ADMIN_PASSWORD}|g" )
  sed_args+=( -e "s|<navidrome_metrics_password>|\\\${NAVIDROME_METRICS_PASSWORD}|g" )
  # Caddy Basic Auth placeholders
  sed_args+=( -e "s|<caddy_auth_user>|\\\${CADDY_AUTH_USER}|g" )
  sed_args+=( -e "s|<caddy_auth_password_hash>|\\\${CADDY_AUTH_PASSWORD_HASH}|g" )

  # For each discovered PORT var, add a replacement
  for pv in "${PORT_VARS[@]:-}"; do
    # lowercase placeholder name (PROMETHEUS_PORT -> prometheus_port)
    lc="$(echo "$pv" | tr '[:upper:]' '[:lower:]')"
    # replacement should be literal ${VAR} so later envsubst/perl expands it
    replacement='\${'"$pv"'}'
    sed_args+=( -e "s|<${lc}>|${replacement}|g" )
  done

  # Also include any other env-based placeholders you want (grafana_port etc) if present
  if [[ -n "${GRAFANA_PORT:-}" ]]; then
    sed_args+=( -e "s|<grafana_port>|\\\${GRAFANA_PORT}|g" )
  fi

  # Apply sed replacements in-place (create .bak then remove)
  sed -i.bak "${sed_args[@]}" "$tmp" && rm -f "${tmp}.bak" || true

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

# Check whether the compose implementation supports --profile for 'up'
SUPPORTS_PROFILE=0
if compose help up 2>&1 | grep -q -- '--profile'; then
  SUPPORTS_PROFILE=1
else
  # try a generic help check if previous failed (some implementations differ)
  if compose --help 2>&1 | grep -q -- '--profile'; then
    SUPPORTS_PROFILE=1
  fi
fi

if [[ $SUPPORTS_PROFILE -eq 0 ]]; then
  warn "Compose implementation does not advertise '--profile' support; profile control flags will be ignored. Services without profiles will still start."
fi

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

COMPOSE_PROJECT="navidrome-orchestra"
compose_args=(-p $COMPOSE_PROJECT)
for f in "${compose_ymls[@]}"; do
  compose_args+=(-f "$f")
done

###############################################################################
# Build profile args for 'compose up' when applicable
# Default: enable all known profiles unless explicitly disabled by flags.
###############################################################################
PROFILE_ARGS=()
if [[ $SUPPORTS_PROFILE -eq 1 ]]; then
  if [[ $ENABLE_EXTRA_STORAGE -eq 1 ]]; then
    PROFILE_ARGS+=( --profile extra-storage )
  fi
  if [[ $ENABLE_WUD -eq 1 ]]; then
    PROFILE_ARGS+=( --profile wud )
  fi
  if [[ $ENABLE_MONITORING -eq 1 ]]; then
    PROFILE_ARGS+=( --profile monitoring )
  fi
  if [[ $ENABLE_PICARD -eq 1 ]]; then
    PROFILE_ARGS+=( --profile picard )
  fi
  if [[ $ENABLE_DOZZLE -eq 1 ]]; then
    PROFILE_ARGS+=( --profile dozzle )
  fi
  if [[ $PROD_MODE -eq 1 ]]; then
    PROFILE_ARGS+=( --profile prod )
  fi
fi

###############################################################################
# Unset unused secrets to prevent leaking into the environment
###############################################################################
# WUD_ADMIN_PASSWORD uses WUD_ADMIN_PASSWORD_HASH for the container
unset WUD_ADMIN_PASSWORD
# CADDY_AUTH_PASSWORD uses CADDY_AUTH_PASSWORD_HASH in Caddyfile
unset CADDY_AUTH_PASSWORD

###############################################################################
# Invoke compose with selected mode using original compose files
###############################################################################
info "Invoking docker compose mode: ${MODE}"

if [[ "$MODE" == "up" ]]; then
  # Force recreate so we make sure configuration stays correct
  # We include PROFILE_ARGS only for 'up' if supported; down doesn't need profiles
  if [[ ${#PROFILE_ARGS[@]} -gt 0 ]]; then
    info "Enabled compose profiles: $(printf '%s ' "${PROFILE_ARGS[@]}")"
  else
    info "No compose profiles will be passed (either disabled or unsupported)."
  fi

  compose "${compose_args[@]}" "${PROFILE_ARGS[@]:-}" up -d --force-recreate --remove-orphans
  EXIT_CODE=$?
elif [[ "$MODE" == "down" ]]; then
  compose "${compose_args[@]}" "${PROFILE_ARGS[@]:-}" down --remove-orphans
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
