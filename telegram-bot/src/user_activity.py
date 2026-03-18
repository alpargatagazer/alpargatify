"""
User activity engine: handles user synchronization, favorites,
recommendations, and aggregated playback statistics.
"""

import logging
import random
from datetime import datetime, timezone, timedelta
from typing import Optional, List, Dict, Any

import credentials_db
from navidrome_client import NavidromeClient

logger = logging.getLogger(__name__)

# How often to re-sync a user's starred items (in hours)
STARRED_CACHE_TTL_HOURS = 24


def sync_user_starred(username: str, password: str, base_url: str) -> bool:
    """
    Fetch a user's starred songs, albums, and artists from Navidrome
    and cache them in the local database.

    :param username: Navidrome username.
    :param password: Navidrome password (plaintext).
    :param base_url: Navidrome server base URL.
    :return: True if sync succeeded, False otherwise.
    """
    try:
        client = NavidromeClient.from_credentials(base_url, username, password)
        starred = client.get_starred()

        if starred is None:
            logger.error(f"Failed to fetch starred items for user: {username}")
            return False

        for item_type in ('song', 'album', 'artist'):
            items = starred.get(item_type, [])
            credentials_db.upsert_starred_items(username, item_type, items)

        logger.info(
            f"Synced starred for {username}: "
            f"{len(starred.get('song', []))} songs, "
            f"{len(starred.get('album', []))} albums, "
            f"{len(starred.get('artist', []))} artists"
        )
        return True

    except Exception as e:
        logger.error(f"Error syncing starred for {username}: {e}", exc_info=True)
        return False


def ensure_user_synced(username: str, base_url: str) -> bool:
    """
    Ensure a user's starred cache is up to date.
    Only re-syncs if the cache is older than STARRED_CACHE_TTL_HOURS.

    :param username: Navidrome username.
    :param base_url: Navidrome server base URL.
    :return: True if cache is fresh (or was refreshed), False on error.
    """
    last_sync = credentials_db.get_starred_sync_time(username)

    if last_sync:
        if last_sync.tzinfo is None:
            last_sync = last_sync.replace(tzinfo=timezone.utc)
        age = datetime.now(timezone.utc) - last_sync
        if age < timedelta(hours=STARRED_CACHE_TTL_HOURS):
            logger.debug(f"Starred cache for {username} is fresh ({age}). Skipping sync.")
            return True

    # Need to sync — get credentials
    cred = credentials_db.get_credential(username)
    if not cred:
        logger.warning(f"No credentials found for user: {username}")
        return False

    return sync_user_starred(cred[0], cred[1], base_url)


def get_recommendations(
    from_username: str,
    item_type: str,
    limit: int,
    base_url: str
) -> Optional[List[Dict[str, Any]]]:
    """
    Get recommendations from a specific user's favorites.

    :param from_username: The user whose favorites to draw from.
    :param item_type: One of 'song', 'album', 'artist'.
    :param limit: Number of items to return.
    :param base_url: Navidrome server base URL (for syncing if needed).
    :return: List of item dicts, or None on error.
    """
    # Ensure starred data is synced
    if not ensure_user_synced(from_username, base_url):
        return None

    items = credentials_db.get_starred_items(from_username, item_type)

    if not items:
        return []

    # Shuffle and return up to limit
    random.shuffle(items)
    return items[:limit]


def get_random_user_recommendations(
    item_type: str,
    limit: int,
    base_url: str,
    exclude_username: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Get recommendations from a random user's favorites.

    :param item_type: One of 'song', 'album', 'artist'.
    :param limit: Number of items to return.
    :param base_url: Navidrome server base URL (for syncing).
    :param exclude_username: Optional username to exclude from random selection.
    :return: Dict with 'username' and 'items' keys, or None if no users available.
    """
    users = validate_and_get_users(base_url)
    if exclude_username:
        users = [u for u in users if u != exclude_username]

    if not users:
        return None

    chosen = random.choice(users)
    items = get_recommendations(chosen, item_type, limit, base_url)

    if items is None:
        return None

    return {
        'username': chosen,
        'items': items
    }


def validate_and_get_users(base_url: str) -> List[str]:
    """
    Iterate over all stored users, ping the server to check credentials.
    If an AuthError is raised (invalid credentials), the user is deleted from the database.
    
    :param base_url: Navidrome server base URL.
    :return: List of valid usernames.
    """
    from navidrome_client import AuthError
    users = credentials_db.list_users()
    valid_users = []
    for username in users:
        cred = credentials_db.get_credential(username)
        if not cred:
            continue
        try:
            client = NavidromeClient.from_credentials(base_url, cred[0], cred[1])
            client._request('ping')
            valid_users.append(username)
        except AuthError:
            logger.warning(f"Validation failed for {username} (AuthError). Deleting from DB.")
            credentials_db.delete_user(username)
        except Exception as e:
            # If it's a network error, we don't delete the user, we just assume they might be valid
            logger.warning(f"Validation ping error for {username}: {e}")
            valid_users.append(username)
    return valid_users


def purge_inactive_users(admin_client: NavidromeClient, max_days: int = 30) -> List[str]:
    """
    Remove users from the credentials database if they haven't logged into
    Navidrome in the last `max_days` days.

    Uses the Navidrome Native API to check lastLoginAt.

    :param admin_client: NavidromeClient with admin credentials.
    :param max_days: Maximum days of inactivity before purging.
    :return: List of purged usernames.
    """
    users = credentials_db.list_users()
    if not users:
        return []

    purged = []
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_days)

    for username in users:
        try:
            last_login = admin_client.get_user_last_login(username)

            if last_login is None:
                # User doesn't exist in Navidrome anymore — purge
                logger.info(f"User '{username}' not found in Navidrome. Purging.")
                credentials_db.delete_user(username)
                purged.append(username)
                continue

            if last_login.tzinfo is None:
                last_login = last_login.replace(tzinfo=timezone.utc)

            if last_login < cutoff:
                logger.info(
                    f"User '{username}' last login {last_login.isoformat()} "
                    f"is older than {max_days} days. Purging."
                )
                credentials_db.delete_user(username)
                purged.append(username)

        except Exception as e:
            logger.warning(f"Could not check last login for '{username}': {e}")

    if purged:
        logger.info(f"Purged {len(purged)} inactive user(s): {', '.join(purged)}")
    else:
        logger.info("No inactive users to purge.")

    return purged
