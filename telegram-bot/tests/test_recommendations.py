import unittest
from unittest.mock import patch, MagicMock

import recommendations

class TestRecommendations(unittest.TestCase):

    @patch("recommendations.ensure_user_synced", return_value=True)
    @patch("credentials_db.get_starred_items")
    def test_get_recommendations(self, mock_get_starred, mock_ensure):
        # Mock 25 songs
        mock_get_starred.return_value = [{"id": str(i)} for i in range(25)]
        
        results = recommendations.get_recommendations("testuser", "song", 20, "http://navidrome")
        
        self.assertIsNotNone(results)
        self.assertEqual(len(results), 20) # Bounded by limit limit

    @patch("credentials_db.list_users", return_value=["user1", "user2", "user3"])
    @patch("recommendations.get_recommendations", return_value=[{"id": "1"}])
    def test_get_random_user_excludes_self(self, mock_get_rec, mock_list):
        from unittest.mock import ANY
        # Exclude user1, should only pick user2 or user3
        for _ in range(10):
            res = recommendations.get_random_user_recommendations("song", 10, "http://nav", exclude_username="user1")
            self.assertIn(res["username"], ["user2", "user3"])
            self.assertNotEqual(res["username"], "user1")
