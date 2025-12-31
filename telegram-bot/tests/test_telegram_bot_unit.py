import os
import sys
import unittest
from unittest.mock import patch

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

from telegram_bot import TelegramBot

class TestTelegramBotUnit(unittest.TestCase):
    def setUp(self):
        # Patch dependencies to avoid side effects during init
        with patch('telegram_bot.NavidromeClient'), \
             patch('telegram_bot.telebot.TeleBot'), \
             patch('telegram_bot.get_secret'):
            self.bot = TelegramBot()

    def test_format_size(self):
        self.assertEqual(TelegramBot.format_size(0), "0 B")
        self.assertEqual(TelegramBot.format_size(1024), "1.0 KB")
        self.assertEqual(TelegramBot.format_size(1024 * 1024), "1.0 MB")
        self.assertEqual(TelegramBot.format_size(1024**3), "1.0 GB")
        self.assertEqual(TelegramBot.format_size(1572864), "1.5 MB")

    def test_get_album_type_tag_from_release_types(self):
        # EP
        alb_ep = {"name": "Test EP", "releaseTypes": ["ep"]}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_ep), " [EP]")
        
        # Live
        alb_live = {"name": "Live in Paris", "releaseTypes": ["live"]}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_live), " [Live]")

    def test_get_album_type_tag_from_compilation_flag(self):
        alb_comp = {"name": "Hits 2024", "isCompilation": True}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_comp), " [Compilation]")

    def test_get_album_type_tag_from_title_heuristic(self):
        # Compilation keywords in title
        alb_title_comp = {"name": "Street Halo / Kindred Compilation"}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_title_comp), " [Compilation]")
        
        alb_box_set = {"name": "Keep an Eye on the Sky (Box Set)"}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_box_set), " [Compilation]")

        alb_best_of = {"name": "Best of Big Star"}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_best_of), " [Compilation]")
        
        # Case insensitive
        alb_title_ep = {"name": "Great ep"}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_title_ep), " [EP]")

    def test_get_album_type_tag_avoids_duplication(self):
        # If title already has brackets, don't add more
        alb_already_tagged = {"name": "Discovery [Live]", "releaseTypes": ["live"]}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_already_tagged), "")
        
        # Avoid duplication for parentheses too
        alb_paren = {"name": "After Hours (EP)", "releaseTypes": ["ep"]}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_paren), "")

    def test_get_album_type_tag_empty_for_standard_album(self):
        alb_standard = {"name": "Standard Album", "releaseTypes": ["album"]}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_standard), "")
        
        alb_none = {"name": "Mystery Music"}
        self.assertEqual(TelegramBot._get_album_type_tag(alb_none), "")

if __name__ == '__main__':
    unittest.main()
