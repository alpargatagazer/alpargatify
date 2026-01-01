
import unittest
import sys
import os

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

from telegram_bot import TelegramBot

class TestDateFormatting(unittest.TestCase):
    def setUp(self):
        # TelegramBot init requires secrets, so we mock or bypass it if possible.
        # But format_album_list is a static method (or independent enough) in our refactor?
        # Actually format_album_list is a static method in my previous edit!
        # Let's verify if I made it static. Yes, line 628 in previous view showed @staticmethod.
        pass

    def test_full_date(self):
        """Test formatting with full Year-Month-Day."""
        album = {
            "name": "Full Date Album",
            "artist": "Artist",
            "releaseDate": {"year": 2023, "month": 5, "day": 20}
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 2023-05-20", msg)

    def test_partial_year_month(self):
        """Test formatting with Year-Month only."""
        album = {
            "name": "Year Month Album",
            "artist": "Artist",
            "releaseDate": {"year": 2023, "month": 8}
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 2023-08", msg)
        self.assertNotIn("2023-08-01", msg) # Should NOT default to day 1

    def test_year_only_dict(self):
        """Test formatting with Year only (in dict)."""
        album = {
            "name": "Year Only Dict",
            "artist": "Artist",
            "releaseDate": {"year": 2025}
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 2025", msg)
        self.assertNotIn("2025-01", msg)

    def test_year_only_missing_month(self):
        """Test formatting with Year and None month/day."""
        album = {
            "name": "Year Missing Month",
            "artist": "Artist",
            "releaseDate": {"year": 1990, "month": None, "day": None}
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 1990", msg)

    def test_string_date(self):
        """Test formatting with ISO string date."""
        album = {
            "name": "String Date",
            "artist": "Artist",
            "releaseDate": "1994-01-01"
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 1994-01-01", msg)

    def test_simple_year_field(self):
        """Test fallback to 'year' field if releaseDate is missing."""
        album = {
            "name": "Simple Year",
            "artist": "Artist",
            "year": 1999
        }
        msg = TelegramBot.format_album_list([album], "Test")
        self.assertIn("📅 1999", msg)

if __name__ == '__main__':
    unittest.main()
