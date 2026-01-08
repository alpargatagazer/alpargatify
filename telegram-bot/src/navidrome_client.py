import datetime
import hashlib
import json
import logging
import os
import random
import string
from typing import List, Dict, Optional, Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class NavidromeClient:
    """
    Client for interacting with the Navidrome (Subsonic) API.
    """
    def __init__(self):
        """
        Initialize the Navidrome client with credentials from secrets.
        Sanitizes the base URL by stripping trailing slashes.
        """
        url = get_secret("navidrome_url")
        self._base_url: Optional[str] = url.rstrip('/') if url else None
        self._username: Optional[str] = get_secret("navidrome_user")
        self._password: Optional[str] = get_secret("navidrome_password")
        self._client_name: str = "telegram-bot"
        self._api_version: str = os.environ.get("NAVIDROME_API_VERSION", "1.16.1")
        self._music_folder_name: str = os.environ.get("NAVIDROME_MUSIC_FOLDER", "Music Library")
        self._music_folder_id: Optional[str] = None
        self._scan_meta_file: str = '/app/data/scan_status.json'
        
        # Setup session with retries
        self.session = requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET"]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        self.timeout = 30 # Default timeout in seconds

    def _get_auth_params(self) -> dict[str, str | None]:
        """
        Generate authentication parameters (salt, token, etc.) for Subsonic API.

        :return: Dictionary containing authentication parameters.
        """
        salt = ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
        
        if not self._password:
            logger.error("Navidrome password not found in secrets.")
            token = ""
        else:
            token = hashlib.md5((self._password + salt).encode('utf-8')).hexdigest()
            
        return {
            'u': self._username or "",
            't': token,
            's': salt,
            'v': self._api_version,
            'c': self._client_name,
            'f': 'json'
        }

    def _request(self, endpoint: str, params: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
        """
        Make a request to the Navidrome API.

        :param endpoint: The API endpoint (e.g., 'getAlbumList').
        :param params: Optional dictionary of query parameters.
        :return: However the 'subsonic-response' JSON object is structured, or None on failure.
        """
        if params is None:
            params = {}
        
        full_params = self._get_auth_params()
        full_params.update(params)
        
        if not self._base_url:
            logger.error("Navidrome URL not found configuration.")
            return None

        url = f"{self._base_url}/rest/{endpoint}"
        logger.debug(f"Requesting {url} with params: {params}")
        
        try:
            response = self.session.get(url, params=full_params, timeout=self.timeout)
            response.raise_for_status()
            
            logger.debug(f"Response status: {response.status_code}")
            try:
                data = response.json()
            except json.JSONDecodeError:
                logger.error(f"Failed to decode JSON response from {url}")
                return None
            
            subsystem = data.get('subsonic-response', {})
            if subsystem.get('status') == 'failed':
                error = subsystem.get('error', {})
                error_msg = f"Navidrome API Error: {error.get('message')} (Code: {error.get('code')})"
                logger.error(error_msg)
                raise Exception(error_msg)
            
            logger.debug("Request successful.")
            return subsystem
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error connecting to Navidrome: {e}")
            raise e

    def get_music_folder_id(self) -> Optional[str]:
        """
        Find the ID of the music folder matching self._music_folder_name.
        Caches the result in memory for efficiency.

        :return: The folder ID as a string, or None if not found.
        """
        if self._music_folder_id:
            return self._music_folder_id

        response = self._request('getMusicFolders')
        if response and 'musicFolders' in response:
            folders = response['musicFolders'].get('musicFolder', [])
            for folder in folders:
                if folder.get('name') == self._music_folder_name:
                    self._music_folder_id = str(folder.get('id'))
                    logger.info(f"Detected music folder '{self._music_folder_name}' with ID: {self._music_folder_id}")
                    return self._music_folder_id
        
        logger.warning(f"Could not find music folder named '{self._music_folder_name}'")
        return None

    def check_scan_status(self) -> Optional[Dict[str, Any]]:
        """
        Check the current scan status of the Navidrome server.
        
        :return: Dictionary with scan status details or None on failure.
        """
        response = self._request('getScanStatus')
        if response and 'scanStatus' in response:
            return response['scanStatus']
        return None

    def _fetch_album_details(self, album_id: str) -> Optional[Dict[str, Any]]:
        """
        Fetch detailed information for a single album using the getAlbum endpoint.
        This provides enriched metadata including full release dates and genre lists.
        
        :param album_id: The unique album ID.
        :return: Album dictionary with detailed metadata, or None if fetch fails.
        """
        response = self._request('getAlbum', {'id': album_id})
        if response and 'album' in response:
            album = response['album']
            # Calculate total size in bytes for this album
            total_size = 0
            if 'song' in album:
                for s in album['song']:
                    total_size += s.get('size', 0)
            album['total_size_bytes'] = total_size
            return album
        return None

    def sync_library(self, force: bool = False) -> List[Dict[str, Any]]:
        """
        Synchronize the album library with incremental enrichment and expiry rotation.
        
        Strategy:
        1. Fetch ALL album IDs from API (lightweight getAlbumList calls).
        2. Load existing enriched cache from disk.
        3. Calculate diffs:
            - NEW albums: In API but not in cache.
            - DELETED albums: In cache but not in API.
            - EXPIRED albums: In cache but _fetched_at > 7 days old.
        4. Enrich (fetch detailed metadata) for NEW + EXPIRED albums using ThreadPool.
        5. Reconstruct and save the updated cache.
        
        :param force: If True, ignores cache and re-fetches all album details.
        :return: List of enriched album dictionaries with full metadata.
        """
        cache_file = '/app/data/albums_cache.json'
        expiry_days = 7
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)

        # 0. Check Scan Status before doing anything heavy
        if not force:
            try:
                current_status = self.check_scan_status()
                if current_status and not current_status.get('scanning'):
                    current_count = current_status.get('count')
                    last_scan = current_status.get('lastScan')
                    
                    if os.path.exists(self._scan_meta_file):
                        with open(self._scan_meta_file, 'r') as f:
                            saved_status = json.load(f)
                        
                        if saved_status.get('count') == current_count and saved_status.get('lastScan') == last_scan:
                            if os.path.exists(cache_file):
                                with open(cache_file, 'r') as f:
                                    cached_data = json.load(f)
                                
                                # Check if cache entries are missing size metadata (migration check)
                                needs_migration = False
                                if cached_data:
                                    # Heuristic: check first few albums
                                    for alb in cached_data[:20]:
                                        if 'total_size_bytes' not in alb:
                                            needs_migration = True
                                            break
                                
                                if not needs_migration:
                                    logger.info("Scan status unchanged and cache exists. Skipping full sync.")
                                    return cached_data
                                else:
                                    logger.info("Cache is missing size metadata. Triggering enrichment sync.")
                    
                    # Save current status for next time if we're about to sync
                    with open(self._scan_meta_file, 'w') as f:
                        json.dump({'count': current_count, 'lastScan': last_scan}, f)
            except Exception as e:
                logger.warning(f"Optimization check failed: {e}. Proceeding with sync.")
        
        cached_albums: Dict[str, Dict[str, Any]] = {}
        
        
        # 1. Load Cache (if valid and not forced)
        if not force and os.path.exists(cache_file):
            try:
                # We can relax the timeout since we check against the live API list anyway.
                # If an album changes metadata WITHOUT changing ID, we won't catch it with this strategy.
                # But for "New Albums" and "Anniversaries" based on static release dates, this is fine.
                logger.info("Loading local cache...")
                with open(cache_file, 'r') as f:
                    data = json.load(f)
                    # Convert list to dict for fast lookup by ID
                    for alb in data:
                        aid = alb.get('id')
                        if aid:
                            cached_albums[aid] = alb
            except Exception as e:
                logger.warning(f"Cache load error: {e}. Starting fresh.")
                cached_albums = {}

        # 2. Fetch full list from API (Lightweight)
        current_api_albums: List[Dict[str, Any]] = []
        offset = 0
        size = 500
        
        logger.info("Fetching full album list (IDs) from Navidrome...")
        while True:
            logger.debug(f"Fetching batch: offset={offset}")
            params = {'type': 'alphabeticalByArtist', 'size': size, 'offset': offset}
            
            folder_id = self.get_music_folder_id()
            if folder_id:
                params['musicFolderId'] = folder_id
                
            response = self._request('getAlbumList', params)
            if not response or 'albumList' not in response:
                break
            
            batch = response['albumList'].get('album', [])
            if not batch:
                break
                
            current_api_albums.extend(batch)
            offset += size
            
            if offset % 2000 == 0:
                logger.info(f"Fetched {offset} albums (light)...")
        
        # 3. Diff
        current_ids = set(a['id'] for a in current_api_albums if 'id' in a)
        cached_ids = set(cached_albums.keys())
        
        new_ids = current_ids - cached_ids
        deleted_ids = cached_ids - current_ids

        # 4. Check for expired items in cache
        expired_ids = set()
        if not force:
            now = datetime.datetime.now(datetime.timezone.utc)
            for aid, album in cached_albums.items():
                if aid in deleted_ids: 
                    continue
                
                fetched_at_str = album.get('_fetched_at')
                is_expired = True # Default to expired if no timestamp
                
                if fetched_at_str:
                    try:
                        fetched_at = datetime.datetime.fromisoformat(fetched_at_str)
                        if fetched_at.tzinfo is None:
                            fetched_at = fetched_at.replace(tzinfo=datetime.timezone.utc)
                        
                        age = now - fetched_at
                        if age.days < expiry_days:
                            is_expired = False
                    except ValueError:
                        pass # Bad format, treat as expired
                
                if is_expired or 'total_size_bytes' not in album:
                    expired_ids.add(aid)
        
        ids_to_fetch = new_ids.union(expired_ids)
        
        logger.info(f"Sync Status: {len(current_api_albums)} total. {len(new_ids)} new. {len(deleted_ids)} deleted. {len(expired_ids)} expired.")
        
        # 5. Enrich New & Expired Albums
        new_enriched_albums: List[Dict[str, Any]] = []
        
        if ids_to_fetch:
            logger.info(f"Enriching {len(ids_to_fetch)} albums...")
            from concurrent.futures import ThreadPoolExecutor, as_completed
            
            with ThreadPoolExecutor(max_workers=10) as executor:
                # We need to map future back to ID to know what failed
                future_to_id = {executor.submit(self._fetch_album_details, aid): aid for aid in ids_to_fetch}
                
                count = 0
                total = len(ids_to_fetch)
                
                for future in as_completed(future_to_id):
                    aid = future_to_id[future]
                    try:
                        details = future.result()
                        if details:
                            # Add timestamp
                            details['_fetched_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                            new_enriched_albums.append(details)
                        else:
                            # If fetch fails, try to find the basic info from current_api_albums as fallback
                            fallback = next((a for a in current_api_albums if a['id'] == aid), None)
                            if fallback:
                                # Even if fallback, we mark it fetched so we don't retry immediately, 
                                # or maybe we don't? Let's mark it so we try again next time if we don't save _fetched_at?
                                # Actually, if we stick with fallback, we should probably timestamp it to avoid loops.
                                fallback['_fetched_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                                new_enriched_albums.append(fallback)
                    except Exception as e:
                        logger.error(f"Error enriching album {aid}: {e}")
                    
                    count += 1
                    if count % 50 == 0:
                         logger.info(f"Enriched {count}/{total} albums...")
        
        # 5. Reconstruct Final List and Cache
        final_library: List[Dict[str, Any]] = []
        
        # Add preserved cached items (excluding deleted and expired)
        for aid, album in cached_albums.items():
            if aid not in deleted_ids and aid not in expired_ids:
                final_library.append(album)
        
        # Add newly enriched items
        final_library.extend(new_enriched_albums)
        
        # Save
        if final_library:
            try:
                with open(cache_file, 'w') as f:
                    json.dump(final_library, f)
                logger.info(f"Updated cache with {len(final_library)} albums.")
            except Exception as e:
                logger.error(f"Failed to save cache: {e}")
                
        return final_library

    def get_new_albums(self, hours: int = 24, force: bool = False) -> List[Dict[str, Any]]:
        """
        Get albums added to the library in the last N hours.
        Filters the synchronized library cache.

        :param hours: Number of hours to look back.
        :param force: If True, force a full library synchronization.
        :return: List of new album dictionaries sorted by creation date.
        """
        all_albums = self.sync_library(force=force) 
        
        cutoff = datetime.datetime.now() - datetime.timedelta(hours=hours)
        if cutoff.tzinfo is None:
             cutoff = cutoff.replace(tzinfo=datetime.timezone.utc)
             
        new_albums: List[Dict[str, Any]] = []
        logger.info(f"Filtering {len(all_albums)} albums for additions since {cutoff}...")
        
        for album in all_albums:
            try:
                created_str = album.get('created')
                if created_str:
                    if created_str.endswith('Z'):
                        created_str = created_str[:-1] + '+00:00'
                    
                    created_dt = datetime.datetime.fromisoformat(created_str)
                    if created_dt.tzinfo is None:
                         created_dt = created_dt.replace(tzinfo=datetime.timezone.utc)
                    
                    if created_dt > cutoff:
                         new_albums.append(album)
            except ValueError:
                continue
                
        # Sort by created desc
        new_albums.sort(key=lambda x: x.get('created', ''), reverse=True)
        return new_albums

    def get_anniversary_albums(self, day: int, month: int, force: bool = False) -> List[Dict[str, Any]]:
        """
        Find albums released on the specified day and month across all years.
        Handles various release date formats (ISO strings and Navidrome dictionaries).

        :param day: Day of the month (1-31).
        :param month: Month of the year (1-12).
        :param force: If True, force a full library synchronization.
        :return: List of matching album dictionaries.
        """
        all_albums = self.sync_library(force=force)
        
        matches: List[Dict[str, Any]] = []
        logger.info(f"Scanning {len(all_albums)} albums for anniversary {month}/{day}...")
        
        for album in all_albums:
            release_date = None
            # Prioritize 'releaseDate' which comes from getAlbum detailed view
            possible_keys = ['releaseDate', 'date', 'originalDate', 'published']
            for k in possible_keys:
                if k in album and album[k]:
                    release_date = album[k]
                    break
            
            if release_date:
                try:
                    # Case 1: releaseDate is a Dictionary (Navidrome getAlbum format)
                    # e.g. {'year': 2006, 'month': 3, 'day': 14}
                    if isinstance(release_date, dict):
                        r_month = release_date.get('month')
                        r_day = release_date.get('day')
                        if r_month == month and r_day == day:
                            matches.append(album)
                            logger.debug(f"MATCH (dict): {album.get('name')} ({release_date})")
                            continue

                    # Case 2: releaseDate is a String (Subsonic/ISO format)
                    s_date = str(release_date)
                    d = None
                    if len(s_date) >= 10:
                        try:
                            d = datetime.datetime.fromisoformat(s_date[:10])
                        except ValueError:
                            pass
                    
                    if d:
                        if d.month == month and d.day == day:
                            matches.append(album)
                            logger.debug(f"MATCH (iso): {album.get('name')} ({s_date})")
                except Exception as e:
                     logger.debug(f"Date check error for {album.get('name')}: {e}")
            
        return matches

    def search_albums(self, query: str, limit: int = 5) -> List[Dict[str, Any]]:
        """
        Search for albums using the Subsonic search3 endpoint.
        Matches against artist names and album titles.

        :param query: The search query string.
        :param limit: Maximum number of albums to return.
        :return: List of matching album dictionaries.
        """
        params = {
            'query': query,
            'albumCount': limit,
            'artistCount': 0,
            'songCount': 0
        }
        
        folder_id = self.get_music_folder_id()
        if folder_id:
            params['musicFolderId'] = folder_id

        response = self._request('search3', params)
        
        if response and 'searchResult3' in response:
            albums = response['searchResult3'].get('album', [])
            logger.info(f"Search for '{query}' returned {len(albums)} albums")
            return albums
        
        return []

    def get_random_album(self) -> Optional[Dict[str, Any]]:
        """
        Fetch a single random album from the library.

        :return: A random album dictionary or None if no albums are available.
        """
        params = {
            'type': 'random',
            'size': 1
        }
        
        folder_id = self.get_music_folder_id()
        if folder_id:
            params['musicFolderId'] = folder_id

        response = self._request('getAlbumList2', params)
        
        if response and 'albumList2' in response:
            albums = response['albumList2'].get('album', [])
            if albums:
                logger.info(f"Random album: {albums[0].get('name')}")
                return albums[0]
        
        return None

    def get_now_playing(self) -> List[Dict[str, Any]]:
        """
        Retrieve currently playing tracks for the authenticated user.
        NOTE: Navidrome does not support global 'Now Playing' for all users via Subsonic API.

        :return: List of now playing entry dictionaries.
        """
        response = self._request('getNowPlaying')
        if response and 'nowPlaying' in response:
            return response['nowPlaying'].get('entry', [])
        return []

    def get_top_albums_from_history(self, days: int = 7, limit: int = 10) -> List[Dict[str, Any]]:
        """
        Calculate top albums by aggregating playback history for the current user.
        
        NOTE: This functionality is CURRENTLY UNUSED and not exposed in the bot.
        Navidrome (Subsonic API) does not support global history for all users, 
        making server-wide statistics impossible via API at this time.
        We preserve this code for future use if API capabilities expand.

        :param days: Number of days to look back.
        :param limit: Maximum number of albums to return.
        :return: List of top album dictionaries.
        """
        # Fetch history (default limit is usually 50, let's get more for better stats)
        # getHistory doesn't take 'days', so we fetch a large batch and filter locally.
        response = self._request('getHistory', {'size': 500})
        
        if not response or 'history' not in response:
            logger.warning("getHistory returned no data or error. Falling back to 'frequent' albums.")
            fallback = self._request('getAlbumList2', {'type': 'frequent', 'size': limit})
            if fallback and 'albumList2' in fallback:
                return fallback['albumList2'].get('album', [])
            return []
        
        entries = response['history'].get('item', [])
        now = datetime.datetime.now(datetime.timezone.utc)
        cutoff = now - datetime.timedelta(days=days)
        
        logger.debug(f"Aggregating top albums. Now (UTC): {now}, Cutoff (UTC): {cutoff}")
        
        album_stats = {} # album_id -> {details, count}
        
        for entry in entries:
            # Entry 'played' can be:
            # 1. Timestamp in ms (Subsonic Spec)
            # 2. Timestamp in seconds (Some variants)
            # 3. ISO 8601 string (Navidrome/JSON default in some cases)
            played_val = entry.get('played')
            if not played_val:
                continue
            
            try:
                if isinstance(played_val, (int, float)):
                    # Heuristic: if value < 10^11, it's probably seconds
                    # (Current time in ms is ~1.7e12, in s is ~1.7e9)
                    if played_val < 100000000000: 
                        played_ms = played_val * 1000
                    else:
                        played_ms = played_val
                    played_dt = datetime.datetime.fromtimestamp(played_ms / 1000.0, tz=datetime.timezone.utc)
                else:
                    # Try parsing as ISO string
                    # Navidrome often returns "2024-12-24T12:00:00Z"
                    s_val = str(played_val)
                    if s_val.endswith('Z'):
                        s_val = s_val[:-1] + '+00:00'
                    played_dt = datetime.datetime.fromisoformat(s_val)
                    if played_dt.tzinfo is None:
                        played_dt = played_dt.replace(tzinfo=datetime.timezone.utc)
            except Exception as e:
                logger.warning(f"Could not parse played date '{played_val}': {e}")
                continue
            
            if played_dt < cutoff:
                logger.debug(f"Skipping entry: {entry.get('title')} played at {played_dt} (before {cutoff})")
                continue
            
            album_id = entry.get('albumId')
            if not album_id:
                continue
                
            if album_id not in album_stats:
                album_stats[album_id] = {
                    'id': album_id,
                    'name': entry.get('album'),
                    'artist': entry.get('artist'),
                    'playCount': 0,
                    'coverArt': entry.get('coverArt')
                }
            album_stats[album_id]['playCount'] += 1
            
        # Sort by playCount desc
        top_albums = sorted(album_stats.values(), key=lambda x: x['playCount'], reverse=True)
        logger.info(f"Top albums aggregation complete. Found {len(top_albums)} unique albums in range.")
        return top_albums[:limit]

    def get_genres(self) -> List[Dict[str, Any]]:
        """
        Fetch all music genres available in the library.

        :return: List of genre objects (dictionaries).
        """
        response = self._request('getGenres')
        if response and 'genres' in response:
            return response['genres'].get('genre', [])
        return []

    def get_albums_by_genre(self, genre: str, limit: int = 50) -> List[Dict[str, Any]]:
        """
        Retrieve a selection of albums for a specific genre.
        Used for the /genres command exploration.

        :param genre: The genre name (case sensitive). 'None' for albums without a genre.
        :param limit: Maximum number of albums to return.
        :return: List of album dictionaries.
        """
        params = {
            'type': 'byGenre',
            'genre': genre if genre != 'None' else '',
            'size': 500 # Fetch more to randomize
        }
        
        folder_id = self.get_music_folder_id()
        if folder_id:
            params['musicFolderId'] = folder_id
            
        response = self._request('getAlbumList2', params)
        if response and 'albumList2' in response:
            albums = response['albumList2'].get('album', [])
            if albums:
                random.shuffle(albums)
                return albums[:limit]
        return []

    def get_albums_by_year(self, start_year: int, end_year: int, limit: int = 50) -> List[Dict[str, Any]]:
        """
        Retrieve random albums released within a specific year range.
        
        :param start_year: The starting year (inclusive).
        :param end_year: The ending year (inclusive).
        :param limit: Maximum number of albums to return.
        :return: List of album dictionaries sorted by year.
        """
        # Since Navidrome/Subsonic API doesn't support range filtering easily,
        # we sync the library (cached) and filter locally.
        all_albums = self.sync_library(force=False)
        
        matches = []
        for album in all_albums:
            # Check 'year' field
            year_val = album.get('year')
            if not year_val:
                # Try detailed Release Date if accessible, but usually 'year' is present in standard list
                continue
                
            try:
                year = int(year_val)
                if start_year <= year <= end_year:
                    matches.append(album)
            except (ValueError, TypeError):
                continue
        
        if not matches:
            return []
            
        # Shuffle first to get random selection, then sort by year
        random.shuffle(matches)
        selected = matches[:limit]
        
        # Sort by year (ascending)
        selected.sort(key=lambda x: int(x.get('year', 0)))
        
        return selected


    def get_server_stats(self) -> Optional[Dict[str, int]]:
        """
        Get server statistics (album count, artist count, song count).
        Uses the local cache to count items efficiently.
        
        :return: Dictionary with 'albums', 'artists', 'songs' counts or None on error
        """
        try:
            # Use cached library for counting
            all_albums = self.sync_library(force=False)
            
            # Count unique artists and aggregate total size
            artists = set()
            total_songs = 0
            total_size_bytes = 0
            
            for album in all_albums:
                artist = album.get('artist')
                if artist:
                    artists.add(artist)
                
                song_count = album.get('songCount', 0)
                total_songs += song_count
                
                # total_size_bytes is calculated during enrichment in _fetch_album_details
                total_size_bytes += album.get('total_size_bytes', 0)
            
            stats = {
                'albums': len(all_albums),
                'artists': len(artists),
                'songs': total_songs,
                'size_bytes': total_size_bytes
            }
            
            logger.info(f"Server stats: {stats}")
            return stats
            
        except Exception as e:
            logger.error(f"Error getting server stats: {e}")
            return None

    def get_cover_art_url(self, cover_id: str) -> Optional[str]:
        """
        Generate an authenticated URL for album cover art.
        
        :param cover_id: Cover art ID from album metadata
        :return: Full URL to cover art image or None if configuration missing
        """
        if not self._base_url or not cover_id:
            return None
        
        params = self._get_auth_params()
        params['id'] = cover_id
        
        # Build query string
        query_parts = [f"{k}={v}" for k, v in params.items()]
        query_string = "&".join(query_parts)
        
        url = f"{self._base_url}/rest/getCoverArt?{query_string}"
        return url

    def get_cover_art_bytes(self, cover_id: str) -> Optional[bytes]:
        """
        Download album cover art as binary data.
        
        :param cover_id: Cover art ID from album metadata
        :return: Cover art image bytes or None if download fails
        """
        if not self._base_url or not cover_id:
            return None
        
        params = self._get_auth_params()
        params['id'] = cover_id
        
        url = f"{self._base_url}/rest/getCoverArt"
        
        try:
            response = requests.get(url, params=params)
            response.raise_for_status()
            logger.debug(f"Downloaded cover art for {cover_id}, size: {len(response.content)} bytes")
            return response.content
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to download cover art: {e}")
            return None
