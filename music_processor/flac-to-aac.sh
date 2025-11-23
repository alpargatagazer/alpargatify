#!/usr/bin/env bash
# flac-to-aac.sh (modified to preserve metadata)
# macOS: recursively convert .flac -> AAC (.m4a) using afconvert
# - preserves source tree under destination
# - preserve tags (you need to install "metaflag" and "AtomicParsley")
# - env/configurable options via AF_OPTS (see below)
# - flags: --help, --force (overwrite), --dry-run
# Based on https://ss64.com/mac/afconvert.html

set -u
set -o pipefail
IFS=$'\n\t'

# Defaults (change by editing script or by setting AF_OPTS)
# Default chosen for "very good quality but small size": 256 kbps AAC
DEFAULT_AF_ARGS=( -f m4af -d aac -b 192000 -q 127 )

# You may set AF_OPTS in the environment to override or append options.
# Example (append): AF_OPTS='-b 160000' ./flac-to-aac.sh src dest
# Example (replace): AF_OPTS='-f mp4f -d aac -b 160000 -q 127'
: "${AF_OPTS:=}"   # optional string of extra/override options

# Other env flags:
: "${SKIP_EXISTING:=yes}"   # yes -> skip existing outputs; no -> overwrite
: "${VERBOSE:=no}"          # yes -> extra debug
: "${DRY_RUN:=no}"          # yes -> don't execute, just show commands

usage() {
  cat <<EOF
flac-to-aac.sh - convert .flac -> AAC (.m4a) (macOS afconvert)

Usage:
  $(basename "$0") [--force] [--dry-run] /path/to/source /path/to/destination

Flags:
  -h, --help      show this help and exit
  --force         overwrite existing destination files (equivalent to SKIP_EXISTING=no)
  --dry-run       show actions without running afconvert (equivalent to DRY_RUN=yes)

Environment:
  AF_OPTS         optional extra afconvert options (whitespace-separated tokens)
                  Example: AF_OPTS='-b 160000' ./flac-to-aac.sh src dest
  SKIP_EXISTING   ${SKIP_EXISTING}
  VERBOSE         ${VERBOSE}
  DRY_RUN         ${DRY_RUN}

Default encoding (change AF_OPTS to override):
  ${DEFAULT_AF_ARGS[*]}
EOF
}

# --- minimal flag parsing ---
declare -a POSITIONAL=()
FORCE_FROM_CLI="no"

while (( "$#" )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE_FROM_CLI="yes"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  echo "Error: source and destination required." >&2
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

# apply --force
if [ "$FORCE_FROM_CLI" = "yes" ]; then
  SKIP_EXISTING="no"
fi

# normalize yes/no
normalize_bool() {
  case "$1" in
    yes|Yes|YES|y|Y|true|True|TRUE) echo "yes" ;;
    *) echo "no" ;;
  esac
}
SKIP_EXISTING="$(normalize_bool "$SKIP_EXISTING")"
DRY_RUN="$(normalize_bool "$DRY_RUN")"
VERBOSE="$(normalize_bool "$VERBOSE")"

# --- PRECHECKS: macOS and required commands ---
# Detect macOS (Darwin)
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: afconvert is macOS-only. This script requires macOS (Darwin)." >&2
  exit 5
# Ensure afconvert exists
elif ! command -v afconvert >/dev/null 2>&1; then
  echo "Error: afconvert not found in PATH. Ensure you're on macOS and Xcode (or Command Line Tools) is installed." >&2
  exit 6
fi

# Optional tools for metadata (we'll continue if missing but warn)
MISSING_META_TOOLS=""
if ! command -v metaflac >/dev/null 2>&1; then
  MISSING_META_TOOLS="$MISSING_META_TOOLS metaflac"
fi
if ! command -v AtomicParsley >/dev/null 2>&1; then
  MISSING_META_TOOLS="$MISSING_META_TOOLS AtomicParsley"
fi
if [ -n "$MISSING_META_TOOLS" ]; then
  echo "Warning: metadata copying will be skipped or limited because the following tools are missing:$MISSING_META_TOOLS" >&2
fi
# --- end prechecks ---

# Sanity checks
if [ ! -d "$SRC" ]; then
  echo "Error: source directory does not exist: $SRC" >&2
  exit 3
fi
mkdir -p "$DEST" || { echo "Error: cannot create destination: $DEST" >&2; exit 4; }
SRC="${SRC%/}"

# Build actual AF_ARGS array:
AF_ARGS=( "${DEFAULT_AF_ARGS[@]}" )

# If AF_OPTS is set, split it safely into tokens and replace AF_ARGS if user intends to replace.
# Heuristic: if AF_OPTS contains -f or -d or -b or -q then treat as replacement of defaults.
if [ -n "${AF_OPTS}" ]; then
  # split AF_OPTS on whitespace into tokens
  read -r -a tmp <<< "$AF_OPTS"
  # if tmp contains any of common root flags, replace defaults (user explicitly provided flags)
  replace=no
  for t in "${tmp[@]}"; do
    case "$t" in -f|-d|-b|-q) replace=yes; break ;; esac
  done
  if [ "$replace" = "yes" ]; then
    AF_ARGS=( "${tmp[@]}" )
  else
    AF_ARGS+=( "${tmp[@]}" )
  fi
fi

vprint() { [ "$VERBOSE" = "yes" ] && printf '%s\n' "$*"; }

echo "Settings summary:"
echo "  Source:        $SRC"
echo "  Destination:   $DEST"
echo -n "  afconvert args: "
printf '%s ' "${AF_ARGS[@]}"
echo
echo "  SKIP_EXISTING: $SKIP_EXISTING"
echo "  DRY_RUN:       $DRY_RUN"
echo "  VERBOSE:       $VERBOSE"
echo

# Find and convert .flac files
find "$SRC" -type f -iname '*.flac' -print0 |
while IFS= read -r -d '' srcfile; do
  if [[ "$srcfile" == "$SRC/"* ]]; then
    relpath="${srcfile:$(( ${#SRC} + 1 ))}"
  else
    relpath="$srcfile"
  fi
  dirpart="$(dirname "$relpath")"
  base="$(basename "$relpath")"
  name="${base%.*}"
  if [ "$dirpart" = "." ]; then
    destdir="$DEST"
  else
    destdir="$DEST/$dirpart"
  fi
  mkdir -p "$destdir" || { echo "Warning: could not create $destdir" >&2; continue; }
  destfile="$destdir/$name.m4a"

  if [ -e "$destfile" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      vprint "Skipping (exists): $destfile"
      continue
    else
      rm -f "$destfile" || { echo "Warning: could not remove existing $destfile" >&2; continue; }
    fi
  fi

  echo "Converting:"
  echo "  source: $srcfile"
  echo "  dest:   $destfile"

  if [ "$DRY_RUN" = "yes" ]; then
    # Print safe, human-readable command
    printf '  -> DRY RUN: afconvert'
    for tok in "${AF_ARGS[@]}"; do printf ' %s' "$tok"; done
    printf ' %q %q\n' "$srcfile" "$destfile"
    continue
  fi

  # Assemble command array and run
  cmd=(afconvert)
  if [ "${#AF_ARGS[@]}" -gt 0 ]; then
    cmd+=( "${AF_ARGS[@]}" )
  fi
  cmd+=( "$srcfile" "$destfile" )

  # Create one temporary working directory for metadata extraction and ensure cleanup
  TMPD=""
  if ! TMPD="$(mktemp -d 2>/dev/null)"; then
    echo "Warning: could not create global temp dir; metadata operations may fail." >&2
  else
    # cleanup on exit/interrupt
    trap 'rm -rf "$TMPD"' EXIT INT TERM
  fi

  vprint "Running: ${cmd[*]}"
  if "${cmd[@]}"; then
    # --- METADATA PRESERVATION ---
    # Export Vorbis comments + embedded picture from the source FLAC and apply them to the
    # destination M4A. Errors here are non-fatal and will print warnings only.
    if command -v metaflac >/dev/null 2>&1 && command -v AtomicParsley >/dev/null 2>&1; then
      if [ -d "$TMPD" ]; then
        metafile="$TMPD/meta.txt"
        # try to export Vorbis comments; metaflac prints TAG=VALUE lines
        if metaflac --export-tags-to="$metafile" "$srcfile" 2>/dev/null; then
          ap_args=()
          while IFS= read -r line || [ -n "$line" ]; do
            # skip empty lines
            [ -z "$line" ] && continue
            key="${line%%=*}"
            val="${line#*=}"
            # normalize key to upper-case
            case "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" in
              TITLE) ap_args+=( --title "$val" ) ;;
              ARTIST) ap_args+=( --artist "$val" ) ;;
              ALBUM) ap_args+=( --album "$val" ) ;;
              TRACKNUMBER) ap_args+=( --tracknum "$val" ) ;;
              DATE|YEAR) ap_args+=( --year "$val" ) ;;
              GENRE) ap_args+=( --genre "$val" ) ;;
              COMMENT) ap_args+=( --comment "$val" ) ;;
              ALBUMARTIST) ap_args+=( --albumArtist "$val" ) ;;
              COMPOSER) ap_args+=( --composer "$val" ) ;;
              DISCNUMBER) ap_args+=( --disk "$val" ) ;;
              # add more mappings here if needed
            esac
          done < "$metafile"

          # try to export embedded picture (cover art). metaflac exits non-zero if no picture.
          picfile="$TMPD/cover"
          if metaflac --export-picture-to="$picfile" "$srcfile" 2>/dev/null; then
            # AtomicParsley expects a file with extension; try to detect image type
            # by file command if available, otherwise fallback to .jpg
            if command -v file >/dev/null 2>&1; then
              ftype=$(file --brief --mime-type "$picfile" 2>/dev/null || echo "image/jpeg")
              case "$ftype" in
                image/png) picfile_ext="$picfile.png" ;;
                image/jpeg) picfile_ext="$picfile.jpg" ;;
                image/*) picfile_ext="$picfile.img" ;;
                *) picfile_ext="$picfile.jpg" ;;
              esac
              mv "$picfile" "$picfile_ext" 2>/dev/null || true
            else
              picfile_ext="$picfile.jpg"
              mv "$picfile" "$picfile_ext" 2>/dev/null || true
            fi
            ap_args+=( --artwork "$picfile_ext" )
          fi

          if [ "${#ap_args[@]}" -gt 0 ]; then
            vprint "Applying metadata with AtomicParsley: ${ap_args[*]}"
            if AtomicParsley "$destfile" "${ap_args[@]}" --overWrite >/dev/null 2>&1; then
              vprint "Metadata written to $destfile"
            else
              echo "Warning: AtomicParsley failed to write metadata to $destfile" >&2
            fi
          fi
        fi
      fi
    else
      vprint "metaflac or AtomicParsley not available; skipping metadata copy"
    fi

    echo "  -> OK"
  else
    echo "  -> ERROR converting $srcfile" >&2
    [ -e "$destfile" ] && rm -f "$destfile"
  fi
done

echo "All done."
