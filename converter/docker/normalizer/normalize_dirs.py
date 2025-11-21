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
from functools import cached_property
from pathlib import Path

from mutagen import File as MutagenFile, FileType

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

    @staticmethod
    def build_album_dir_name(
            artist: str,
            year: t.Optional[str],
            album: str,
            release_type: t.Optional[str],
    ) -> str:
        """
        Construct an album directory name.
        Format: "<Artist> - (<Year>) <Album Title> [<Release Type>]"

        The release type is only included when present and not equal to 'LP'
        (case-insensitive).
        :param artist: Artist name.
        :param year: Release year or None.
        :param album: Album title.
        :param release_type: Optional release type (e.g., 'EP', 'Single').
        :return: Constructed directory name.
        """
        base_artist = artist or "Unknown Artist"
        base_album = album or "Unknown Album"

        parts = [f"{base_artist} - "]

        if year:
            parts.append(f"({year}) ")

        parts.append(base_album)

        if release_type:
            normalized = release_type.strip().lower()
            if normalized not in ("lp", "long play"):
                parts.append(f" [{release_type}]")

        return "".join(parts)

    @staticmethod
    def padded(n: int, width: int = 2) -> str:
        """
        Return a zero-padded string representation of a number.
        :param n: Number to pad.
        :param width: Minimum width of the resulting string.
        :return: Zero-padded string.
        """
        return str(n).zfill(width)

    @staticmethod
    def sanitize_filename(name: str) -> str:
        """
        Sanitize a filename to improve cross-platform compatibility.
        Removes forbidden characters, normalizes Unicode, and collapses
        unnecessary whitespace.
        :param name: Original filename string.
        :return: A safe, cleaned filename string.
        """
        # Normalize Unicode to a decomposed form (removes accents when needed)
        name = unicodedata.normalize('NFKD', name)

        # Remove NUL characters explicitly
        name = name.replace('\x00', '')

        # Remove characters commonly forbidden in filenames
        forbidden = r'<>:"/\\|?*'
        for ch in forbidden:
            name = name.replace(ch, '')

        # Collapse multiple spaces and trim leading/trailing whitespace
        name = re.sub(r'\s+', ' ', name).strip()

        return name

    @staticmethod
    def ensure_dir(path: Path, dry_run: bool = False) -> None:
        """
        Ensure that a directory exists, creating it if necessary.
        :param path: Directory path to create.
        :param dry_run: If True, only log the action without performing it.
        """
        if dry_run:
            logger.info(f"DRY RUN: would create directory: {path}")
            return
        path.mkdir(parents=True, exist_ok=True)


class FileNormalizer(object):

    def __init__(self, path: Path):
        self._path = path
        if not path.is_file():
            logger.error(f"File does not exist or is not a file: {self._path}")
            raise FileNotFoundError(self._path)

    ### PROPERTIES
    @property
    def path(self) -> Path:
        return self._path

    @path.setter
    def path(self, _):
        pass

    @cached_property
    def mutagen(self) -> FileType:
        mut = MutagenFile(str(self._path), easy=False)
        return mut

    @cached_property
    def tags(self) -> dict[str, t.Any]:
        return self._read_tags()

    ### METHODS
    def get_tag_value(self, keys: t.Tuple[str]) -> t.Optional[str]:
        """
        Try a few tag keys from mutagen tags, return the first non-empty.
        Keys should be the convenient canonical names we want to probe for.
        This function attempts several common tag variants for different formats.
        :param keys: list of tag keys.
        :return: tag value or None
        """

        if self.mutagen is None or not self.mutagen.tags:
            return None
        tags = self.mutagen.tags

        # For MP4 files mutagen uses keys like '\xa9nam', '\xa9ART', '\xa9day'
        # For ID3 tags keys are objects (FrameName) - but tags.get('TPE1') works.
        # Mutagen also supports tags.get('artist') for some formats.

        # Try canonical keys first
        for k in keys:
            # direct key
            if k in tags:
                return Helper.safe_text(tags.get(k))
            # try lowercase
            elif k.lower() in tags:
                return Helper.safe_text(tags.get(k.lower()))
        # try a more general search: look for keys that contain the canonical key
        for k in keys:
            for tag_key in tags.keys():
                try:
                    if isinstance(tag_key, str) and k.lower() in tag_key.lower():
                        v = tags.get(tag_key)
                        if v:
                            return Helper.safe_text(v)
                except Exception:
                    continue
        return None

    def _read_tags(self) -> dict[str, t.Any]:
        """Return a dict with common tag fields for this file.

        Fields returned: artist, albumartist, album, title, year, disc, track, release_type
        """
        data: dict[str, t.Any] = {
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

            # Common lookup
            tags = {key: self.get_tag_value(keys) for key, keys in TAG_KEYS.items()}
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
            data['artist'] = Helper.safe_text(artist) or Helper.safe_text(albumartist) or None
            data['albumartist'] = Helper.safe_text(albumartist) or Helper.safe_text(artist) or None
            data['album'] = Helper.safe_text(album) or None
            data['title'] = Helper.safe_text(title) or None
            data['year'] = None
            if year:
                # try to extract 4-digit year from string
                myear = re.search(r"(19|20)\d{2}", year)
                if myear:
                    data['year'] = myear.group(0)
                else:
                    data['year'] = year
            if disc:
                mdisc = re.search(r"(\d+)", disc)
                if mdisc:
                    data['disc'] = int(mdisc.group(1))
            if track:
                mtrack = re.search(r"(\d+)", track)
                if mtrack:
                    data['track'] = int(mtrack.group(1))
            data['release_type'] = Helper.safe_text(release_type) or None

        except Exception as e:
            logger.warning(f"Failed reading tags for {self._path}: {e}")

        else:
            logger.debug(f"Successfully read tags for {self._path}: {data}")

        return data

    def move_or_rename(self, dst: Path, dry_run: bool = False) -> bool:
        """
        Move or rename this object's file path to a new destination.
        Honors the SKIP_EXISTING flag for overwrite control.

        :param dst: Destination file path.
        :param dry_run: If True, actions are logged but not executed.
        :return: True if the move/rename occurred (or would occur in dry-run), False if skipped.
        """

        # Resolve both paths to detect no-op moves
        if self._path.resolve() == dst.resolve():
            logger.debug(f"Source and destination are identical: {self._path}")
            return True

        # Handle existing destination
        if dst.exists():
            if SKIP_EXISTING:
                logger.info(f"Skipping because destination already exists: {dst}")
                return True
            else:
                # Overwrite logic
                if dry_run:
                    logger.info(f"DRY RUN: would overwrite existing {dst} with {self._path}")
                else:
                    if dst.is_file():
                        dst.unlink()
                    else:
                        logger.error(f"Destination exists and is a directory: {dst}")
                        return False

        # Perform (or simulate) the move
        if dry_run:
            logger.info(f"DRY RUN: would move '{self._path}' -> '{dst}'")
            return True
        else:
            Helper.ensure_dir(dst.parent, dry_run=False)
            shutil.move(str(self._path), str(dst))
            logger.info(f"Moved '{self._path}' -> '{dst}'")
            return True


class AlbumNormalizer(object):

    def __init__(self, path: Path):
        self._path = path
        if not self._path.is_dir():
            logger.error(f"Directory does not exist or is not a directory: {self._path}")
            sys.exit(2)

    ### PROPERTIES
    @property
    def path(self) -> Path:
        return self._path

    @path.setter
    def path(self, _):
        pass

    ### PROPERTIES
    @cached_property
    def file_songs(self) -> t.List[FileNormalizer]:
        return self.gather_audio_files()

    def gather_audio_files(self) -> t.List[FileNormalizer]:
        """
        Gather audio files directly under the album path and in immediate subdirectories.
        :return: List of FileNormalizer instances for audio files found (direct children + one level deep).
        """
        # Gather audio files directly under path and in immediate subdirs (ignore nested albums)
        files: t.List[FileNormalizer] = [FileNormalizer(p) for p in self._path.iterdir() if Helper.is_audio_file(p)]
        # Also include audio files in immediate subdirs (commonly disc subdirs)
        for child in self._path.iterdir():
            if child.is_dir():
                files_subdir = [FileNormalizer(p) for p in child.iterdir() if Helper.is_audio_file(p)]
                files += files_subdir
        logger.debug(f"Found {len(files)} audio files in {self._path}: {(f.path.name for f in files)}")
        return files

    def get_new_album_name(self, dry_run: bool = False) -> Path:
        """
        Get the album path where the songs must be moved thanks to the song tags.
        :param dry_run: If True, only log the action without performing it.
        :return: new album path.
        """

        logger.info(f"Processing album dir: {self._path}")

        if not self.file_songs:
            logger.error(f"No audio files found in {self._path}")

        tag_samples = [p.tags for p in self.file_songs]
        # Determine album-level metadata by majority / fallbacks
        artist = None
        album = None
        year = None
        release_type = None
        discs = set()

        for tag in tag_samples:
            if not artist and tag.get('albumartist'):
                artist = tag.get('albumartist')
            if not artist and tag.get('artist'):
                artist = tag.get('artist')
            if not album and tag.get('album'):
                album = tag.get('album')
            if not year and tag.get('year'):
                year = tag.get('year')
            if not release_type and tag.get('release_type'):
                release_type = tag.get('release_type')
            if tag.get('disc'):
                discs.add(int(tag.get('disc')))
            else:
                discs.add(1)

        album_dir_name = Helper.build_album_dir_name(artist, year, album, release_type)

        # If self._path is not already named like album_dir_name, attempt to rename directory
        parent = self._path.parent
        target_album_dir = parent / album_dir_name
        if self._path.name != album_dir_name:
            # if target exists and is different from our source, do not clobber
            if target_album_dir.exists() and target_album_dir.resolve() != self._path.resolve():
                logger.warning(f"Target album dir already exists, skipping rename: {target_album_dir}")
                renamed_album_dir = target_album_dir
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
        return renamed_album_dir

    def process_album(self, dry_run: bool = False) -> bool:
        """
        Normalize the content of an album directory.
        :param dry_run: If True, only log the action without performing it.
        :return: True if it went successfully is, False otherwise.
        """

        new_album = AlbumNormalizer(self.get_new_album_name(dry_run))

        # Determine disc set after reading tags (some files may not have disc tags)
        disc_map: dict[FileNormalizer, tuple[int, int, dict[str, t.Any]]] = {}  # mapping from file -> (disc, track, tags)
        for file in new_album.file_songs:
            tags = file.tags
            disc = tags.get('disc') or 1
            track = tags.get('track') or 0
            disc = int(disc)
            track = int(track)
            disc_map[file] = (disc, track, tags)

        discs_present = sorted({d for d, _, _ in [v for v in disc_map.values()]})
        multi_disc = len(discs_present) > 1

        result = []
        for file, (disc, track, tags) in disc_map.items():
            track_num = Helper.padded(track, 2)
            filename = f"{track_num}. {tags.get('artist')} - {tags.get('title') or file.path.stem}{file.path.suffix}"
            # Sanitize filename
            filename = Helper.sanitize_filename(filename)
            # For multi-disc: create per-disc subdir
            if multi_disc:
                filename = f"{disc}/{discs_present} {filename}"
                target_dir = new_album.path / f"Disc {disc}"
            else:
                target_dir = new_album.path
            target_path = target_dir / filename
            # If target exists and is same content, skip
            if target_path.exists() and SKIP_EXISTING:
                logger.info(f"Skipping move because target exists and SKIP_EXISTING=yes: {target_path}")
                for old_file in self.file_songs:
                    if (
                        old_file.tags["title"] == file.tags["title"] and old_file.tags["track"] == file.tags["track"]
                        and old_file.path.parent != file.path.parent
                    ):
                        logger.debug(f"Removing duplicate file: {old_file.path}")
                        os.remove(old_file.path)
                        break
                continue
            # If neither, tries to create the file
            Helper.ensure_dir(target_dir, dry_run=dry_run)
            try:
                result.append(file.move_or_rename(target_path, dry_run=dry_run))
            except Exception as e:
                logger.error(f"Failed to move {file.path} -> {target_path}: {e}")
                result.append(False)
        else:
            if self._path.exists() and not any(self._path.iterdir()):
                logger.debug(f"Removing {self._path} since it's empty.")
                shutil.rmtree(self._path)
            return any(result)


class Normalizer(object):

    def __init__(self, path: str):
        self._path = Path(path).resolve()
        if not self._path.is_dir():
            logger.error(f"Directory does not exist or is not a directory: {self._path}")
            sys.exit(2)
        self._album_dirs = self._find_album_dirs()

    ### PROPERTIES
    @property
    def path(self) -> Path:
        return self._path

    @path.setter
    def path(self, _):
        pass

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
        :param dry_run: If True, only log the action without performing it.
        :return: None
        """
        for ad in self.album_dirs:
            try:
                ad.process_album(dry_run=dry_run)
            except Exception as e:
                logger.exception(f"Error processing album {ad.path}: {e}")


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
