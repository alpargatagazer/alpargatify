import os
import sys
import unittest


def run_all_tests():
    print("🚀 Starting Navidrome Telegram Bot Test Suite...")
    
    # Discover and run all tests in the 'tests' directory
    loader = unittest.TestLoader()
    start_dir = os.path.join(os.path.dirname(__file__), 'tests')
    suite = loader.discover(start_dir, pattern='test_*.py')
    
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    
    if result.wasSuccessful():
        print("\n✅ All tests passed successfully!")
        sys.exit(0)
    else:
        print("\n❌ Some tests failed.")
        sys.exit(1)

if __name__ == "__main__":
    run_all_tests()
