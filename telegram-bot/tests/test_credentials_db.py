import os
import sys
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

import credentials_db

# Dummy 32-byte key for testing
TEST_KEY = bytes.fromhex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

class TestCredentialsDB(unittest.TestCase):
    def setUp(self):
        # Use a temporary file database for testing so connections share state
        self.fd, self.temp_db = tempfile.mkstemp()
        credentials_db.DB_PATH = self.temp_db
        credentials_db.init_db()

    def tearDown(self):
        os.close(self.fd)
        os.unlink(self.temp_db)

    @patch("credentials_db.get_secret", return_value=TEST_KEY.hex())
    def test_upsert_and_get_credential(self, mock_get_secret):
        credentials_db.upsert_credential("testuser", "testpass")
        cred = credentials_db.get_credential("testuser")
        self.assertIsNotNone(cred)
        self.assertEqual(cred[0], "testuser")
        self.assertEqual(cred[1], "testpass")

    @patch("credentials_db.get_secret", return_value=TEST_KEY.hex())
    def test_upsert_updates_existing(self, mock_get_secret):
        credentials_db.upsert_credential("testuser", "testpass")
        credentials_db.upsert_credential("testuser", "newpass")
        cred = credentials_db.get_credential("testuser")
        self.assertEqual(cred[1], "newpass")

    @patch("credentials_db.get_secret", return_value=TEST_KEY.hex())
    def test_list_users(self, mock_get_secret):
        credentials_db.upsert_credential("user1", "pass1")
        credentials_db.upsert_credential("user2", "pass2")
        users = credentials_db.list_users()
        self.assertEqual(len(users), 2)
        self.assertIn("user1", users)
        self.assertIn("user2", users)

    @patch("credentials_db.get_secret", return_value=TEST_KEY.hex())
    def test_delete_user_cascades(self, mock_get_secret):
        credentials_db.upsert_credential("user1", "pass1")
        credentials_db.upsert_starred_items("user1", "song", [{"id": "1"}])
        
        # Verify it's there
        self.assertEqual(len(credentials_db.get_starred_items("user1", "song")), 1)
        
        credentials_db.delete_user("user1")
        self.assertIsNone(credentials_db.get_credential("user1"))
        # Should be empty after cascade delete
        self.assertEqual(len(credentials_db.get_starred_items("user1", "song")), 0)

    @patch("credentials_db.get_secret", return_value=TEST_KEY.hex())
    def test_starred_cache_upsert_and_get(self, mock_get_secret):
        credentials_db.upsert_credential("user1", "pass1")
        items = [{"id": "1", "title": "Song A"}, {"id": "2", "title": "Song B"}]
        credentials_db.upsert_starred_items("user1", "song", items)
        
        cached = credentials_db.get_starred_items("user1", "song")
        self.assertEqual(len(cached), 2)
        self.assertEqual(cached[0]["title"], "Song A")
