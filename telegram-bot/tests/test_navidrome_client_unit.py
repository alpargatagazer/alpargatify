import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add project root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
# Also try a relative src if running outside docker
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src')))

from navidrome_client import NavidromeClient

class TestNavidromeClientUnit(unittest.TestCase):
    def setUp(self):
        # Patch get_secret to return dummy values
        self.secret_patcher = patch('navidrome_client.get_secret')
        self.mock_get_secret = self.secret_patcher.start()
        self.mock_get_secret.side_effect = lambda key, default=None: {
            "navidrome_url": "http://test-server",
            "navidrome_user": "test-user",
            "navidrome_password": "test-password"
        }.get(key, default)
        
        self.client = NavidromeClient()

    def tearDown(self):
        self.secret_patcher.stop()

    @patch('navidrome_client.NavidromeClient._get_auth_params')
    def test_request_success(self, mock_auth):
        mock_auth.return_value = {'u': 'user', 't': 'token', 's': 'salt', 'v': '1.16.1', 'c': 'test', 'f': 'json'}
        
        mock_get = MagicMock()
        self.client.session.get = mock_get
        
        mock_response = MagicMock()
        mock_response.json.return_value = {
            'subsonic-response': {
                'status': 'ok',
                'test': 'data'
            }
        }
        mock_response.status_code = 200
        mock_get.return_value = mock_response

        result = self.client._request('testEndpoint', {'param1': 'value1'})
        
        self.assertEqual(result.get('status'), 'ok')
        self.assertEqual(result.get('test'), 'data')
        self.assertTrue(mock_get.called)

    @patch('navidrome_client.NavidromeClient._get_auth_params')
    def test_request_failure(self, mock_auth):
        mock_auth.return_value = {'u': 'user', 't': 'token', 's': 'salt', 'v': '1.16.1', 'c': 'test', 'f': 'json'}
        
        mock_get = MagicMock()
        self.client.session.get = mock_get
        
        mock_response = MagicMock()
        mock_response.json.return_value = {
            'subsonic-response': {
                'status': 'failed',
                'error': {'code': 40, 'message': 'Wrong username or password'}
            }
        }
        mock_get.return_value = mock_response

        with self.assertRaises(Exception):
            self.client._request('testEndpoint')

    @patch('navidrome_client.NavidromeClient._request')
    def test_get_music_folder_id(self, mock_request):
        # Setup mock for getMusicFolders
        mock_request.return_value = {
            'musicFolders': {
                'musicFolder': [
                    {'id': '1', 'name': 'Music Library'},
                    {'id': '2', 'name': 'Other'}
                ]
            }
        }
        
        folder_id = self.client.get_music_folder_id()
        self.assertEqual(folder_id, '1')
        # Check cache
        self.assertEqual(self.client._music_folder_id, '1')

    @patch('navidrome_client.NavidromeClient._request')
    def test_search_albums(self, mock_request):
        # Explicit ID to ensure filtering is called
        self.client._music_folder_id = '1'
        mock_request.return_value = {
            'searchResult3': {
                'album': [{'id': 'alb1', 'name': 'Great Album', 'artist': 'Great Artist'}]
            }
        }
        
        results = self.client.search_albums("query", limit=5)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['name'], 'Great Album')
        
        # Verify params
        args, kwargs = mock_request.call_args
        self.assertEqual(args[0], 'search3')
        self.assertEqual(args[1]['musicFolderId'], '1')
        self.assertEqual(args[1]['query'], 'query')

    @patch('navidrome_client.NavidromeClient._request')
    def test_get_now_playing(self, mock_request):
        mock_request.return_value = {
            'nowPlaying': {
                'entry': [{'username': 'user1', 'title': 'song1'}]
            }
        }
        playing = self.client.get_now_playing()
        self.assertEqual(len(playing), 1)
        self.assertEqual(playing[0]['username'], 'user1')

    @patch('navidrome_client.NavidromeClient.sync_library')
    def test_get_server_stats_with_size(self, mock_sync):
        # Mock enriched albums with sizes
        mock_sync.return_value = [
            {'id': 'alb1', 'artist': 'Artist 1', 'songCount': 10, 'total_size_bytes': 1024},
            {'id': 'alb1', 'artist': 'Artist 1', 'songCount': 5, 'total_size_bytes': 512}, # Same ID, different instance (should still count)
            {'id': 'alb2', 'artist': 'Artist 2', 'songCount': 3, 'total_size_bytes': 256}
        ]
        
        stats = self.client.get_server_stats()
        self.assertEqual(stats['albums'], 3)
        self.assertEqual(stats['artists'], 2)
        self.assertEqual(stats['songs'], 18)
        self.assertEqual(stats['size_bytes'], 1792)

    @patch('navidrome_client.NavidromeClient._request')
    def test_fetch_album_details_with_size(self, mock_request):
        mock_request.return_value = {
            'album': {
                'id': 'alb1',
                'name': 'Test Album',
                'song': [
                    {'id': 's1', 'size': 100},
                    {'id': 's2', 'size': 200}
                ]
            }
        }
        
        album = self.client._fetch_album_details('alb1')
        self.assertEqual(album['total_size_bytes'], 300)

if __name__ == '__main__':
    unittest.main()
