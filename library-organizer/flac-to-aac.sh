#!/usr/bin/env bash
# flac-to-aac.sh - macOS: recursively convert .flac -> AAC (.m4a) using afconvert
#
# This script recursively converts FLAC audio files to AAC format (.m4a) using
# macOS's native afconvert tool. It supports:
# - Metadata preservation (via metaflac and AtomicParsley)
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
SPLIT_ONLY="no"       # Only split FLAC images, don't convert to AAC
# Default afconvert arguments: m4af container, AAC codec, 192kbps, quality 127 and VBR_constrained
DEFAULT_AF_ARGS=( -f m4af -d "aac" -b 192000 -q 127 -s 2 )
declare -a AF_ARGS  # Array to hold afconvert arguments

###############################################################################
# Initialization functions
###############################################################################

# Initialize color codes for terminal output
# Sets RED, ORANGE, and RESET variables based on terminal capabilities
# Disables colors if stderr is not a TTY
init_colors() {
  RESET=""
  # Try to use tput for reliable color codes
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  # Use 256-color codes if terminal supports it
  if [[ "${TERM:-}" == *256color* ]]; then
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      # Fallback to ANSI codes if tput fails
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  # Disable colors if stderr is not a terminal
  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

# Normalize boolean values to "yes" or "no"
# Args:
#   $1 - Input value to normalize
# Returns:
#   "yes" for truthy values, "no" otherwise
normalize_bool() {
  case "$1" in
    yes|Yes|YES|y|Y|true|True|TRUE) echo "yes" ;;
    *) echo "no" ;;
  esac
}

###############################################################################
# Logging functions
###############################################################################

# Get current timestamp in YYYY-MM-DD HH:MM:SS format
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Log error message to stderr in red
# Args:
#   $* - Error message to log
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }

# Log warning message to stderr in orange
# Args:
#   $* - Warning message to log
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }

# Log info message to stdout
# Args:
#   $* - Info message to log
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }

# Log debug message to stdout if VERBOSE is enabled
# Args:
#   $* - Debug message to log
debug(){ if [ "$VERBOSE" = "yes" ]; then printf '%s DEBUG: %s\n' "$(time_stamp)" "$*"; fi }

###############################################################################
# Help and usage
###############################################################################

# Display usage information and exit
usage() {
  cat <<EOF
flac-to-aac.sh - convert .flac -> AAC (.m4a) (macOS afconvert)

Usage:
  $(basename "$0") [options] /path/to/source /path/to/destination

Flags:
  -h, --help      show this help and exit
  --force         overwrite existing destination files (equivalent to SKIP_EXISTING=no)
  --dry-run       show actions without running afconvert (equivalent to DRY_RUN=yes)
  --split-only    only split FLAC images using CUE sheets, output FLAC tracks
                  (no AAC conversion). Tracks are placed in destination with
                  same structure as if they were converted to AAC.

Environment:
  AF_OPTS         optional extra afconvert options (whitespace-separated tokens)
                  Example: AF_OPTS='-f mp4f -d "aacf@24000" -b 256000 -q 127' ./flac-to-aac.sh src dest
                  (ignored when --split-only is used)
  SKIP_EXISTING   ${SKIP_EXISTING}
  VERBOSE         ${VERBOSE}
  DRY_RUN         ${DRY_RUN}
  SPLIT_ONLY      ${SPLIT_ONLY}

Default encoding (change AF_OPTS to override, not used with --split-only):
  ${DEFAULT_AF_ARGS[*]}

Examples:
  # Normal conversion
  $(basename "$0") /music/flac /music/aac

  # Split FLAC images only, no conversion
  $(basename "$0") --split-only /music/images /music/split_flac

  # Dry run to see what would happen
  $(basename "$0") --dry-run --split-only /music/images /music/split_flac
EOF
}

###############################################################################
# Argument parsing
###############################################################################

# Parse command-line arguments and set global variables
# Args:
#   $@ - All command-line arguments
# Sets:
#   SRC - Source directory path
#   DEST - Destination directory path
#   SKIP_EXISTING - Whether to skip existing files
#   DRY_RUN - Whether to run in dry-run mode
#   VERBOSE - Whether to enable verbose output
#   SPLIT_ONLY - Whether to only split without converting
parse_arguments() {
  declare -a POSITIONAL=()
  local FORCE_FROM_CLI="no"

  # Parse flags and options
  while (( "$#" )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --force) FORCE_FROM_CLI="yes"; shift ;;
      --dry-run) DRY_RUN="yes"; shift ;;
      --split-only) SPLIT_ONLY="yes"; shift ;;
      --) shift; break ;;
      -*)
        err "Unknown option: $1"
        usage
        exit 2
        ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done

  # Restore positional arguments
  set -- "${POSITIONAL[@]:-}"

  # Validate that exactly 2 positional arguments were provided
  if [ "${#}" -ne 2 ]; then
    err "source and destination required."
    usage
    exit 2
  fi

  SRC="$1"
  DEST="$2"

  # Apply --force flag
  if [ "$FORCE_FROM_CLI" = "yes" ]; then
    SKIP_EXISTING="no"
  fi

  # Normalize boolean environment variables
  SKIP_EXISTING="$(normalize_bool "$SKIP_EXISTING")"
  DRY_RUN="$(normalize_bool "$DRY_RUN")"
  VERBOSE="$(normalize_bool "$VERBOSE")"
  SPLIT_ONLY="$(normalize_bool "$SPLIT_ONLY")"
}

###############################################################################
# System checks
###############################################################################

# Check that the system meets requirements (macOS with afconvert)
# Exits with error code if requirements not met
check_system_requirements() {
  # Verify we're running on macOS
  if [ "$(uname -s)" != "Darwin" ]; then
    if [ "$SPLIT_ONLY" = "yes" ]; then
      # In split-only mode, we don't need afconvert
      debug "Not on macOS, but --split-only mode doesn't require afconvert"
    else
      err "afconvert is macOS-only. This script requires macOS (Darwin)."
      exit 5
    fi
  # Verify afconvert is available (unless in split-only mode)
  elif [ "$SPLIT_ONLY" = "no" ] && ! command -v afconvert >/dev/null 2>&1; then
    err "afconvert not found in PATH. Ensure you're on macOS and Xcode (or Command Line Tools) is installed."
    exit 6
  fi
}

# Check for optional tools (metaflac, AtomicParsley, xld)
# Sets:
#   MISSING_META_TOOLS - Space-separated list of missing metadata tools
#   XLD_PRESENT - "yes" if XLD is available, "no" otherwise
check_optional_tools() {
  MISSING_META_TOOLS=""
  
  # In split-only mode, we don't need metadata tools for AAC
  if [ "$SPLIT_ONLY" = "no" ]; then
    # Check for metaflac (FLAC metadata tool)
    if ! command -v metaflac >/dev/null 2>&1; then 
      MISSING_META_TOOLS="$MISSING_META_TOOLS metaflac"
    fi
    
    # Check for AtomicParsley (MP4/M4A metadata tool)
    if ! command -v AtomicParsley >/dev/null 2>&1; then 
      MISSING_META_TOOLS="$MISSING_META_TOOLS AtomicParsley"
    fi
    
    # Warn if metadata tools are missing
    if [ -n "$MISSING_META_TOOLS" ]; then
      warn "metadata copying will be skipped or limited because the following tools are missing:$MISSING_META_TOOLS"
    fi
  fi

  # Check for XLD (X Lossless Decoder for CUE sheet splitting)
  XLD_PRESENT="no"
  if command -v xld >/dev/null 2>&1; then
    XLD_PRESENT="yes"
  else
    if [ "$SPLIT_ONLY" = "yes" ]; then
      err "XLD not found. --split-only mode requires XLD to be installed."
      exit 7
    else
      warn "XLD not found. Cue-based splitting will be skipped; single-file conversion only."
    fi
  fi
}

# Validate source and destination paths
# Exits with error if source doesn't exist or destination can't be created
# Sets:
#   SRC - Normalized source path (trailing slash removed)
validate_paths() {
  # Check source directory exists
  if [ ! -d "$SRC" ]; then
    err "source directory does not exist: $SRC"
    exit 3
  fi
  
  # Create destination directory if it doesn't exist
  mkdir -p "$DEST" || { err "cannot create destination: $DEST"; exit 4; }
  
  # Remove trailing slash from source path
  SRC="${SRC%/}"
}

###############################################################################
# Configuration
###############################################################################

# Setup afconvert arguments from environment or defaults
# Sets:
#   AF_ARGS - Array of arguments to pass to afconvert
setup_afconvert_args() {
  # Skip if in split-only mode
  if [ "$SPLIT_ONLY" = "yes" ]; then
    AF_ARGS=()
    return
  fi

  : "${AF_OPTS:=}"
  
  # Use custom AF_OPTS if provided, otherwise use defaults
  if [ -n "${AF_OPTS}" ]; then
    eval "AF_ARGS=($AF_OPTS)"
    debug "Using custom AF_OPTS: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
    debug "Remember that default is: $(printf '%s ' "${DEFAULT_AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
  else
    AF_ARGS=( "${DEFAULT_AF_ARGS[@]}" )
  fi
}

# Print current settings to stdout
print_settings() {
  info "Settings summary:"
  info "  Source:        $SRC"
  info "  Destination:   $DEST"
  info "  Mode:          $([ "$SPLIT_ONLY" = "yes" ] && echo "SPLIT ONLY (FLAC)" || echo "Convert to AAC")"
  if [ "$SPLIT_ONLY" = "no" ]; then
    debug "  afconvert args: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
  fi
  info "  SKIP_EXISTING: $SKIP_EXISTING"
  info "  DRY_RUN:       $DRY_RUN"
  info "  VERBOSE:       $VERBOSE"
  info ""
}

###############################################################################
# Metadata handling
###############################################################################

# Apply metadata from FLAC to M4A file using metaflac and AtomicParsley
# Args:
#   $1 - Input FLAC file path
#   $2 - Output M4A file path
# Returns:
#   0 always (failures are logged but don't stop processing)
apply_metadata_to_m4a() {
  local in_file="$1"
  local out_file="$2"

  # Skip if required tools are not available
  if ! command -v metaflac >/dev/null 2>&1 || ! command -v AtomicParsley >/dev/null 2>&1; then
    debug "metaflac or AtomicParsley not available; skipping metadata copy for $out_file"
    return 0
  fi

  # Only process FLAC files
  case "${in_file##*/}" in
    *.flac|*.FLAC) ;;
    *)
      debug "Input not FLAC; skipping metaflac-based metadata copy for $in_file"
      return 0
      ;;
  esac

  # Create temporary directory for metadata extraction
  local TMPD2
  TMPD2="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
  if [ -z "$TMPD2" ]; then
    return 0
  fi

  local metafile="$TMPD2/meta.txt"
  local ap_args=()

  # Export FLAC metadata tags to text file
  if metaflac --export-tags-to="$metafile" "$in_file" 2>/dev/null; then
    # Use associative arrays (if bash 4+) or just variables to collect tags for track/disc pairing
    local track_num="" track_total=""
    local disc_num="" disc_total=""
    local year="" date="" original_date=""

    # Parse metadata file
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      local key="${line%%=*}"
      local val="${line#*=}"
      local upper_key
      upper_key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
      
      # Map FLAC tags to M4A tags
      case "$upper_key" in
        TITLE) ap_args+=( --title "$val" ) ;;
        ARTIST) ap_args+=( --artist "$val" ) ;;
        ALBUM) ap_args+=( --album "$val" ) ;;
        ALBUMARTIST) ap_args+=( --albumArtist "$val" ) ;;
        COMPOSER) ap_args+=( --composer "$val" ) ;;
        GENRE) ap_args+=( --genre "$val" ) ;;
        COMMENT) ap_args+=( --comment "$val" ) ;;
        LYRICS) ap_args+=( --lyrics "$val" ) ;;
        COPYRIGHT) ap_args+=( --copyright "$val" ) ;;
        ENCODEDBY) ap_args+=( --encodedBy "$val" ) ;;
        GROUPING) ap_args+=( --grouping "$val" ) ;;
        
        # Track and Disc numbers (collect for pairing)
        TRACKNUMBER) track_num="$val" ;;
        TRACKTOTAL|TOTALTRACKS) track_total="$val" ;;
        DISCNUMBER) disc_num="$val" ;;
        DISCTOTAL|TOTALDISCS) disc_total="$val" ;;
        
        # Date handling
        DATE) date="$val" ;;
        YEAR) year="$val" ;;
        ORIGINALDATE) original_date="$val" ;;

        # Extended/Special tags using rDNS
        ARTISTSORT) ap_args+=( --rDNSatom "$val" name="ARTISTSORT" domain="com.apple.iTunes" ) ;;
        ALBUMARTISTSORT) ap_args+=( --rDNSatom "$val" name="ALBUMARTISTSORT" domain="com.apple.iTunes" ) ;;
        ALBUMSORT) ap_args+=( --rDNSatom "$val" name="ALBUMSORT" domain="com.apple.iTunes" ) ;;
        TITLESORT) ap_args+=( --rDNSatom "$val" name="TITLESORT" domain="com.apple.iTunes" ) ;;
        COMPOSERSORT) ap_args+=( --rDNSatom "$val" name="COMPOSERSORT" domain="com.apple.iTunes" ) ;;
        
        ISRC) ap_args+=( --rDNSatom "$val" name="ISRC" domain="com.apple.iTunes" ) ;;
        LABEL|ORGANIZATION|PUBLISHER) ap_args+=( --rDNSatom "$val" name="LABEL" domain="com.apple.iTunes" ) ;;
        BARCODE) ap_args+=( --rDNSatom "$val" name="BARCODE" domain="com.apple.iTunes" ) ;;
        CATALOGNUMBER) ap_args+=( --rDNSatom "$val" name="CATALOGNUMBER" domain="com.apple.iTunes" ) ;;
        
        # MusicBrainz IDs
        MUSICBRAINZ_TRACKID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Track Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ALBUMID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Album Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ARTISTID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Artist Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_ALBUMARTISTID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Album Artist Id" domain="com.apple.iTunes" ) ;;
        MUSICBRAINZ_RELEASEGROUPID) ap_args+=( --rDNSatom "$val" name="MusicBrainz Release Group Id" domain="com.apple.iTunes" ) ;;
      esac
    done < "$metafile"

    # Assemble track and disc strings (X/Y format)
    if [ -n "$track_num" ]; then
      if [ -n "$track_total" ]; then
        ap_args+=( --tracknum "$track_num/$track_total" )
      else
        ap_args+=( --tracknum "$track_num" )
      fi
    fi
    if [ -n "$disc_num" ]; then
      if [ -n "$disc_total" ]; then
        ap_args+=( --disk "$disc_num/$disc_total" )
      else
        ap_args+=( --disk "$disc_num" )
      fi
    fi

    # Pick the best date available
    local final_date=""
    if [ -n "$original_date" ]; then final_date="$original_date";
    elif [ -n "$date" ]; then final_date="$date";
    elif [ -n "$year" ]; then final_date="$year"; fi
    [ -n "$final_date" ] && ap_args+=( --year "$final_date" )

    # Extract and include album artwork if present
    local picfile="$TMPD2/cover"
    if metaflac --export-picture-to="$picfile" "$in_file" 2>/dev/null; then
      local picfile_ext
      
      # Detect image format and add appropriate extension
      if command -v file >/dev/null 2>&1; then
        local ftype
        ftype="$(file --brief --mime-type "$picfile" 2>/dev/null || echo "image/jpeg")"
        case "$ftype" in
          image/png) picfile_ext="${picfile}.png" ;;
          image/jpeg) picfile_ext="${picfile}.jpg" ;;
          image/*) picfile_ext="${picfile}.img" ;;
          *) picfile_ext="${picfile}.jpg" ;;
        esac
        mv "$picfile" "$picfile_ext" 2>/dev/null || true
      else
        # Default to JPEG if 'file' command not available
        picfile_ext="${picfile}.jpg"
        mv "$picfile" "$picfile_ext" 2>/dev/null || true
      fi
      ap_args+=( --artwork "$picfile_ext" )
    fi

    # Apply metadata to M4A file if we have any tags to write
    if [ "${#ap_args[@]}" -gt 0 ]; then
      debug "Applying metadata with AtomicParsley: $(printf '%s ' "${ap_args[@]}" | sed -E 's/[[:space:]]+$//')"
      if AtomicParsley "$out_file" "${ap_args[@]}" --overWrite >/dev/null 2>&1; then
        debug "Metadata written to $out_file"
      else
        warn "AtomicParsley failed to write metadata to $out_file"
      fi
    fi
  fi

  # Clean up temporary directory
  if [ -n "$TMPD2" ] && [ -d "$TMPD2" ]; then
    rm -rf "$TMPD2" || true
  fi
}

###############################################################################
# Core conversion functions
###############################################################################

# Convert a single audio file to M4A using afconvert
# Args:
#   $1 - Input file path
#   $2 - Output directory path
# Returns:
#   0 on success, 1 on failure
convert_to_m4a() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local name="${base%.*}"
  local out_file="$out_dir/$name.m4a"

  # Handle existing output file
  if [ -e "$out_file" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $out_file"
      return 0
    else
      rm -f "$out_file" || { warn "could not remove existing $out_file"; return 1; }
    fi
  fi

  info "Converting: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  
  # In dry-run mode, just show the command that would be executed
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: afconvert'
    for tok in "${AF_ARGS[@]}"; do printf ' %s' "$tok"; done
    printf ' %q %q\n' "$in_file" "$out_file"
    return 0
  fi

  # Build afconvert command
  local cmd=(afconvert)
  if [ "${#AF_ARGS[@]}" -gt 0 ]; then
    cmd+=( "${AF_ARGS[@]}" )
  fi
  cmd+=( "$in_file" "$out_file" )

  debug "Running: $(printf '%s ' "${cmd[@]}" | sed -E 's/[[:space:]]+$//')"

  # Execute conversion
  if "${cmd[@]}"; then
    # Apply metadata after successful conversion
    apply_metadata_to_m4a "$in_file" "$out_file"
    info "  -> OK"
    return 0
  else
    err "  -> ERROR converting $in_file"
    # Remove partial output file on failure
    [ -e "$out_file" ] && rm -f "$out_file"
    return 1
  fi
}

# Copy a FLAC file to destination (for split-only mode)
# Args:
#   $1 - Input FLAC file path
#   $2 - Output directory path
# Returns:
#   0 on success, 1 on failure
copy_flac_file() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local out_file="$out_dir/$base"

  # Handle existing output file
  if [ -e "$out_file" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $out_file"
      return 0
    else
      rm -f "$out_file" || { warn "could not remove existing $out_file"; return 1; }
    fi
  fi

  info "Copying: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  
  # In dry-run mode, just show the command that would be executed
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: cp %q %q\n' "$in_file" "$out_file"
    return 0
  fi

  # Copy the file
  if cp "$in_file" "$out_file"; then
    info "  -> OK"
    return 0
  else
    err "  -> ERROR copying $in_file"
    return 1
  fi
}

###############################################################################
# CUE sheet detection and handling
###############################################################################

# Find CUE sheet file associated with a FLAC file
# Args:
#   $1 - FLAC file path
# Returns:
#   Prints path to CUE file if found, empty string otherwise
#   Exit code 0 if found, 1 if not found
find_cue_file() {
  local srcfile="$1"
  local base_name="${srcfile%.flac}"
  
  # Try multiple CUE file naming patterns:
  # 1. filename.cue (e.g., "album.cue" for "album.flac")
  local cue_candidate1="${base_name}.cue"
  # 2. filename.flac.cue (e.g., "album.flac.cue")
  local cue_candidate2="${srcfile}.cue"
  # 3. filename FLAC.cue (e.g., "album FLAC.cue" for "album.flac")
  local cue_candidate3="${base_name} FLAC.cue"
  # 4. filename flac.cue (lowercase variant)
  local cue_candidate4="${base_name} flac.cue"

  if [ -f "$cue_candidate1" ]; then
    echo "$cue_candidate1"
    return 0
  elif [ -f "$cue_candidate2" ]; then
    echo "$cue_candidate2"
    return 0
  elif [ -f "$cue_candidate3" ]; then
    echo "$cue_candidate3"
    return 0
  elif [ -f "$cue_candidate4" ]; then
    echo "$cue_candidate4"
    return 0
  fi
  
  echo ""
  return 1
}

# Split a FLAC image file using XLD based on a CUE sheet
# Args:
#   $1 - Source FLAC file path
#   $2 - CUE sheet file path
#   $3 - Destination directory
#   $4 - Relative path (for logging)
# Returns:
#   0 on success, 1 on failure (falls back to single-file conversion)
split_with_xld() {
  local srcfile="$1"
  local cue_file="$2"
  local destdir="$3"
  local relpath="$4"

  # Check if XLD is available
  if [ "$XLD_PRESENT" != "yes" ]; then
    warn "Found cue sheet for $srcfile but XLD not available; performing regular single-file conversion."
    return 1
  fi

  info "Detected CUE for image: ${relpath} -> splitting into tracks with XLD"

  # Create temporary directory for XLD output
  local TMPD
  TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
  if [ -z "$TMPD" ]; then
    warn "could not create temp dir; skipping cue split for $srcfile"
    return 1
  fi

  local XLD_LOG="$TMPD/xld.log"
  debug "Running XLD to split: (cd $TMPD && xld -c $cue_file -f flac $srcfile >$XLD_LOG 2>&1)"
  
  # In dry-run mode, just show the command
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  -> DRY RUN: (cd %s && xld -c %q -f flac %q)\n' "$TMPD" "$cue_file" "$srcfile"
    rm -rf "$TMPD" || true
    return 0
  fi

  # Run XLD to split FLAC image into individual tracks
  ( cd "$TMPD" && xld -c "$cue_file" -f flac "$srcfile" >"$XLD_LOG" 2>&1 )
  local XLD_RC=$?

  # Check if XLD succeeded
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

  # Process each split track
  find "$TMPD" -maxdepth 1 -type f \( -iname '*.flac' \) -print0 | while IFS= read -r -d '' trackfile; do
    if [ "$SPLIT_ONLY" = "yes" ]; then
      # In split-only mode, copy FLAC files
      copy_flac_file "$trackfile" "$destdir"
    else
      # Normal mode: convert to M4A
      convert_to_m4a "$trackfile" "$destdir"
    fi
  done

  # Clean up temporary directory
  rm -rf "$TMPD" || true
  return 0
}

###############################################################################
# File processing
###############################################################################

# Process a single FLAC file (with CUE sheet detection)
# Args:
#   $1 - Source FLAC file path
# Returns:
#   0 on success, 1 on failure
process_flac_file() {
  local srcfile="$1"
  local relpath destdir base name destfile

  # Calculate relative path from source directory
  if [[ "$srcfile" == "$SRC/"* ]]; then
    relpath="${srcfile:$(( ${#SRC} + 1 ))}"
  else
    relpath="$srcfile"
  fi

  # Determine output directory and file name
  local dirpart="$(dirname "$relpath")"
  base="$(basename "$relpath")"
  name="${base%.*}"

  if [ "$dirpart" = "." ]; then
    destdir="$DEST"
  else
    destdir="$DEST/$dirpart"
  fi

  # Create output directory
  mkdir -p "$destdir" || { warn "could not create $destdir"; return 1; }
  
  # Determine output file extension
  local out_ext
  if [ "$SPLIT_ONLY" = "yes" ]; then
    out_ext="flac"
  else
    out_ext="m4a"
  fi
  destfile="$destdir/$name.$out_ext"

  # Check for associated CUE sheet
  local cue_file
  cue_file="$(find_cue_file "$srcfile")"

  # If CUE sheet exists, try splitting with XLD
  if [ -n "$cue_file" ]; then
    debug "Found cue sheet: $cue_file"
    if split_with_xld "$srcfile" "$cue_file" "$destdir" "$relpath"; then
      return 0
    fi
    # If XLD split fails, fall through to single-file conversion/copy
  fi

  # Handle existing output file (for single-file processing)
  if [ -e "$destfile" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $destfile"
      return 0
    else
      rm -f "$destfile" || { warn "could not remove existing $destfile"; return 1; }
    fi
  fi

  # Process single FLAC file
  if [ "$SPLIT_ONLY" = "yes" ]; then
    # In split-only mode without CUE, just copy the file
    copy_flac_file "$srcfile" "$destdir"
  else
    # Normal mode: convert to M4A
    convert_to_m4a "$srcfile" "$destdir"
  fi
}

# Process all FLAC files in the source directory recursively
# Returns:
#   Number of files that failed to convert
process_all_files() {
  local error_count=0
  
  # Find all FLAC files and process them
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

# Main entry point
# Args:
#   $@ - All command-line arguments
# Returns:
#   0 on success, 1 if any files failed to convert
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

# Execute main function with all arguments
main "$@"