"""
Encrypted credentials storage for Navidrome user accounts.
Uses SQLite for persistence and AES-256-GCM for password encryption.
"""

import json
import logging
import os
import sqlite3
from datetime import datetime, timezone
from typing import Optional, List, Dict, Tuple, Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from secrets_loader import get_secret

logger = logging.getLogger(__name__)

DB_PATH = os.environ.get("CREDENTIALS_DB_PATH", "/app/data/credentials.db")


def _get_encryption_key() -> bytes:
    """
    Load the AES-256 encryption key from Docker secrets.
    The key must be exactly 32 bytes (hex-encoded = 64 chars).

    :return: 32-byte encryption key.
    :raises ValueError: If the key is missing or invalid length.
    """
    key_hex = get_secret("credentials_encryption_key")
    if not key_hex:
        raise ValueError(
            "credentials_encryption_key secret not found. "
            "Generate one with: python -c \"import secrets; print(secrets.token_hex(32))\""
        )
    key_hex = key_hex.strip()
    if len(key_hex) != 64:
        raise ValueError(
            f"credentials_encryption_key must be 64 hex chars (32 bytes), got {len(key_hex)}"
        )
    return bytes.fromhex(key_hex)


def _get_db() -> sqlite3.Connection:
    """
    Get a SQLite connection with WAL mode and foreign keys enabled.

    :return: sqlite3.Connection instance.
    """
    db_dir = os.path.dirname(DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    """
    Create the database tables if they don't exist.
    Called once at application startup.
    """
    conn = _get_db()
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS credentials (
                username        TEXT PRIMARY KEY,
                encrypted_password BLOB NOT NULL,
                nonce           BLOB NOT NULL,
                updated_at      TEXT NOT NULL,
                telegram_id     INTEGER
            );

            CREATE TABLE IF NOT EXISTS starred_cache (
                username    TEXT NOT NULL,
                item_type   TEXT NOT NULL CHECK(item_type IN ('song', 'album', 'artist')),
                item_id     TEXT NOT NULL,
                item_data   TEXT NOT NULL,
                synced_at   TEXT NOT NULL,
                PRIMARY KEY (username, item_type, item_id),
                FOREIGN KEY (username) REFERENCES credentials(username) ON DELETE CASCADE
            );
        """)
        conn.commit()
        
        # Migration: Add telegram_id column if it doesn't exist
        try:
            conn.execute("ALTER TABLE credentials ADD COLUMN telegram_id INTEGER")
            conn.commit()
            logger.info("Database migration: Added telegram_id column to credentials table.")
        except sqlite3.OperationalError as e:
            if "duplicate column name" in str(e).lower():
                pass # Already exists
            else:
                logger.warning(f"Database migration note: {e}")

        logger.info("Credentials database initialized.")
    finally:
        conn.close()


def upsert_credential(username: str, password: str, telegram_id: Optional[int] = None) -> None:
    """
    Insert or update a user's Navidrome credentials.
    
    :param username: Navidrome username.
    :param password: Navidrome password.
    :param telegram_id: Optional Telegram user ID to associate.
    """
    key = _get_encryption_key()
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    encrypted = aesgcm.encrypt(nonce, password.encode('utf-8'), None)
    now = datetime.now(timezone.utc).isoformat()

    conn = _get_db()
    try:
        conn.execute(
            """
            INSERT INTO credentials (username, encrypted_password, nonce, updated_at, telegram_id)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(username) DO UPDATE SET
                encrypted_password = excluded.encrypted_password,
                nonce = excluded.nonce,
                updated_at = excluded.updated_at,
                telegram_id = COALESCE(excluded.telegram_id, credentials.telegram_id)
            """,
            (username, encrypted, nonce, now, telegram_id)
        )
        conn.commit()
        logger.info(f"Credential upserted for user: {username}")
    finally:
        conn.close()


def get_navidrome_user_by_telegram_id(telegram_id: int) -> Optional[str]:
    """
    Find the Navidrome username associated with a Telegram ID.
    """
    conn = _get_db()
    try:
        row = conn.execute(
            "SELECT username FROM credentials WHERE telegram_id = ?",
            (telegram_id,)
        ).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def get_credential(username: str) -> Optional[Tuple[str, str]]:
    """
    Retrieve and decrypt a user's credentials.

    :param username: Navidrome username.
    :return: Tuple of (username, decrypted_password) or None if not found.
    """
    conn = _get_db()
    try:
        row = conn.execute(
            "SELECT username, encrypted_password, nonce FROM credentials WHERE username = ?",
            (username,)
        ).fetchone()

        if not row:
            return None

        key = _get_encryption_key()
        aesgcm = AESGCM(key)
        decrypted = aesgcm.decrypt(row[2], row[1], None)
        return (row[0], decrypted.decode('utf-8'))
    except Exception as e:
        logger.error(f"Error decrypting credentials for {username}: {e}")
        return None
    finally:
        conn.close()


def list_users() -> List[str]:
    """
    List all usernames that have stored credentials.

    :return: List of usernames.
    """
    conn = _get_db()
    try:
        rows = conn.execute("SELECT username FROM credentials ORDER BY username").fetchall()
        return [r[0] for r in rows]
    finally:
        conn.close()


def delete_user(username: str) -> None:
    """
    Delete a user's credentials and all their cached starred data.
    Due to ON DELETE CASCADE, starred_cache rows are automatically removed.

    :param username: Navidrome username to delete.
    """
    conn = _get_db()
    try:
        conn.execute("DELETE FROM credentials WHERE username = ?", (username,))
        conn.commit()
        logger.info(f"Deleted credentials and cache for user: {username}")
    finally:
        conn.close()


def upsert_starred_items(username: str, item_type: str, items: List[Dict[str, Any]]) -> None:
    """
    Bulk insert/update cached starred items for a user.
    Replaces all existing items of that type for the user.

    :param username: Navidrome username.
    :param item_type: One of 'song', 'album', 'artist'.
    :param items: List of item dicts from the Subsonic API response.
    """
    if item_type not in ('song', 'album', 'artist'):
        raise ValueError(f"Invalid item_type: {item_type}")

    now = datetime.now(timezone.utc).isoformat()
    conn = _get_db()
    try:
        # Delete existing items of this type for this user
        conn.execute(
            "DELETE FROM starred_cache WHERE username = ? AND item_type = ?",
            (username, item_type)
        )

        # Insert new items
        for item in items:
            item_id = item.get('id', '')
            if not item_id:
                continue
            conn.execute(
                """
                INSERT INTO starred_cache (username, item_type, item_id, item_data, synced_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (username, item_type, item_id, json.dumps(item, ensure_ascii=False), now)
            )

        conn.commit()
        logger.info(f"Cached {len(items)} {item_type}(s) for user: {username}")
    finally:
        conn.close()


def get_starred_items(username: str, item_type: str) -> List[Dict[str, Any]]:
    """
    Retrieve cached starred items for a user.

    :param username: Navidrome username.
    :param item_type: One of 'song', 'album', 'artist'.
    :return: List of item dicts.
    """
    conn = _get_db()
    try:
        rows = conn.execute(
            "SELECT item_data FROM starred_cache WHERE username = ? AND item_type = ?",
            (username, item_type)
        ).fetchall()
        return [json.loads(r[0]) for r in rows]
    finally:
        conn.close()


def get_starred_sync_time(username: str) -> Optional[datetime]:
    """
    Get the last sync time for a user's starred cache.

    :param username: Navidrome username.
    :return: datetime of last sync, or None if never synced.
    """
    conn = _get_db()
    try:
        row = conn.execute(
            "SELECT MAX(synced_at) FROM starred_cache WHERE username = ?",
            (username,)
        ).fetchone()

        if row and row[0]:
            return datetime.fromisoformat(row[0])
        return None
    finally:
        conn.close()


def delete_starred_items(username: str) -> None:
    """
    Delete all cached starred items for a user.

    :param username: Navidrome username.
    """
    conn = _get_db()
    try:
        conn.execute("DELETE FROM starred_cache WHERE username = ?", (username,))
        conn.commit()
        logger.info(f"Cleared starred cache for user: {username}")
    finally:
        conn.close()
