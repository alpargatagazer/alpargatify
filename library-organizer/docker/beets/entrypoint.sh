#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Config and source path (allow override from environment)
CONFIG_PATH=${BEETS_CONFIG_PATH:-/config.yaml}
IMPORT_SRC_PATH=${IMPORT_SRC_PATH:-/import}
DRY_RUN=${DRY_RUN:-no}
IMPORT_MODE=${IMPORT_MODE:-full}  # expected values: full, order-only, tag-only

# Build base beet command
BEET_BASE=(beet -c "$CONFIG_PATH")

# Map modes to beets cli flags:
# - full:
#     -> move files into library and autotag (default behavior)
# - order-only:
#     -> move files but do NOT autotag (-A) and DO NOT write tags (-W)
# - tag-only:
#     -> do not move (don't copy): -C ; allow autotag & write tags (default)
#
# Note: beets CLI flags referenced here come from beets docs/manpages:
#   --pretend  : preview without changes
#   --move     : move files into library (instead of copying)
#   -A         : don't autotag (we use this to disable autotagging)
#   -W         : don't write tags (we use this to avoid tag writes)
#   -C         : don't copy (do not move/copy files)  -- use for tag-only
#
# If your beets install uses different flags, adjust these mappings here.

# Compose the final beet import command based on mode and dry run
BEET_CMD=("${BEET_BASE[@]}" import)
if [ "$DRY_RUN" = "yes" ]; then
  # pretend mode: just preview
  BEET_CMD+=(--pretend)
fi

case "$IMPORT_MODE" in
  full)
    # move + autotag (default)
    true
    ;;
  order-only)
    # move files into library, but don't autotag and don't write tags
    BEET_CMD+=(-A -W)
    ;;
  tag-only)
    # autotag/write tags but do NOT move/copy files (-C)
    BEET_CMD+=(-C)
    ;;
  *)
    echo "Unknown IMPORT_MODE: $IMPORT_MODE" >&2
    exit 2
    ;;
esac

# Add import source path
BEET_CMD+=("$IMPORT_SRC_PATH")

echo "Running: $(printf "%s " "${BEET_CMD[@]}" | tr '\n' ' ')"

# Simple retry wrapper (keeps your previous behavior)
MAX_RETRIES=5
attempt=0
EXIT_CODE=1

until [ $attempt -ge $MAX_RETRIES ]
do
  set +e
  "${BEET_CMD[@]}"
  EXIT_CODE=$?
  set -e
  if [ $EXIT_CODE -eq 0 ]; then
    break
  else
    attempt=$((attempt+1))
    echo "Whole-import attempt $attempt/$MAX_RETRIES failed — retrying after $((attempt*5))s..."
    sleep $((attempt*5))
  fi
done

echo "Beets finished with exit code $EXIT_CODE"

exit "$EXIT_CODE"
