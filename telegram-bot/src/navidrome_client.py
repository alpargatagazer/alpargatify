import datetime
import hashlib
import json
import logging
import os
import random
import string
from typing import List, Dict, Optional, Any

import requests

from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class NavidromeClient:
    """
    Client for interacting with the Navidrome (Subsonic) API.
    """
    def __init__(self):
        """
        Initialize the Navidrome client with credentials from secrets.
        """
        self.base_url: Optional[str] = get_secret("navidrome_url")
        self.username: Optional[str] = get_secret("navidrome_user")
        self.password: Optional[str] = get_secret("navidrome_password")
        self.client_name: str = "telegram-bot"
        self.version: str = "1.16.1"

    def _get_auth_params(self) -> dict[str, str | None]:
        """
        Generate authentication parameters (salt, token, etc.) for Subsonic API.

        :return: Dictionary containing authentication parameters.
        """
        salt = ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
        
        if not self.password:
            logger.error("Navidrome password not found in secrets.")
            token = ""
        else:
            token = hashlib.md5((self.password + salt).encode('utf-8')).hexdigest()
            
        return {
            'u': self.username or "",
            't': token,
            's': salt,
            'v': self.version,
            'c': self.client_name,
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
        
        if not self.base_url:
            logger.error("Navidrome URL not found configuration.")
            return None

        url = f"{self.base_url}/rest/{endpoint}"
        logger.debug(f"Requesting {endpoint} with params: {params}")
        
        try:
            response = requests.get(url, params=full_params)
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
            return response['album']
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
            response = self._request('getAlbumList', {'type': 'alphabeticalByArtist', 'size': size, 'offset': offset})
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
                
                if is_expired:
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
        Get albums added in the last N hours by filtering the synchronized library.
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
        Find albums released on the specified day and month by filtering the library.
        Handles both ISO strings and Navidrome's dict keys for 'releaseDate'.
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
        Search for albums matching the given query.
        
        :param query: Search term (artist or album name)
        :param limit: Maximum number of results to return
        :return: List of matching albums
        """
        response = self._request('search3', {
            'query': query,
            'albumCount': limit,
            'artistCount': 0,
            'songCount': 0
        })
        
        if response and 'searchResult3' in response:
            albums = response['searchResult3'].get('album', [])
            logger.info(f"Search for '{query}' returned {len(albums)} albums")
            return albums
        
        return []

    def get_random_album(self) -> Optional[Dict[str, Any]]:
        """
        Get a random album from the library.
        
        :return: Random album dictionary or None if not found
        """
        response = self._request('getAlbumList2', {
            'type': 'random',
            'size': 1
        })
        
        if response and 'albumList2' in response:
            albums = response['albumList2'].get('album', [])
            if albums:
                logger.info(f"Random album: {albums[0].get('name')}")
                return albums[0]
        
        return None

    def get_server_stats(self) -> Optional[Dict[str, int]]:
        """
        Get server statistics (album count, artist count, song count).
        Uses the local cache to count items efficiently.
        
        :return: Dictionary with 'albums', 'artists', 'songs' counts or None on error
        """
        try:
            # Use cached library for counting
            all_albums = self.sync_library(force=False)
            
            # Count unique artists
            artists = set()
            total_songs = 0
            
            for album in all_albums:
                artist = album.get('artist')
                if artist:
                    artists.add(artist)
                
                song_count = album.get('songCount', 0)
                total_songs += song_count
            
            stats = {
                'albums': len(all_albums),
                'artists': len(artists),
                'songs': total_songs
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
        if not self.base_url or not cover_id:
            return None
        
        params = self._get_auth_params()
        params['id'] = cover_id
        
        # Build query string
        query_parts = [f"{k}={v}" for k, v in params.items()]
        query_string = "&".join(query_parts)
        
        url = f"{self.base_url}/rest/getCoverArt?{query_string}"
        return url

    def get_cover_art_bytes(self, cover_id: str) -> Optional[bytes]:
        """
        Download album cover art as binary data.
        
        :param cover_id: Cover art ID from album metadata
        :return: Cover art image bytes or None if download fails
        """
        if not self.base_url or not cover_id:
            return None
        
        params = self._get_auth_params()
        params['id'] = cover_id
        
        url = f"{self.base_url}/rest/getCoverArt"
        
        try:
            response = requests.get(url, params=params)
            response.raise_for_status()
            logger.debug(f"Downloaded cover art for {cover_id}, size: {len(response.content)} bytes")
            return response.content
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to download cover art: {e}")
            return None
