#!/usr/bin/env python3
"""normalize_dirs.py

Scan DEST tree for album directories (a directory containing audio files),
normalize album directory names and track filenames.

Usage (entrypoint passes these args):
  python3 normalize_dirs.py --source /data/Some/Path --dest /data/Some/Path [--dry-run]

Behavior summary (decisions enforced):
- Album directory name format:
    <Artist> - (<Year>) <Album Title> [<Release Type>]
  Release Type is included only when a release-type tag is present and not 'LP'.

- Track filename format:
    <disc/total_discs> <track_num_padded>. <Artist> - <Title>.m4a
  If the album is multi-disc, files are placed under a disc subdirectory named
  by the disc number (e.g. .../Album/1/(1)01. Artist - Song.m4a).
  If single-disc, files remain inside the album directory with the same naming
  rule.

- SKIP_EXISTING (env var, default 'yes') controls whether already-existing
  target filenames are preserved. If SKIP_EXISTING=yes and the desired
  pathname already exists, the file is left alone (skipped). If SKIP_EXISTING=no
  the existing file will be overwritten (by moving/renaming the source into
  place, replacing the previous file).

- The script is careful: it will not merge two different album directories by
  renaming if a conflicting directory name already exists. It logs actions and
  supports --dry-run to preview changes.

Notes:
- The script uses mutagen to read tags (mutagen is already installed in the
  image). It supports common audio container types.
- The heuristics to read tags try common tag keys across formats.

"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import sys
import typing as t
import unicodedata
from pathlib import Path

from mutagen import File as MutagenFile


# Global variables
AUDIO_EXTS: t.Final[tuple] = ('.m4a', '.mp4', '.mp3', '.flac', '.wav', '.aac', '.ogg', '.opus')
TAG_KEYS: t.Final[dict[str, tuple]] = {
    'artist': ('artist', '©ART', '©ARTIST', 'TPE1', 'artist'),
    'albumartist': ('albumartist', 'aART', '©ART', 'albumartist'),
    'album': ('album', '\u00a9alb', '©alb', 'TALB', 'album'),
    'title': ('title', '\u00a9nam', '©nam', 'TIT2', 'title'),
    'year': ('date', 'year', '\u00a9day', '©day', 'TDRC'),
    'disc': ('disc', 'disk', 'disknumber', 'disk number', 'discnumber'),
    'track': ('track', 'tracknumber', 'trkn', 'TRCK'),
    'release_type': ('release_type', 'albumtype', 'media', 'stik', 'cpil')
}
# Environment-controlled behavior
SKIP_EXISTING: t.Final[bool] = True if os.environ.get('SKIP_EXISTING', 'yes').lower() == "yes" else False
# Helpers
logger = logging.getLogger('normalize')


class Helper(object):

    def __new__(cls):
        if not hasattr(cls, 'instance'):
            cls.instance = super(Helper, cls).__new__(cls)
        return cls.instance

    def __init__(self):
        pass

    @staticmethod
    def is_audio_file(path: Path) -> bool:
        """
        Check if a file is an audio file.
        :param path: Path to the file to check.
        :return: True if it is, False otherwise.
        """
        return path.is_file() and path.suffix.lower() in AUDIO_EXTS

    @staticmethod
    def dir_exists(path: Path) -> bool:
        """
        Check if a directory exists.
        :param path: Path to the directory to check.
        :return: True if exists, False otherwise.
        """
        if not path.exists() or not path.is_dir():
            return False
        else:
            return True


class Normalizer(object):

    def __init__(self, path: str):
        self._path = Path(path).resolve()
        if not Helper.dir_exists(self._path):
            logger.error(f"Directory does not exist or is not a directory: {self._path}")
            sys.exit(2)
        self._album_dirs = self._find_album_dirs()

    ### PROPERTIES
    @property
    def path(self) -> Path:
        return self._path

    @path.setter
    def path(self, path: str):
        self._path = Path(path).resolve()

    @property
    def album_dirs(self) -> t.List[AlbumNormalizer]:
        return self._album_dirs

    @album_dirs.setter
    def album_dirs(self, _):
        pass

    def _find_album_dirs(self) -> t.List[AlbumNormalizer]:
        """
        Return list of directories that contain at least one audio file.
        This returns directories anywhere under self._path (including root itself) that
        contain audio files directly (i.e. not only via subdirectories).
        :return: list of directories that contain at least one audio file.
        """
        albums = []
        for dirpath, _, filenames in os.walk(self._path):
            p = Path(dirpath)
            for fn in filenames:
                if Path(fn).suffix.lower() in AUDIO_EXTS:
                    logger.debug(f"Found album directory: {p}")
                    albums.append(AlbumNormalizer(p))
                    break
            else:
                logger.debug(f"{p} is not an album directory")
        logger.info(f"Found {len(albums)} album directories under {self._path}")
        return albums

    def normalize(self, dry_run: bool = False) -> None:
        """
        Process all directory-albums recursively.
        :param dry_run: don't apply anything
        :return: None
        """
        for ad in self.album_dirs:
            try:
                ad.process_album(dry_run=dry_run)
            except Exception as e:
                logger.exception(f"Error processing album {ad}: {e}")


class AlbumNormalizer(object):

    def __init__(self, path: Path):
        self._path = path
        if not Helper.dir_exists(self._path):
            logger.error(f"Directory does not exist or is not a directory: {self._path}")
            sys.exit(2)

    ### PROPERTIES
    @property
    def path(self) -> Path:
        return self._path

    @path.setter
    def path(self, path: str):
        self._path = Path(path).resolve()

    def process_album(self, dry_run: bool = False):
        logger.info(f"Processing album dir: {self._path}")
        # Gather audio files directly under self._path and in immediate subdirs (ignore nested albums)
        files = [p for p in self._path.iterdir() if Helper.is_audio_file(p)]
        # Also include audio files in immediate subdirs (commonly disc subdirs)
        for child in self._path.iterdir():
            if child.is_dir():
                for p in child.iterdir():
                    if Helper.is_audio_file(p):
                        files.append(p)
        if not files:
            logger.debug(f"No audio files found in {self._path}")
            return

        tag_samples = [read_tags(p) for p in files]
        # Determine album-level metadata by majority / fallbacks
        artist = None
        album = None
        year = None
        release_type = None
        discs = set()

        for t in tag_samples:
            if not artist and t.get('albumartist'):
                artist = t.get('albumartist')
            if not artist and t.get('artist'):
                artist = t.get('artist')
            if not album and t.get('album'):
                album = t.get('album')
            if not year and t.get('year'):
                year = t.get('year')
            if not release_type and t.get('release_type'):
                release_type = t.get('release_type')
            if t.get('disc'):
                discs.add(int(t.get('disc')))
            else:
                discs.add(1)

        if not artist:
            artist = 'Unknown Artist'
        if not album:
            album = self._path.name
        album_dir_name = build_album_dir_name(artist, year, album, release_type)

        # If self._path is not already named like album_dir_name, attempt to rename directory
        parent = self._path.parent
        target_album_dir = parent / album_dir_name
        if self._path.name != album_dir_name:
            # if target exists and is different from our source, do not clobber
            if target_album_dir.exists() and target_album_dir.resolve() != self._path.resolve():
                logger.warning(f"Target album dir already exists, skipping rename: {target_album_dir}")
            else:
                if dry_run:
                    logger.info(f"DRY RUN: would rename album dir '{self._path.name}' -> '{album_dir_name}'")
                    # For DRY RUN, proceed as if renamed for downstream path calculations
                    renamed_album_dir = target_album_dir
                else:
                    try:
                        self._path.rename(target_album_dir)
                        logger.info(f"Renamed album dir '{self._path}' -> '{target_album_dir}'")
                        renamed_album_dir = target_album_dir
                    except Exception as e:
                        logger.error(f"Failed to rename album dir {self._path} -> {target_album_dir}: {e}")
                        renamed_album_dir = self._path
        else:
            renamed_album_dir = self._path

        # Re-scan files under renamed_album_dir for up-to-date list
        files = [p for p in renamed_album_dir.iterdir() if Helper.is_audio_file(p)]
        for child in renamed_album_dir.iterdir():
            if child.is_dir():
                for p in child.iterdir():
                    if Helper.is_audio_file(p):
                        files.append(p)

        # Determine disc set after reading tags (some files may not have disc tags)
        disc_map = {}  # mapping from file -> (disc, track)
        for p in files:
            t = read_tags(p)
            disc = t.get('disc') or 1
            track = t.get('track') or 0
            disc = int(disc)
            track = int(track)
            disc_map[p] = (disc, track, t)

        discs_present = sorted({d for d, _, _ in [v for v in disc_map.values()]})
        multi_disc = len(discs_present) > 1

        # For multi-disc: create per-disc subdir
        for p, (disc, track, tags) in disc_map.items():
            track_num = padded(track, 2)
            filename = f"{track_num}. {tags.get('artist') or artist} - {tags.get('title') or p.stem}{p.suffix}"
            # sanitize filename
            filename = sanitize_filename(filename)
            if multi_disc:
                filename = f"{disc}/{discs_present} {filename}"
                target_dir = f"{renamed_album_dir}/Disc {disc}"
            else:
                target_dir = renamed_album_dir
            target_path = target_dir / filename
            # If current file already at target path, skip
            if p.resolve() == target_path.resolve():
                logger.debug(f"File already at desired path: {p}")
                continue
            # If target exists and is same content, skip
            if target_path.exists() and SKIP_EXISTING:
                logger.info(f"Skipping move because target exists and SKIP_EXISTING=yes: {target_path}")
                continue
            ensure_dir(target_dir, dry_run=dry_run)
            try:
                moved = move_or_rename(p, target_path, dry_run=dry_run)
            except Exception as e:
                logger.error(f"Failed to move {p} -> {target_path}: {e}")



def safe_text(val: t.Any) -> str:
    """
    Convert a value into a safe, stripped string.
    :param val: input value. If None, returns an empty string.
                If a non-string sequence (list/tuple/other Sequence), returns the string form of
                its first element (or '' if the sequence is empty).
                Other values are converted to str() and stripped.
    :return: stripped string representation or '' for None/empty sequence.
    """
    if val is None:
        return ''

    # Treat non-string sequences by taking their first element (if any).
    # We explicitly exclude str/bytes/bytearray so that strings are not treated as sequences.
    if isinstance(val, t.Sequence) and not isinstance(val, (str, bytes, bytearray)):
        if len(val) == 0:
            return ''
        val = val[0]

    return str(val).strip()


def get_tag_value(mut, keys: t.List[str]) -> t.Optional[str]:
    """Try a few tag keys from mutagen tags, return the first non-empty.

    Keys should be the convenient canonical names we want to probe for.
    This function attempts several common tag variants for different formats.
    """
    if mut is None:
        return None
    tags = mut.tags
    
    logger.debug(f"Tags for file: {tags}")
    if not tags:
        return None

    # For MP4 files mutagen uses keys like '\xa9nam', '\xa9ART', '\xa9day'
    # For ID3 tags keys are objects (FrameName) - but tags.get('TPE1') works.
    # Mutagen also supports tags.get('artist') for some formats.

    # Try canonical keys first
    for k in keys:
        # direct key
        if k in tags:
            return safe_text(tags.get(k))
        # try lowercase
        if k.lower() in tags:
            return safe_text(tags.get(k.lower()))
    # try a more general search: look for keys that contain the canonical key
    for k in keys:
        for tkey in tags.keys():
            try:
                if isinstance(tkey, str) and k.lower() in tkey.lower():
                    v = tags.get(tkey)
                    if v:
                        return safe_text(v)
            except Exception:
                continue
    return None


def read_tags(path: Path) -> dict:
    """Return a dict with common tag fields for this file.

    Fields returned: artist, albumartist, album, title, year, disc, track, release_type
    """
    data = {
        'artist': None,
        'albumartist': None,
        'album': None,
        'title': None,
        'year': None,
        'disc': None,
        'track': None,
        'release_type': None,
    }
    try:

        m = MutagenFile(str(path), easy=False)
        if m is None:
            return data

        # Common lookup
        tags = {key: get_tag_value(m, keys) for key, keys in TAG_KEYS.items()}
        artist = tags['artist']
        albumartist = tags['albumartist']
        album = tags['album']
        title = tags['title']
        year = tags['year']
        # disc and track can be stored as "1/2" or as numbers
        disc = tags['disc']
        track = tags['track']
        release_type = tags['release_type']

        # Normalize
        data['artist'] = safe_text(artist) or safe_text(albumartist) or None
        data['albumartist'] = safe_text(albumartist) or safe_text(artist) or None
        data['album'] = safe_text(album) or None
        data['title'] = safe_text(title) or None
        data['year'] = None
        if year:
            # try to extract 4-digit year from string
            myear = re.search(r"(19|20)\d{2}", year)
            if myear:
                data['year'] = myear.group(0)
            else:
                data['year'] = year
        # disc
        if disc:
            mdisc = re.search(r"(\d+)", disc)
            if mdisc:
                data['disc'] = int(mdisc.group(1))
        # track
        if track:
            mtrack = re.search(r"(\d+)", track)
            if mtrack:
                data['track'] = int(mtrack.group(1))
        data['release_type'] = safe_text(release_type) or None
    except Exception as e:
        logger.debug(f"Failed reading tags for {path}: {e}")
    return data


def padded(n: int, width: int = 2) -> str:
    return str(n).zfill(width)


def build_album_dir_name(artist: str, year: t.Optional[str], album: str, release_type: t.Optional[str]) -> str:
    """Construct album dir name: <Artist> - (<Year>) <Album Title> [<Release Type>]

    Release type is only included when present and not equal to 'LP' (case-insensitive).
    """
    parts = []
    base_artist = artist or 'Unknown Artist'
    base_album = album or 'Unknown Album'
    parts.append(f"{base_artist} - ")
    if year:
        parts.append(f"({year}) ")
    parts.append(base_album)
    if release_type:
        if release_type.strip().lower() not in ('lp', 'long play'):
            parts.append(f" [{release_type}]")
    return ''.join(parts)


def make_unique_path_if_needed(path: Path) -> Path:
    """If path exists, try to make a unique name by appending ' (1)', ' (2)', ...

    This is used only for safety when we need a non-conflicting name.
    """
    if not path.exists():
        return path
    parent = path.parent
    stem = path.stem
    suffix = path.suffix
    i = 1
    while True:
        candidate = parent / f"{stem} ({i}){suffix}"
        if not candidate.exists():
            return candidate
        i += 1


def ensure_dir(path: Path, dry_run: bool = False):
    if dry_run:
        logger.info(f"DRY RUN: would create directory: {path}")
        return
    path.mkdir(parents=True, exist_ok=True)


def move_or_rename(src: Path, dst: Path, dry_run: bool = False):
    """Move src to dst with overwrite control via SKIP_EXISTING.

    Returns True if moved, False if skipped.
    """
    if src.resolve() == dst.resolve():
        logger.debug(f"Source and destination are same: {src}")
        return False

    if dst.exists():
        if SKIP_EXISTING:
            logger.info(f"Skipping existing target: {dst}")
            return False
        else:
            # overwrite
            if dry_run:
                logger.info(f"DRY RUN: would overwrite existing {dst} with {src}")
            else:
                if dst.is_file():
                    dst.unlink()
                else:
                    # if it's a directory, fail-safe
                    raise FileExistsError(f"Destination exists and is a directory: {dst}")
    if dry_run:
        logger.info(f"DRY RUN: would move '{src}' -> '{dst}'")
        return True
    ensure_dir(dst.parent, dry_run=False)
    shutil.move(str(src), str(dst))
    logger.info(f"Moved '{src}' -> '{dst}'")
    return True


def sanitize_filename(name: str) -> str:
    # Remove problematic characters for cross-platform compatibility
    name = unicodedata.normalize('NFKD', name)
    # forbid NUL
    name = name.replace('\x00', '')
    # Strip characters commonly problematic in filenames
    forbidden = r'<>:"/\\|?*'
    for ch in forbidden:
        name = name.replace(ch, '')
    # Collapse multiple spaces
    name = re.sub(r'\s+', ' ', name).strip()
    return name


def main(argv=None):
    ap = argparse.ArgumentParser(description='Normalize album directories and track filenames')
    ap.add_argument('--source', required=True, help='Source root to scan')
    ap.add_argument('--dry-run', action='store_true', help='Do not perform writes, only show what would happen')
    ap.add_argument('--verbose', action='store_true', help='Verbose logging')
    args = ap.parse_args(argv)

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(level=level, format='%(levelname)s: %(message)s')

    normalizer = Normalizer(args.source)
    normalizer.normalize()


if __name__ == '__main__':
    main()
