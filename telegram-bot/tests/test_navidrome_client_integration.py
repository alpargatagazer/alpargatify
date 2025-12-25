import os
import sys
import unittest

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
# Also try a relative src if running outside docker
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

from navidrome_client import NavidromeClient
from telegram_bot import TelegramBot

class TestNavidromeIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # We need secrets to be available in the environment or secrets folder
        cls.client = NavidromeClient()
        # Initialize bot without polling - just for formatting tests
        cls.bot = TelegramBot()

    def test_navidrome_connection(self):
        """Verify we can at least get music folders."""
        response = self.client._request('getMusicFolders')
        self.assertIsNotNone(response)
        self.assertIn('musicFolders', response)
        
        folders = response.get('musicFolders', {}).get('musicFolder', [])
        folder_names = [f.get('name') for f in folders]
        self.assertIn(self.client._music_folder_name, folder_names, 
                     f"Configured folder '{self.client._music_folder_name}' not found on server")

    def test_music_folder_filtering(self):
        """Verify music folder detection and filtering works."""
        folder_id = self.client.get_music_folder_id()
        self.assertIsNotNone(folder_id)
        
        # Test album list for this folder
        params = {'type': 'alphabeticalByArtist', 'size': 5, 'musicFolderId': folder_id}
        response = self.client._request('getAlbumList', params)
        self.assertIn('albumList', response)

    def test_notification_content(self):
        """Verify get_new_albums and get_anniversary_albums (extended window)."""
        # 10 days window
        new_albums = self.client.get_new_albums(hours=240)
        self.assertIsInstance(new_albums, list)
        
        # Test anniversary (use fixed date if possible or just check call)
        # We are using here September 22 because we know an album is released that day
        anniversaries = self.client.get_anniversary_albums(22, 9)
        self.assertIsInstance(anniversaries, list)

    def test_library_scan_status(self):
        status = self.client.check_scan_status()
        self.assertIsNotNone(status)
        self.assertIn('scanning', status)

    def test_search_and_format(self):
        """Search for 'a' and verify formatting works."""
        results = self.client.search_albums("a", limit=3)
        self.assertIsInstance(results, list)
        
        if results:
            msg = self.bot.format_album_list(results, "Integration Test")
            self.assertIsNotNone(msg)
            self.assertIn("Integration Test", msg)
            self.assertIn("💿", msg)

    def test_get_genres(self):
        genres = self.client.get_genres()
        self.assertIsInstance(genres, list)

if __name__ == '__main__':
    unittest.main()
