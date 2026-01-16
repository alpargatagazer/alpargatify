#!/usr/bin/env bash
# flac-to-lossy.sh - recursively convert .flac -> Lossy (Opus/AAC)
#
# This script recursively converts FLAC audio files to lossy formats.
# Supports:
# - Opus (via opusenc, default)
# - AAC (via macOS afconvert)
# - Metadata preservation
# - CUE sheet splitting (via XLD)
# - Split-only mode (--split-only flag)
# - Configurable encoding parameters
# - Dry-run mode for testing

set -u              # Exit on undefined variables
set -o pipefail     # Exit on pipe failures
IFS=$'\n\t'         # Set Internal Field Separator to newline and tab

# Ensure UTF-8 locale for filename and metadata handling
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

###############################################################################
# Global variables
###############################################################################
RED=""                # ANSI color code for error messages
ORANGE=""             # ANSI color code for warning messages
RESET=""              # ANSI color code to reset formatting
MISSING_META_TOOLS="" # List of missing metadata tools
XLD_PRESENT="no"      # Flag indicating if XLD is available
SKIP_EXISTING="yes"   # Skip conversion if output file exists
VERBOSE="no"          # Enable verbose debug output
DRY_RUN="no"          # Show actions without executing them
SPLIT_ONLY="no"       # Only split FLAC images, don't convert
COPY_COVERS="yes"     # Copy cover art images by default
STRIP_REPLAYGAIN="yes" # Strip ReplayGain tags before conversion
METAFLAC_PRESENT="no" # Flag indicating if metaflac is available

# Default settings
FORMAT="opus"         # Default format: opus
BITRATE="256"         # Default bitrate: 256kbps

# Default encoding parameters
DEFAULT_OPUS_ARGS=( --bitrate "${BITRATE}" --vbr --music )
# Default afconvert arguments: m4af container, AAC codec, bitrate, quality 127 and VBR_constrained
DEFAULT_AAC_ARGS=( -f m4af -d "aac" -b 256000 -q 127 -s 2 )

declare -a ENCODE_ARGS  # Array to hold encoding arguments

###############################################################################
# Initialization functions
###############################################################################

# Initialize color codes for terminal output
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
flac-to-lossy.sh - convert .flac -> Lossy (Opus/AAC)

Usage:
  $(basename "$0") [options] /path/to/source /path/to/destination

Flags:
  -h, --help      show this help and exit
  --format FMT    output format: opus (default) or aac
  --bitrate N     bitrate in kbps (default: ${BITRATE})
  --force         overwrite existing destination files (equivalent to SKIP_EXISTING=no)
  --dry-run       show actions without running conversion (equivalent to DRY_RUN=yes)
  --split-only    only split FLAC images using CUE sheets, output FLAC tracks
                  (no conversion). Tracks are placed in destination with
                  same structure as if they were converted.
  --no-cover      do not copy cover art images (cover.jpg, front.png, etc.)
  --keep-replaygain  do not strip ReplayGain tags before conversion

Environment:
  ENCODE_OPTS     optional extra encoding options (whitespace-separated tokens)
                  Example: ENCODE_OPTS='--vbr --framesize 20' ./flac-to-lossy.sh src dest
                  (ignored when --split-only is used)
  SKIP_EXISTING   ${SKIP_EXISTING}
  VERBOSE         ${VERBOSE}
  DRY_RUN         ${DRY_RUN}
  SPLIT_ONLY      ${SPLIT_ONLY}
  COPY_COVERS     ${COPY_COVERS}
  STRIP_REPLAYGAIN ${STRIP_REPLAYGAIN}

Default encoding (for Opus):
  opusenc ${DEFAULT_OPUS_ARGS[*]}

Default encoding (for AAC - macOS only):
  afconvert ${DEFAULT_AAC_ARGS[*]}
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
      --format) FORMAT="$2"; shift 2 ;;
      --bitrate) BITRATE="$2"; shift 2 ;;
      --force) FORCE_FROM_CLI="yes"; shift ;;
      --dry-run) DRY_RUN="yes"; shift ;;
      --split-only) SPLIT_ONLY="yes"; shift ;;
      --no-cover) COPY_COVERS="no"; shift ;;
      --keep-replaygain) STRIP_REPLAYGAIN="no"; shift ;;
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
  SPLIT_ONLY="$(normalize_bool "$SPLIT_ONLY")"
  COPY_COVERS="$(normalize_bool "$COPY_COVERS")"
  STRIP_REPLAYGAIN="$(normalize_bool "$STRIP_REPLAYGAIN")"
  
  # Normalize format
  case "$(echo "$FORMAT" | tr '[:upper:]' '[:lower:]')" in
    opus) FORMAT="opus" ;;
    aac|m4a) FORMAT="aac" ;;
    *) err "Unsupported format: $FORMAT. Use 'opus' or 'aac'."; exit 2 ;;
  esac
}

###############################################################################
# System checks
###############################################################################

check_system_requirements() {
  if [ "$SPLIT_ONLY" = "yes" ]; then
    return
  fi

  if [ "$FORMAT" = "aac" ]; then
    if [ "$(uname -s)" != "Darwin" ]; then
      err "AAC conversion via afconvert requires macOS (Darwin)."
      exit 5
    fi
    if ! command -v afconvert >/dev/null 2>&1; then
      err "afconvert not found. Ensure you're on macOS."
      exit 6
    fi
  elif [ "$FORMAT" = "opus" ]; then
    if ! command -v opusenc >/dev/null 2>&1 && ! command -v ffmpeg >/dev/null 2>&1; then
      err "Neither opusenc nor ffmpeg found. Required for Opus conversion."
      exit 6
    fi
  fi
}

check_optional_tools() {
  MISSING_META_TOOLS=""
  
  if [ "$SPLIT_ONLY" = "no" ]; then
    if [ "$FORMAT" = "aac" ]; then
      if ! command -v metaflac >/dev/null 2>&1; then MISSING_META_TOOLS="$MISSING_META_TOOLS metaflac"; fi
      if ! command -v AtomicParsley >/dev/null 2>&1; then MISSING_META_TOOLS="$MISSING_META_TOOLS AtomicParsley"; fi
    fi
    # Opusenc handles metadata internally well from flac files.
    
    if [ -n "$MISSING_META_TOOLS" ]; then
      warn "metadata copying will be limited because tools are missing:$MISSING_META_TOOLS"
    fi
  fi

  METAFLAC_PRESENT="no"
  if command -v metaflac >/dev/null 2>&1; then
    METAFLAC_PRESENT="yes"
  else
    if [ "$STRIP_REPLAYGAIN" = "yes" ]; then
      warn "metaflac not found. ReplayGain stripping will be skipped."
      STRIP_REPLAYGAIN="no"
    fi
  fi

  XLD_PRESENT="no"
  if command -v xld >/dev/null 2>&1; then
    XLD_PRESENT="yes"
  else
    if [ "$SPLIT_ONLY" = "yes" ]; then
      err "XLD not found. --split-only mode requires XLD."
      exit 7
    fi
    warn "XLD not found. Cue-based splitting will be skipped."
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

setup_encoding_args() {
  if [ "$SPLIT_ONLY" = "yes" ]; then
    ENCODE_ARGS=()
    return
  fi

  : "${ENCODE_OPTS:=}"
  
  if [ -n "${ENCODE_OPTS}" ]; then
    eval "ENCODE_ARGS=($ENCODE_OPTS)"
  else
    if [ "$FORMAT" = "opus" ]; then
      ENCODE_ARGS=( --bitrate "${BITRATE}" )
    else
      # AAC
      ENCODE_ARGS=( -f m4af -d "aac" -b $((BITRATE * 1000)) -q 127 -s 2 )
    fi
  fi
}

print_settings() {
  info "Settings summary:"
  info "  Source:        $SRC"
  info "  Destination:   $DEST"
  info "  Format:        $FORMAT"
  info "  Bitrate:       $BITRATE kbps"
  info "  Mode:          $([ "$SPLIT_ONLY" = "yes" ] && echo "SPLIT ONLY (FLAC)" || echo "Convert to $FORMAT")"
  info "  Copy Covers:   $COPY_COVERS"
  info "  Strip RG:      $STRIP_REPLAYGAIN"
  info "  SKIP_EXISTING: $SKIP_EXISTING"
  info "  DRY_RUN:       $DRY_RUN"
  info "  VERBOSE:       $VERBOSE"
  info ""
}

###############################################################################
# Metadata handling (for AAC/M4A)
###############################################################################

apply_metadata_to_m4a() {
  local in_file="$1"
  local out_file="$2"

  if ! command -v metaflac >/dev/null 2>&1 || ! command -v AtomicParsley >/dev/null 2>&1; then
    return 0
  fi

  local TMPD2
  TMPD2="$(mktemp -d 2>/dev/null || mktemp -d -t flac2lossy_tmp 2>/dev/null || true)"
  [ -z "$TMPD2" ] && return 0

  local metafile="$TMPD2/meta.txt"
  local ap_args=()

  if metaflac --export-tags-to="$metafile" "$in_file" 2>/dev/null; then
    local track_num="" track_total="" disc_num="" disc_total=""
    local year="" date="" original_date=""

    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      local key="${line%%=*}"
      local val="${line#*=}"
      local upper_key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
      
      case "$upper_key" in
        TITLE) ap_args+=( --title "$val" ) ;;
        ARTIST) ap_args+=( --artist "$val" ) ;;
        ALBUM) ap_args+=( --album "$val" ) ;;
        ALBUMARTIST) ap_args+=( --albumArtist "$val" ) ;;
        COMPOSER) ap_args+=( --composer "$val" ) ;;
        GENRE) ap_args+=( --genre "$val" ) ;;
        #COMMENT) ap_args+=( --comment "$val" ) ;;
        LYRICS) ap_args+=( --lyrics "$val" ) ;;
        COPYRIGHT) ap_args+=( --copyright "$val" ) ;;
        ENCODEDBY) ap_args+=( --encodedBy "$val" ) ;;
        GROUPING) ap_args+=( --grouping "$val" ) ;;
        TRACKNUMBER) track_num="$val" ;;
        TRACKTOTAL|TOTALTRACKS) track_total="$val" ;;
        DISCNUMBER) disc_num="$val" ;;
        DISCTOTAL|TOTALDISCS) disc_total="$val" ;;
        DATE) date="$val" ;;
        YEAR) year="$val" ;;
        ORIGINALDATE) original_date="$val" ;;
        ARTISTSORT) ap_args+=( --rDNSatom "$val" name="ARTISTSORT" domain="com.apple.iTunes" ) ;;
        ALBUMARTISTSORT) ap_args+=( --rDNSatom "$val" name="ALBUMARTISTSORT" domain="com.apple.iTunes" ) ;;
        ALBUMSORT) ap_args+=( --rDNSatom "$val" name="ALBUMSORT" domain="com.apple.iTunes" ) ;;
        TITLESORT) ap_args+=( --rDNSatom "$val" name="TITLESORT" domain="com.apple.iTunes" ) ;;
        COMPOSERSORT) ap_args+=( --rDNSatom "$val" name="COMPOSERSORT" domain="com.apple.iTunes" ) ;;
        ISRC) ap_args+=( --rDNSatom "$val" name="ISRC" domain="com.apple.iTunes" ) ;;
        LABEL|ORGANIZATION|PUBLISHER) ap_args+=( --rDNSatom "$val" name="LABEL" domain="com.apple.iTunes" ) ;;
        BARCODE) ap_args+=( --rDNSatom "$val" name="BARCODE" domain="com.apple.iTunes" ) ;;
        CATALOGNUMBER) ap_args+=( --rDNSatom "$val" name="CATALOGNUMBER" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_TRACKID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Track Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ALBUMID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Album Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ARTISTID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Artist Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ALBUMARTISTID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Album Artist Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_RELEASEGROUPID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Release Group Id" domain="com.apple.iTunes" ) ;;
      esac
    done < "$metafile"

    [ -n "$track_num" ] && [ -n "$track_total" ] && ap_args+=( --tracknum "$track_num/$track_total" ) || { [ -n "$track_num" ] && ap_args+=( --tracknum "$track_num" ); }
    [ -n "$disc_num" ] && [ -n "$disc_total" ] && ap_args+=( --disk "$disc_num/$disc_total" ) || { [ -n "$disc_num" ] && ap_args+=( --disk "$disc_num" ); }

    local final_date=""
    if [ -n "$original_date" ]; then final_date="$original_date"; elif [ -n "$date" ]; then final_date="$date"; elif [ -n "$year" ]; then final_date="$year"; fi
    [ -n "$final_date" ] && ap_args+=( --year "$final_date" )

    local picfile="$TMPD2/cover"
    if metaflac --export-picture-to="$picfile" "$in_file" 2>/dev/null; then
      local picfile_ext="${picfile}.jpg"
      if command -v file >/dev/null 2>&1; then
        case "$(file --brief --mime-type "$picfile" 2>/dev/null)" in
          image/png) picfile_ext="${picfile}.png" ;;
          image/jpeg) picfile_ext="${picfile}.jpg" ;;
        esac
      fi
      mv "$picfile" "$picfile_ext" 2>/dev/null
      ap_args+=( --artwork "$picfile_ext" )
    fi

    if [ "${#ap_args[@]}" -gt 0 ]; then
      AtomicParsley "$out_file" "${ap_args[@]}" --overWrite >/dev/null 2>&1
    fi
  fi
  rm -rf "$TMPD2" || true
}

###############################################################################
# ReplayGain stripping
###############################################################################

# Strip ReplayGain tags from a FLAC file by creating a temporary copy
# Returns the path to the cleaned temp file, or the original file if stripping is disabled/failed
strip_replaygain_to_temp() {
  local in_file="$1"
  
  if [ "$STRIP_REPLAYGAIN" != "yes" ] || [ "$METAFLAC_PRESENT" != "yes" ]; then
    echo "$in_file"
    return 0
  fi

  # Create temp file
  local tmp_file
  tmp_file="$(mktemp -t flac_norga_XXXXXX.flac 2>/dev/null || mktemp /tmp/flac_norga_XXXXXX.flac 2>/dev/null || true)"
  
  if [ -z "$tmp_file" ]; then
    warn "Could not create temp file for ReplayGain stripping, using original"
    echo "$in_file"
    return 0
  fi

  # Copy the file
  cp "$in_file" "$tmp_file" 2>/dev/null || {
    warn "Could not copy file for ReplayGain stripping, using original"
    rm -f "$tmp_file" 2>/dev/null || true
    echo "$in_file"
    return 0
  }

  # Strip ReplayGain tags
  if metaflac --remove-replay-gain "$tmp_file" 2>/dev/null; then
    debug "Stripped ReplayGain from temp copy: $tmp_file"
    echo "$tmp_file"
    return 0
  else
    debug "No ReplayGain tags found or stripping failed, using original"
    rm -f "$tmp_file" 2>/dev/null || true
    echo "$in_file"
    return 0
  fi
}

###############################################################################
# Core conversion functions
###############################################################################

convert_to_lossy() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local name="${base%.*}"
  local out_ext="$([ "$FORMAT" = "opus" ] && echo "opus" || echo "m4a")"
  local out_file="$out_dir/$name.$out_ext"

  if [ -e "$out_file" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $out_file"
      return 0
    else
      rm -f "$out_file" || return 1
    fi
  fi

  info "Converting: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  
  # Strip ReplayGain if enabled (creates temp file)
  local encode_src="$in_file"
  local temp_stripped=""
  if [ "$STRIP_REPLAYGAIN" = "yes" ] && [ "$DRY_RUN" != "yes" ]; then
    encode_src="$(strip_replaygain_to_temp "$in_file")"
    if [ "$encode_src" != "$in_file" ]; then
      temp_stripped="$encode_src"
      debug "Using stripped temp file: $temp_stripped"
    fi
  elif [ "$STRIP_REPLAYGAIN" = "yes" ] && [ "$DRY_RUN" = "yes" ]; then
    info "  -> (would strip ReplayGain tags before encoding)"
  fi
  
  local cmd=()
  if [ "$FORMAT" = "opus" ]; then
    if command -v opusenc >/dev/null 2>&1; then
      cmd=(opusenc "${ENCODE_ARGS[@]}" "$encode_src" "$out_file")
    else
      # Fallback to ffmpeg
      cmd=(ffmpeg -i "$encode_src" -c:a libopus -b:a "${BITRATE}k" "$out_file")
    fi
  else
    # AAC
    cmd=(afconvert "${ENCODE_ARGS[@]}" "$encode_src" "$out_file")
  fi

  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: %s\n' "${cmd[*]}"
    return 0
  fi

  debug "Running: ${cmd[*]}"
  local convert_result=0
  if "${cmd[@]}" >/dev/null 2>&1; then
    if [ "$FORMAT" = "aac" ]; then
      apply_metadata_to_m4a "$in_file" "$out_file"
    fi
    info "  -> OK"
  else
    err "  -> ERROR converting $in_file"
    [ -e "$out_file" ] && rm -f "$out_file"
    convert_result=1
  fi

  # Cleanup temp file if we created one
  if [ -n "$temp_stripped" ] && [ -f "$temp_stripped" ]; then
    rm -f "$temp_stripped" 2>/dev/null || true
  fi

  return $convert_result
}

copy_flac_file() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local out_file="$out_dir/$base"

  if [ -e "$out_file" ] && [ "$SKIP_EXISTING" = "yes" ]; then
    return 0
  fi

  info "Copying: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: cp %q %q\n' "$in_file" "$out_file"
    return 0
  fi

  cp "$in_file" "$out_file" || return 1
}

copy_cover_art() {
  local src_dir="$1"
  local dest_dir="$2"

  if [ "$COPY_COVERS" != "yes" ]; then
    return 0
  fi

  # Priority list for cover art
  local candidates=("cover.jpg" "cover.png" "front.jpg" "front.png" "folder.jpg" "folder.png" "Cover.jpg" "Cover.png")

  for cand in "${candidates[@]}"; do
    local src_img="$src_dir/$cand"
    if [ -f "$src_img" ]; then
      local dest_img="$dest_dir/$cand"
      
      # If file exists in destination, skip (unless FORCE is implicitly handled by rm, 
      # but standard logic is SKIP_EXISTING. We can check SKIP_EXISTING here)
      if [ -e "$dest_img" ] && [ "$SKIP_EXISTING" = "yes" ]; then
        # Already exists, assume it's good
        return 0
      fi

      info "Copying cover: $cand"
      if [ "$DRY_RUN" = "yes" ]; then
        printf '  -> DRY RUN: cp %q %q\n' "$src_img" "$dest_img"
        return 0
      fi

      cp "$src_img" "$dest_img" || warn "Failed to copy cover art: $cand"
      return 0
    fi
  done
}

###############################################################################
# CUE sheet detection and handling
###############################################################################

find_cue_file() {
  local srcfile="$1"
  local base_name="${srcfile%.flac}"
  for cand in "${base_name}.cue" "${srcfile}.cue" "${base_name} FLAC.cue" "${base_name} flac.cue"; do
    if [ -f "$cand" ]; then echo "$cand"; return 0; fi
  done
  return 1
}

split_with_xld() {
  local srcfile="$1"
  local cue_file="$2"
  local destdir="$3"
  local relpath="$4"

  if [ "$XLD_PRESENT" != "yes" ]; then
    warn "Found cue for $srcfile but XLD not available; single-file conversion."
    return 1
  fi

  info "Detected CUE for image: ${relpath} -> splitting with XLD"
  local TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t flac2lossy_tmp 2>/dev/null || true)"
  [ -z "$TMPD" ] && return 1

  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: (cd %s && xld -c %q -f flac %q)\n' "$TMPD" "$cue_file" "$srcfile"
    rm -rf "$TMPD"
    return 0
  fi

  ( cd "$TMPD" && xld -c "$cue_file" -f flac "$srcfile" >/dev/null 2>&1 )
  if [ $? -ne 0 ]; then
    rm -rf "$TMPD"
    return 1
  fi

  find "$TMPD" -maxdepth 1 -type f \( -iname '*.flac' \) -print0 | while IFS= read -r -d '' trackfile; do
    if [ "$SPLIT_ONLY" = "yes" ]; then copy_flac_file "$trackfile" "$destdir"
    else convert_to_lossy "$trackfile" "$destdir"; fi
  done

  rm -rf "$TMPD"
  return 0
}

###############################################################################
# File processing
###############################################################################

process_flac_file() {
  local srcfile="$1"
  local relpath="${srcfile#$SRC/}"
  local dirpart="$(dirname "$relpath")"
  local base="$(basename "$relpath")"
  local name="${base%.*}"
  local destdir="$DEST/$dirpart"

  mkdir -p "$destdir" 2>/dev/null
  
  local cue_file="$(find_cue_file "$srcfile")"
  if [ -n "$cue_file" ]; then
    if split_with_xld "$srcfile" "$cue_file" "$destdir" "$relpath"; then return 0; fi
  fi

  # Attempt to copy cover art (will handle duplication checks internally)
  copy_cover_art "$(dirname "$srcfile")" "$destdir"

  if [ "$SPLIT_ONLY" = "yes" ]; then copy_flac_file "$srcfile" "$destdir"
  else convert_to_lossy "$srcfile" "$destdir"; fi
}

process_all_files() {
  local error_count=0
  while IFS= read -r -d '' srcfile; do
    process_flac_file "$srcfile" || ((error_count++))
  done < <(find "$SRC" -type f -iname '*.flac' ! -name '._*' -print0)
  return $error_count
}

main() {
  init_colors
  parse_arguments "$@"
  check_system_requirements
  check_optional_tools
  validate_paths
  setup_encoding_args
  print_settings

  local exit_code=0
  process_all_files || exit_code=1
  info "All done."
  exit $exit_code
}

main "$@"
