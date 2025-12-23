import hashlib
import random
import string
import requests
import datetime
import logging
from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class NavidromeClient:
    def __init__(self):
        self.base_url = get_secret("navidrome_url")
        self.username = get_secret("navidrome_user")
        self.password = get_secret("navidrome_password")
        self.client_name = "telegram-bot"
        self.version = "1.16.1"

    def _get_auth_params(self):
        salt = ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
        token = hashlib.md5((self.password + salt).encode('utf-8')).hexdigest()
        return {
            'u': self.username,
            't': token,
            's': salt,
            'v': self.version,
            'c': self.client_name,
            'f': 'json'
        }

    def _request(self, endpoint, params=None):
        if params is None:
            params = {}
        
        full_params = self._get_auth_params()
        full_params.update(params)
        
        url = f"{self.base_url}/rest/{endpoint}"
        logger.debug(f"Requesting {endpoint} with params: {params}") # Log only safe params
        
        try:
            response = requests.get(url, params=full_params)
            response.raise_for_status()
            logger.debug(f"Response status: {response.status_code}")
            data = response.json()
            
            if data.get('subsonic-response', {}).get('status') == 'failed':
                error = data['subsonic-response'].get('error', {})
                error_msg = f"Navidrome API Error: {error.get('message')} (Code: {error.get('code')})"
                logger.error(error_msg)
                raise Exception(error_msg)
            
            logger.debug("Request successful.")
            return data['subsonic-response']
        except requests.exceptions.RequestException as e:
            logger.error(f"Error connecting to Navidrome: {e}")
            return None

    def get_new_albums(self, hours=24):
        # Calculate cut-off time
        cutoff = datetime.datetime.now() - datetime.timedelta(hours=hours)
        if cutoff.tzinfo is None:
             cutoff = cutoff.replace(tzinfo=datetime.timezone.utc) # Assume UTC comparisons usually
        
        logger.debug(f"Fetching albums newer than {cutoff}")

        new_albums = []
        offset = 0
        size = 50 # Batch size
        
        while True:
            logger.debug(f"Fetching batch: offset={offset}, size={size}")
            response = self._request('getAlbumList', {'type': 'newest', 'size': size, 'offset': offset})
            
            if not response or 'albumList' not in response:
                break


            albums = response['albumList'].get('album', [])
            if not albums:
                break
            
            # Check this batch
            batch_has_new = False
            for album in albums:
                try:
                    created_str = album.get('created')
                    if created_str:
                        if created_str.endswith('Z'):
                            created_str = created_str[:-1] + '+00:00'
                        
                        created_dt = datetime.datetime.fromisoformat(created_str)
                        
                        # Normalize timezone
                        if created_dt.tzinfo is None:
                             created_dt = created_dt.replace(tzinfo=datetime.timezone.utc)
                        
                        if created_dt > cutoff:
                             new_albums.append(album)
                             batch_has_new = True
                        else:
                            # Because 'newest' returns sorted by creation date descending,
                            # once we find an album older than cutoff, we can theoretically stop.
                            # However, to be safe against slight sorting quirks, we process the batch 
                            # but can stop fetching further pages if the WHOLE batch is old.
                            pass
                except ValueError:
                    logger.warning(f"Failed to parse date for album {album.get('name')}")
                    continue
            
            # If the last album in this batch is older than cutoff, we can stop fetching.
            if albums:
                last_album = albums[-1]
                try:
                    l_str = last_album.get('created')
                    if l_str:
                        if l_str.endswith('Z'): l_str = l_str[:-1] + '+00:00'
                        l_dt = datetime.datetime.fromisoformat(l_str)
                        if l_dt.tzinfo is None: l_dt = l_dt.replace(tzinfo=datetime.timezone.utc)
                        
                        if l_dt < cutoff:
                            break # Optimization: we went past the time window
                except ValueError:
                    pass

            offset += size
            # Safety break for huge libraries loop
            if offset > 10000: 
                logger.warning("get_new_albums fetched over 10000 items, stopping.")
                break
                
        return new_albums

    def get_all_albums(self):
        """Fetches the entire library using pagination."""
        all_albums = []
        offset = 0
        size = 500
        
        logger.info("Syncing full library...")
        while True:
            response = self._request('getAlbumList', {'type': 'alphabeticalByArtist', 'size': size, 'offset': offset})
            if not response or 'albumList' not in response:
                break
            
            albums = response['albumList'].get('album', [])
            if not albums:
                break
                
            all_albums.extend(albums)
            offset += size
            
            # Log progress
            if offset % 2000 == 0:
                logger.info(f"Fetched {offset} albums...")
                
        return all_albums

    def get_anniversary_albums(self, day, month, use_cache=True):
        # Simple JSON cache strategy
        import json
        import os
        
        cache_file = '/app/data/albums_cache.json'
        # Ensure data dir exists
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        
        albums = []
        
        # Try load cache
        if use_cache and os.path.exists(cache_file):
            try:
                # Check file age (e.g. refresh if older than 24h?)
                # For now, let's assume we refresh if the script restarts OR we can just overwrite daily.
                # Actually, the user suggested caching to avoid re-downloading.
                # Let's say we trust the cache for 23 hours.
                mtime = os.path.getmtime(cache_file)
                if datetime.datetime.now().timestamp() - mtime < 23 * 3600:
                    logger.info("Loading albums from local cache...")
                    with open(cache_file, 'r') as f:
                        albums = json.load(f)
                else:
                    logger.info("Cache expired.")
            except Exception as e:
                logger.warning(f"Cache error: {e}")
        
        if not albums:
            albums = self.get_all_albums()
            # Save cache
            try:
                with open(cache_file, 'w') as f:
                    json.dump(albums, f)
                logger.info(f"Cached {len(albums)} albums to {cache_file}")
            except Exception as e:
                logger.error(f"Failed to save cache: {e}")
                
        matches = []
        for album in albums:
            release_date = None
            possible_keys = ['releaseDate', 'date', 'originalDate']
            for k in possible_keys:
                if k in album:
                    release_date = album[k]
                    break
            
            if release_date:
                try:
                    if len(str(release_date)) >= 10:
                        d = datetime.datetime.fromisoformat(str(release_date)[:10])
                        if d.month == month and d.day == day:
                            matches.append(album)
                except ValueError:
                    pass
                
        return matches
