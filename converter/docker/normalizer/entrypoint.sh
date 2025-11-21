#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SRC_DIR=${SRC_DIR:-/data}
DRY_RUN_FLAG=${DRY_RUN:-no}

if [ "$DRY_RUN_FLAG" = "yes" ] || [ "$DRY_RUN_FLAG" = "true" ]; then
  python3 /app/normalize_dirs.py --source "$SRC_DIR" --dry-run
else
  python3 /app/normalize_dirs.py --source "$SRC_DIR"
fi

echo "Normalization finished."
