#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Config and source path (allow override from environment)
CONFIG_PATH=${BEETS_CONFIG_PATH:-/config.yaml}
IMPORT_SRC_PATH=${IMPORT_SRC_PATH:-/import}
DRY_RUN=${DRY_RUN:-no}

# Run beets import.
# We instruct beets to import the IMPORT_SRC_PATH directory.
# -c config file path
# --move causes beets to move files into the library directory (not copy)
# --yes answers confirmations
# If DRY_RUN=yes, use --pretend so beets does not actually move files.
BEET_CMD=(beet -c "$CONFIG_PATH" import)
if [ "$DRY_RUN" = "yes" ]; then
  BEET_CMD+=(--pretend)
else
  BEET_CMD+=(--move)
fi
BEET_CMD+=("$IMPORT_SRC_PATH")
echo "Running: $(printf "%s " "${BEET_CMD[@]}" | tr '\n' ' ')"

# Simple retry wrapper
MAX_RETRIES=5
attempt=0
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
    echo "Whole-import attempt $attempt/$MAX_RETRIES failed — retrying after $((attempt*3))s..."
    sleep $((attempt*5))
  fi
done

echo "Beets finished with exit code $EXIT_CODE"

exit "$EXIT_CODE"
