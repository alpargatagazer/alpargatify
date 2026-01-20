#!/bin/sh
set -eu

# ============================================================================
# Filebrowser entrypoint with Docker secrets support
# - Reads FILEBROWSER_ADMIN_PASSWORD from secret if available
# - Original functionality from filebrowser-entrypoint.sh preserved
# ============================================================================

# Read secret from file
read_secret() {
  file="/run/secrets/$1"
  if [ -f "$file" ]; then
    cat "$file" | tr -d '\n'
  fi
}

# Try to read password from secret first, fallback to env var
SECRET_PASSWORD="$(read_secret filebrowser_admin_password)"
if [ -n "$SECRET_PASSWORD" ]; then
  FILEBROWSER_ADMIN_PASSWORD="$SECRET_PASSWORD"
fi

# Environment variables with defaults
: "${DB_DIR:=/database}"
: "${DB_FILE:=${DB_DIR}/filebrowser.db}"
: "${ROOT_DIR:=/srv}"
: "${PORT:=8080}"
: "${ADDRESS:=0.0.0.0}"
: "${FB_TIMEOUT:=15}"
: "${PUID:=0}"
: "${PGID:=0}"

# Admin credentials (optional after initial setup)
FILEBROWSER_ADMIN_USER="${FILEBROWSER_ADMIN_USER:-}"
FILEBROWSER_ADMIN_PASSWORD="${FILEBROWSER_ADMIN_PASSWORD:-}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Check if admin credentials are provided
has_admin_credentials() {
  [ -n "$FILEBROWSER_ADMIN_USER" ] && [ -n "$FILEBROWSER_ADMIN_PASSWORD" ]
}

# Start temporary filebrowser instance to bootstrap database
start_quick_setup() {
  log "Starting temporary filebrowser to bootstrap database..."
  
  local log_file="/tmp/filebrowser-quick.log"
  
  filebrowser -r "$ROOT_DIR" \
              -d "$DB_FILE" \
              --username "$FILEBROWSER_ADMIN_USER" \
              --password "$FILEBROWSER_ADMIN_PASSWORD" \
              --port "$PORT" \
              --address "$ADDRESS" >"$log_file" 2>&1 &
  
  local fb_pid=$!
  local elapsed=0
  
  # Wait for DB file creation
  while [ ! -f "$DB_FILE" ] && [ $elapsed -lt "$FB_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  if [ -f "$DB_FILE" ]; then
    log "Database created successfully at $DB_FILE"
  else
    log "ERROR: Timed out waiting for database creation after ${FB_TIMEOUT}s" >&2
    log "Quick-setup log (first 200 lines):" >&2
    head -n 200 "$log_file" 2>/dev/null || true
    return 1
  fi
  
  # Stop temporary process
  if kill -0 "$fb_pid" 2>/dev/null; then
    log "Stopping temporary quick-setup process (pid $fb_pid)..."
    kill "$fb_pid" 2>/dev/null || true
    sleep 1
    kill -0 "$fb_pid" 2>/dev/null && kill -9 "$fb_pid" 2>/dev/null || true
  fi
}

# Check if user exists in database
user_exists() {
  local username="$1"
  
  if ! filebrowser users ls -d "$DB_FILE" 2>/dev/null; then
    return 1
  fi
  
  filebrowser users ls -d "$DB_FILE" 2>/dev/null | \
    awk '{print $2}' | \
    grep -qx -- "$username"
}

# Create or update admin user
ensure_admin_user() {
  local username="$FILEBROWSER_ADMIN_USER"
  local password="$FILEBROWSER_ADMIN_PASSWORD"
  
  if user_exists "$username"; then
    log "User '$username' exists — updating password and admin permissions"
    if ! filebrowser users update "$username" \
           --password "$password" \
           --perm.admin \
           --scope ./ \
           -d "$DB_FILE" 2>/dev/null; then
      log "WARNING: Failed to update user '$username'" >&2
    fi
  else
    log "Creating admin user '$username'"
    if ! filebrowser users add "$username" "$password" \
           --perm.admin \
           --scope ./ \
           -d "$DB_FILE" 2>/dev/null; then
      log "WARNING: Failed to create user '$username'" >&2
    fi
  fi
}

# ============================================================================
# 1) INITIALIZE DIRECTORIES
# ============================================================================

log "Initializing directories..."

mkdir -p "$DB_DIR" "$ROOT_DIR"

# Best-effort ownership/permissions (ignore errors)
if [ "$PUID" != "0" ] || [ "$PGID" != "0" ]; then
  chown -R "${PUID}:${PGID}" "$DB_DIR" "$ROOT_DIR" 2>/dev/null || true
  chmod -R u+rw "$DB_DIR" "$ROOT_DIR" 2>/dev/null || true
fi

# ============================================================================
# 2) BOOTSTRAP DATABASE
# ============================================================================

if [ ! -f "$DB_FILE" ]; then
  log "Database not found — bootstrapping required..."
  
  # For initial setup, admin credentials are mandatory
  if ! has_admin_credentials; then
    log "ERROR: Database doesn't exist and admin credentials not provided" >&2
    log "ERROR: Please set FILEBROWSER_ADMIN_USER and FILEBROWSER_ADMIN_PASSWORD" >&2
    exit 1
  fi
  
  start_quick_setup || exit 1
else
  log "Database already exists at $DB_FILE"
fi

# ============================================================================
# 3) ENSURE ADMIN USER (OPTIONAL AFTER INITIAL SETUP)
# ============================================================================

if [ -f "$DB_FILE" ]; then
  if has_admin_credentials; then
    log "Admin credentials provided — managing user account"
    ensure_admin_user
  else
    log "No admin credentials provided — skipping user management"
    log "Existing users in database will be preserved"
  fi
else
  log "WARNING: Database file not found — skipping user management" >&2
fi

# ============================================================================
# 4) START FILEBROWSER
# ============================================================================

log "Starting filebrowser on $ADDRESS:$PORT with root=$ROOT_DIR"
exec filebrowser -r "$ROOT_DIR" \
                 -d "$DB_FILE" \
                 --address "$ADDRESS" \
                 -p "$PORT"
