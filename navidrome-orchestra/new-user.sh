#!/usr/bin/env bash
# create_navidrome_user.sh - Create a new Navidrome library and user
# Usage: ./create_navidrome_user.sh <username> <password>
#
# This script:
# - Creates a new library in /extra-libraries/<username>
# - Creates a new user with access to the default library (ID 1) and their personal library
# - User is NOT an admin
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

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") <username> <password>

Creates a new Navidrome library and user account.

Arguments:
  username    Username for the new user (required)
  password    Password for the new user (required)

Example:
  $(basename "$0") alice MySecurePass123

Requirements:
  - .env file must exist in script directory
  - NAVIDROME_PASSWORDENCRYPTIONKEY must be set in .env
  - navidrome container must be running
  - openssl command must be available for password encryption
EOF
}

###############################################################################
# Parse arguments
###############################################################################
if [[ $# -ne 2 ]]; then
  err "Invalid number of arguments."
  usage
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"

if [[ -z "$USERNAME" ]]; then
  err "Username cannot be empty."
  exit 1
fi

if [[ -z "$PASSWORD" ]]; then
  err "Password cannot be empty."
  exit 1
fi

# Validate username (alphanumeric, underscores, hyphens only)
if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  err "Username can only contain letters, numbers, underscores, and hyphens."
  exit 1
fi

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
# Validate required environment variables
###############################################################################
: "${NAVIDROME_PASSWORDENCRYPTIONKEY:?"NAVIDROME_PASSWORDENCRYPTIONKEY is not set in .env"}"

CONTAINER_NAME="${NAVIDROME_CONTAINER_NAME:-navidrome}"

# Check if container exists and is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  err "Container '${CONTAINER_NAME}' is not running."
  exit 3
fi

###############################################################################
# Validate openssl is available for password encryption
###############################################################################
if ! command -v openssl >/dev/null 2>&1; then
  err "openssl command not found. Required for password encryption."
  exit 4
fi

###############################################################################
# Helper function to execute SQL and capture errors
###############################################################################
exec_sql() {
  local sql="$1"
  local error_output
  local result
  
  error_output=$(mktemp)
  trap 'rm -f "$error_output"' RETURN
  
  result=$(docker exec "$CONTAINER_NAME" sqlite3 /data/navidrome.db "$sql" 2>"$error_output")
  local exit_code=$?
  
  if [[ $exit_code -ne 0 ]]; then
    err "SQL execution failed with exit code $exit_code"
    if [[ -s "$error_output" ]]; then
      err "SQLite error output:"
      cat "$error_output" >&2
    fi
    return $exit_code
  fi
  
  echo "$result"
  return 0
}

###############################################################################
# Encrypt password using AES-256-CBC with the encryption key
###############################################################################
info "Encrypting password..."

# Navidrome uses AES-256-CBC with the key directly (no IV in the encrypted output format)
# The encrypted password is base64 encoded
ENCRYPTED_PASSWORD=$(echo -n "$PASSWORD" | openssl enc -aes-256-cbc -a -A -salt -pass "pass:${NAVIDROME_PASSWORDENCRYPTIONKEY}" 2>/dev/null)

if [[ -z "$ENCRYPTED_PASSWORD" ]]; then
  err "Failed to encrypt password."
  exit 5
fi

info "Password encrypted successfully."

###############################################################################
# Generate UUID for user ID
###############################################################################
generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 22
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import uuid; print(uuid.uuid4().hex[:22])"
  else
    # Fallback: use random hex
    openssl rand -hex 11 2>/dev/null || od -An -N11 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

USER_ID=$(generate_uuid)
info "Generated user ID: ${USER_ID}"

###############################################################################
# Create library in database
###############################################################################
LIBRARY_PATH="/extra-libraries/${USERNAME}"
LIBRARY_NAME="${USERNAME}_library"

info "Creating library: ${LIBRARY_NAME} at path ${LIBRARY_PATH}"

# First check if library already exists
info "Checking for existing library..."
EXISTING_LIBRARY=$(exec_sql "SELECT id FROM library WHERE path = '${LIBRARY_PATH}' OR name = '${LIBRARY_NAME}';" || echo "")

if [[ -n "$EXISTING_LIBRARY" ]]; then
  warn "Library with path '${LIBRARY_PATH}' or name '${LIBRARY_NAME}' already exists."
  LIBRARY_ID="$EXISTING_LIBRARY"
  info "Using existing library ID: ${LIBRARY_ID}"
else
  # Insert new library
  info "Inserting new library into database..."
  
  INSERT_RESULT=$(exec_sql "INSERT INTO library (name, path, remote_path, last_scan_at, updated_at, created_at, last_scan_started_at, full_scan_in_progress, total_songs, total_albums, total_artists, total_folders, total_files, total_missing_files, total_size, total_duration, default_new_users) VALUES ('${LIBRARY_NAME}', '${LIBRARY_PATH}', '', '0000-00-00 00:00:00', datetime('now'), datetime('now'), '0000-00-00 00:00:00', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);")
  
  if [[ $? -ne 0 ]]; then
    err "Failed to create library in database."
    exit 6
  fi

  info "Library insert completed, retrieving ID..."
  
  # Get the library ID - try multiple approaches
  LIBRARY_ID=$(exec_sql "SELECT id FROM library WHERE path = '${LIBRARY_PATH}';" || echo "")
  
  if [[ -z "$LIBRARY_ID" ]]; then
    # Try by name instead
    info "Attempting to retrieve library ID by name..."
    LIBRARY_ID=$(exec_sql "SELECT id FROM library WHERE name = '${LIBRARY_NAME}';" || echo "")
  fi
  
  if [[ -z "$LIBRARY_ID" ]]; then
    # Show what libraries exist for debugging
    err "Failed to retrieve library ID after creation."
    info "Debugging: Current libraries in database:"
    exec_sql "SELECT id, name, path FROM library;" || true
    exit 7
  fi

  info "Library created successfully with ID: ${LIBRARY_ID}"
fi

###############################################################################
# Check if user already exists
###############################################################################
info "Checking if user '${USERNAME}' already exists..."

EXISTING_USER=$(exec_sql "SELECT id FROM user WHERE user_name = '${USERNAME}';" || echo "")

if [[ -n "$EXISTING_USER" ]]; then
  err "User '${USERNAME}' already exists with ID: ${EXISTING_USER}"
  exit 8
fi

###############################################################################
# Create user in database
###############################################################################
info "Creating user '${USERNAME}'..."

CURRENT_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

exec_sql "INSERT INTO user (id, user_name, name, email, password, is_admin, last_login_at, last_access_at, created_at, updated_at) VALUES ('${USER_ID}', '${USERNAME}', '${USERNAME}', '', '${ENCRYPTED_PASSWORD}', 0, NULL, NULL, '${CURRENT_TIME}', '${CURRENT_TIME}');"

if [[ $? -ne 0 ]]; then
  err "Failed to create user in database."
  exit 9
fi

info "User '${USERNAME}' created successfully with ID: ${USER_ID}"

###############################################################################
# Assign libraries to user (default library ID 1 + new library)
###############################################################################
info "Assigning libraries to user..."

# Check if user_library table exists
TABLE_CHECK=$(exec_sql "SELECT name FROM sqlite_master WHERE type='table' AND name='user_library';" || echo "")

if [[ -z "$TABLE_CHECK" ]]; then
  err "Table 'user_library' does not exist in the database."
  info "Available tables:"
  exec_sql "SELECT name FROM sqlite_master WHERE type='table';" || true
  exit 10
fi

# Create user_library entries for library access
# Library ID 1 is the default music library
info "Assigning default library (ID: 1)..."
exec_sql "INSERT INTO user_library (user_id, library_id) VALUES ('${USER_ID}', '1');"

if [[ $? -ne 0 ]]; then
  err "Failed to assign default library to user."
  exit 11
fi

info "Assigning personal library (ID: ${LIBRARY_ID})..."
exec_sql "INSERT INTO user_library (user_id, library_id) VALUES ('${USER_ID}', '${LIBRARY_ID}');"

if [[ $? -ne 0 ]]; then
  err "Failed to assign personal library to user."
  exit 12
fi

info "Libraries assigned successfully."

###############################################################################
# Summary
###############################################################################
echo
echo "==== User Creation Summary ===="
echo "Username:        ${USERNAME}"
echo "User ID:         ${USER_ID}"
echo "Library Name:    ${LIBRARY_NAME}"
echo "Library Path:    ${LIBRARY_PATH}"
echo "Library ID:      ${LIBRARY_ID}"
echo "Is Admin:        false"
echo "Accessible Libraries:"
echo "  - Library ID 1 (default music library)"
echo "  - Library ID ${LIBRARY_ID} (${LIBRARY_NAME})"
echo "================================"
echo
info "User creation completed successfully!"
info "The user can now log in with username '${USERNAME}' and the provided password."