import logging
import sys
import os
import datetime

# Add the parent directory (or /app in Docker) to sys.path to import modules
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from navidrome_client import NavidromeClient

# Configure basic logging to stdout
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("tester")

def test():
    logger.info("--- Starting Navidrome Connection Test ---")
    
    client = NavidromeClient()
    
    # Check 1: New Albums
    logger.info("1. Testing get_new_albums(hours=2400) (Checking last 100 days to ensure results)...")
    try:
        # Using a large window to make sure we find something if the server is old
        new_albums = client.get_new_albums(hours=2400) 
        if new_albums:
            logger.info(f"SUCCESS: Found {len(new_albums)} albums.")
            for a in new_albums[:3]: # Show first 3
                logger.info(f" - Found: {a.get('name')} by {a.get('artist')}")
        else:
            logger.info("SUCCESS: Connection worked, but no recent albums found (which might be expected).")
    except Exception as e:
        logger.error(f"FAILURE: get_new_albums failed: {e}", exc_info=True)

    # Check 2: Anniversaries
    logger.info("2. Testing get_anniversary_albums (Checking for TODAY)...")
    now = datetime.datetime.now()
    try:
        anniversaries = client.get_anniversary_albums(now.day, now.month)
        if anniversaries:
            logger.info(f"SUCCESS: Found {len(anniversaries)} anniversaries.")
            for a in anniversaries[:3]:
                logger.info(f" - Found: {a.get('name')} ({a.get('date', a.get('year'))})")
        else:
            logger.info("SUCCESS: Connection worked, but no anniversaries for today (expected).")
    except Exception as e:
        logger.error(f"FAILURE: get_anniversary_albums failed: {e}", exc_info=True)
        
    logger.info("--- Test Completed ---")

if __name__ == "__main__":
    test()
