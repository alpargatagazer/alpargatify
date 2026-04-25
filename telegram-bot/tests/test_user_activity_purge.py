import unittest
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone
import sys
import os

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

import user_activity
from navidrome_client import NavidromeClient

class TestUserActivityPurge(unittest.TestCase):

    @patch("credentials_db.list_users")
    @patch("credentials_db.delete_user")
    def test_purge_inactive_users_skips_on_error(self, mock_delete, mock_list):
        # Setup users
        mock_list.return_value = ["user1", "user2"]
        
        # Mock admin client
        mock_admin = MagicMock(spec=NavidromeClient)
        # user1 fails (network error), user2 is active
        def side_effect(username):
            if username == "user1":
                raise Exception("Network error")
            return datetime.now(timezone.utc)
        
        mock_admin.get_user_last_login.side_effect = side_effect
        
        purged = user_activity.purge_inactive_users(mock_admin, max_days=30)
        
        # Should NOT delete user1
        mock_delete.assert_not_called()
        self.assertEqual(len(purged), 0)

    @patch("credentials_db.list_users")
    @patch("credentials_db.delete_user")
    def test_purge_inactive_users_deletes_on_none(self, mock_delete, mock_list):
        # Setup users
        mock_list.return_value = ["user1"]
        
        # Mock admin client
        mock_admin = MagicMock(spec=NavidromeClient)
        # user1 is NOT found
        mock_admin.get_user_last_login.return_value = None
        
        purged = user_activity.purge_inactive_users(mock_admin, max_days=30)
        
        # Should delete user1
        mock_delete.assert_called_with("user1")
        self.assertEqual(purged, ["user1"])

if __name__ == "__main__":
    unittest.main()
