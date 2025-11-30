#!/usr/bin/env bash
# flac-to-aac.sh - macOS: recursively convert .flac -> AAC (.m4a) using afconvert

set -u
set -o pipefail
IFS=$'\n\t'

###############################################################################
# Global variables
###############################################################################
RED=""
ORANGE=""
RESET=""
MISSING_META_TOOLS=""
XLD_PRESENT="no"
SKIP_EXISTING="yes"
VERBOSE="no"
DRY_RUN="no"
DEFAULT_AF_ARGS=( -f m4af -d "aac" -b 192000 -q 127 )
declare -a AF_ARGS

###############################################################################
# Initialization functions
###############################################################################
init_colors() {
  RESET=""
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  if [[ "${TERM:-}" == *256color* ]]; then
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

normalize_bool() {
  case "$1" in
    yes|Yes|YES|y|Y|true|True|TRUE) echo "yes" ;;
    *) echo "no" ;;
  esac
}

###############################################################################
# Logging functions
###############################################################################
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }
debug(){ if [ "$VERBOSE" = "yes" ]; then printf '%s DEBUG: %s\n' "$(time_stamp)" "$*"; fi }

###############################################################################
# Help and usage
###############################################################################
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
                  Example: AF_OPTS='-f mp4f -d "aacf@24000" -b 256000 -q 127' ./flac-to-aac.sh src dest
  SKIP_EXISTING   ${SKIP_EXISTING}
  VERBOSE         ${VERBOSE}
  DRY_RUN         ${DRY_RUN}

Default encoding (change AF_OPTS to override):
  ${DEFAULT_AF_ARGS[*]}
EOF
}

###############################################################################
# Argument parsing
###############################################################################
parse_arguments() {
  declare -a POSITIONAL=()
  local FORCE_FROM_CLI="no"

  while (( "$#" )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --force) FORCE_FROM_CLI="yes"; shift ;;
      --dry-run) DRY_RUN="yes"; shift ;;
      --) shift; break ;;
      -*)
        err "Unknown option: $1"
        usage
        exit 2
        ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done

  set -- "${POSITIONAL[@]:-}"

  if [ "${#}" -ne 2 ]; then
    err "source and destination required."
    usage
    exit 2
  fi

  SRC="$1"
  DEST="$2"

  if [ "$FORCE_FROM_CLI" = "yes" ]; then
    SKIP_EXISTING="no"
  fi

  SKIP_EXISTING="$(normalize_bool "$SKIP_EXISTING")"
  DRY_RUN="$(normalize_bool "$DRY_RUN")"
  VERBOSE="$(normalize_bool "$VERBOSE")"
}

###############################################################################
# System checks
###############################################################################
check_system_requirements() {
  if [ "$(uname -s)" != "Darwin" ]; then
    err "afconvert is macOS-only. This script requires macOS (Darwin)."
    exit 5
  elif ! command -v afconvert >/dev/null 2>&1; then
    err "afconvert not found in PATH. Ensure you're on macOS and Xcode (or Command Line Tools) is installed."
    exit 6
  fi
}

check_optional_tools() {
  MISSING_META_TOOLS=""
  if ! command -v metaflac >/dev/null 2>&1; then 
    MISSING_META_TOOLS="$MISSING_META_TOOLS metaflac"
  fi
  if ! command -v AtomicParsley >/dev/null 2>&1; then 
    MISSING_META_TOOLS="$MISSING_META_TOOLS AtomicParsley"
  fi
  if [ -n "$MISSING_META_TOOLS" ]; then
    warn "metadata copying will be skipped or limited because the following tools are missing:$MISSING_META_TOOLS"
  fi

  XLD_PRESENT="no"
  if command -v xld >/dev/null 2>&1; then
    XLD_PRESENT="yes"
  else
    warn "XLD not found. Cue-based splitting will be skipped; single-file conversion only."
  fi
}

validate_paths() {
  if [ ! -d "$SRC" ]; then
    err "source directory does not exist: $SRC"
    exit 3
  fi
  mkdir -p "$DEST" || { err "cannot create destination: $DEST"; exit 4; }
  SRC="${SRC%/}"
}

###############################################################################
# Configuration
###############################################################################
setup_afconvert_args() {
  : "${AF_OPTS:=}"
  if [ -n "${AF_OPTS}" ]; then
    eval "AF_ARGS=($AF_OPTS)"
    debug "Using custom AF_OPTS: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
    debug "Remember that default is: $(printf '%s ' "${DEFAULT_AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
  else
    AF_ARGS=( "${DEFAULT_AF_ARGS[@]}" )
  fi
}

print_settings() {
  info "Settings summary:"
  info "  Source:        $SRC"
  info "  Destination:   $DEST"
  debug "  afconvert args: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
  info "  SKIP_EXISTING: $SKIP_EXISTING"
  info "  DRY_RUN:       $DRY_RUN"
  info "  VERBOSE:       $VERBOSE"
  info ""
}

###############################################################################
# Metadata handling
###############################################################################
apply_metadata_to_m4a() {
  local in_file="$1"
  local out_file="$2"

  if ! command -v metaflac >/dev/null 2>&1 || ! command -v AtomicParsley >/dev/null 2>&1; then
    debug "metaflac or AtomicParsley not available; skipping metadata copy for $out_file"
    return 0
  fi

  case "${in_file##*/}" in
    *.flac|*.FLAC) ;;
    *)
      debug "Input not FLAC; skipping metaflac-based metadata copy for $in_file"
      return 0
      ;;
  esac

  local TMPD2
  TMPD2="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
  if [ -z "$TMPD2" ]; then
    return 0
  fi

  local metafile="$TMPD2/meta.txt"
  local ap_args=()

  if metaflac --export-tags-to="$metafile" "$in_file" 2>/dev/null; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      local key="${line%%=*}"
      local val="${line#*=}"
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
      esac
    done < "$metafile"

    local picfile="$TMPD2/cover"
    if metaflac --export-picture-to="$picfile" "$in_file" 2>/dev/null; then
      local picfile_ext
      if command -v file >/dev/null 2>&1; then
        local ftype
        ftype=$(file --brief --mime-type "$picfile" 2>/dev/null || echo "image/jpeg")
        case "$ftype" in
          image/png) picfile_ext="${picfile}.png" ;;
          image/jpeg) picfile_ext="${picfile}.jpg" ;;
          image/*) picfile_ext="${picfile}.img" ;;
          *) picfile_ext="${picfile}.jpg" ;;
        esac
        mv "$picfile" "$picfile_ext" 2>/dev/null || true
      else
        picfile_ext="${picfile}.jpg"
        mv "$picfile" "$picfile_ext" 2>/dev/null || true
      fi
      ap_args+=( --artwork "$picfile_ext" )
    fi

    if [ "${#ap_args[@]}" -gt 0 ]; then
      debug "Applying metadata with AtomicParsley: $(printf '%s ' "${ap_args[@]}" | sed -E 's/[[:space:]]+$//')"
      if AtomicParsley "$out_file" "${ap_args[@]}" --overWrite >/dev/null 2>&1; then
        debug "Metadata written to $out_file"
      else
        warn "AtomicParsley failed to write metadata to $out_file"
      fi
    fi
  fi

  if [ -n "$TMPD2" ] && [ -d "$TMPD2" ]; then
    rm -rf "$TMPD2" || true
  fi
}

###############################################################################
# Core conversion functions
###############################################################################
convert_to_m4a() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local name="${base%.*}"
  local out_file="$out_dir/$name.m4a"

  if [ -e "$out_file" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $out_file"
      return 0
    else
      rm -f "$out_file" || { warn "could not remove existing $out_file"; return 1; }
    fi
  fi

  info "Converting: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: afconvert'
    for tok in "${AF_ARGS[@]}"; do printf ' %s' "$tok"; done
    printf ' %q %q\n' "$in_file" "$out_file"
    return 0
  fi

  local cmd=(afconvert)
  if [ "${#AF_ARGS[@]}" -gt 0 ]; then
    cmd+=( "${AF_ARGS[@]}" )
  fi
  cmd+=( "$in_file" "$out_file" )

  debug "Running: $(printf '%s ' "${cmd[@]}" | sed -E 's/[[:space:]]+$//')"

  if "${cmd[@]}"; then
    apply_metadata_to_m4a "$in_file" "$out_file"
    info "  -> OK"
    return 0
  else
    err "  -> ERROR converting $in_file"
    [ -e "$out_file" ] && rm -f "$out_file"
    return 1
  fi
}

###############################################################################
# CUE sheet detection and handling
###############################################################################
find_cue_file() {
  local srcfile="$1"
  local cue_candidate1="${srcfile%.flac}.cue"
  local cue_candidate2="${srcfile}.cue"

  if [ -f "$cue_candidate1" ]; then
    echo "$cue_candidate1"
    return 0
  elif [ -f "$cue_candidate2" ]; then
    echo "$cue_candidate2"
    return 0
  fi
  
  echo ""
  return 1
}

split_with_xld() {
  local srcfile="$1"
  local cue_file="$2"
  local destdir="$3"
  local relpath="$4"

  if [ "$XLD_PRESENT" != "yes" ]; then
    warn "Found cue sheet for $srcfile but XLD not available; performing regular single-file conversion."
    return 1
  fi

  info "Detected CUE for image: ${relpath} -> splitting into tracks with XLD"

  local TMPD
  TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
  if [ -z "$TMPD" ]; then
    warn "could not create temp dir; skipping cue split for $srcfile"
    return 1
  fi

  local XLD_LOG="$TMPD/xld.log"
  debug "Running XLD to split: (cd $TMPD && xld -c $cue_file -f flac $srcfile >$XLD_LOG 2>&1)"
  
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: (cd %s && xld -c %q -f flac %q)\n' "$TMPD" "$cue_file" "$srcfile"
    rm -rf "$TMPD" || true
    return 0
  fi

  ( cd "$TMPD" && xld -c "$cue_file" -f flac "$srcfile" >"$XLD_LOG" 2>&1 )
  local XLD_RC=$?

  if [ $XLD_RC -ne 0 ]; then
    if [ -s "$XLD_LOG" ]; then
      warn "XLD failed (exit $XLD_RC) while splitting $cue_file; falling back to single-file conversion for $srcfile. XLD log (last lines):"
      while IFS= read -r line; do warn "  $line"; done < <(tail -n 10 "$XLD_LOG" 2>/dev/null)
    else
      warn "XLD failed (exit $XLD_RC) while splitting $cue_file; no xld.log produced. Falling back to single-file conversion for $srcfile"
    fi
    rm -rf "$TMPD" || true
    return 1
  fi

  find "$TMPD" -maxdepth 1 -type f \( -iname '*.flac' \) -print0 | while IFS= read -r -d '' trackfile; do
    convert_to_m4a "$trackfile" "$destdir"
  done

  rm -rf "$TMPD" || true
  return 0
}

###############################################################################
# File processing
###############################################################################
process_flac_file() {
  local srcfile="$1"
  local relpath destdir base name destfile

  if [[ "$srcfile" == "$SRC/"* ]]; then
    relpath="${srcfile:$(( ${#SRC} + 1 ))}"
  else
    relpath="$srcfile"
  fi

  local dirpart="$(dirname "$relpath")"
  base="$(basename "$relpath")"
  name="${base%.*}"

  if [ "$dirpart" = "." ]; then
    destdir="$DEST"
  else
    destdir="$DEST/$dirpart"
  fi

  mkdir -p "$destdir" || { warn "could not create $destdir"; return 1; }
  destfile="$destdir/$name.m4a"

  local cue_file
  cue_file="$(find_cue_file "$srcfile")"

  if [ -n "$cue_file" ]; then
    debug "Found cue sheet: $cue_file"
    if split_with_xld "$srcfile" "$cue_file" "$destdir" "$relpath"; then
      return 0
    fi
  fi

  if [ -e "$destfile" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $destfile"
      return 0
    else
      rm -f "$destfile" || { warn "could not remove existing $destfile"; return 1; }
    fi
  fi

  convert_to_m4a "$srcfile" "$destdir"
}

process_all_files() {
  local error_count=0
  
  while IFS= read -r -d '' srcfile; do
    if ! process_flac_file "$srcfile"; then
      ((error_count++))
    fi
  done < <(find "$SRC" -type f -iname '*.flac' -print0)

  return $error_count
}

###############################################################################
# Main execution
###############################################################################
main() {
  init_colors
  parse_arguments "$@"
  check_system_requirements
  check_optional_tools
  validate_paths
  setup_afconvert_args
  print_settings

  local exit_code=0
  if ! process_all_files; then
    exit_code=1
  fi

  info "All done."
  exit $exit_code
}

main "$@"