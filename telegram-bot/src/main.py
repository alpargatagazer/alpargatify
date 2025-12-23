import time
import schedule
import datetime
import os
import sys
import logging
from navidrome_client import NavidromeClient
from telegram_sender import TelegramSender

# Configure Logging
log_level_str = os.environ.get("LOGGING", "INFO").upper()
log_level = getattr(logging, log_level_str, logging.INFO)

logging.basicConfig(
    level=log_level,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("bot")
logger.info(f"Logging configured at level: {log_level_str}")

def job():
    logger.info(f"Starting daily check at {datetime.datetime.now()}")
    
    client = NavidromeClient()
    sender = TelegramSender()
    
    # 1. New Albums (Last 24h)
    logger.info("Checking for new albums...")
    try:
        new_albums = client.get_new_albums(hours=24)
        if new_albums:
            logger.info(f"Found {len(new_albums)} new albums.")
            msg = sender.format_album_list(new_albums, "🆕 Freshly Added Albums (Last 24h)")
            if msg:
                sender.send_message(msg)
        else:
            logger.info("No new albums found.")
    except Exception as e:
        logger.error(f"Error checking new albums: {e}", exc_info=True)

    # 2. Anniversaries (Same Day, Same Month)
    logger.info("Checking for anniversaries...")
    now = datetime.datetime.now()
    try:
        anniversaries = client.get_anniversary_albums(now.day, now.month)
        if anniversaries:
            logger.info(f"Found {len(anniversaries)} anniversaries.")
            msg = sender.format_album_list(anniversaries, f"🎂 On this day ({now.strftime('%B %d')}) in music history")
            if msg:
                sender.send_message(msg)
        else:
            logger.info("No anniversaries found.")
    except Exception as e:
        logger.error(f"Error checking anniversaries: {e}", exc_info=True)

    logger.info("Daily check completed.")

def main():
    logger.info("Navidrome Telegram Bot Starting...")
    
    # Optional: Run once on startup if ENV var set, for debugging
    if os.environ.get("RUN_ON_STARTUP", "false").lower() == "true":
        job()
    
    # Schedule
    schedule_time = os.environ.get("SCHEDULE_TIME", "08:00")
    logger.info(f"Scheduling daily job at {schedule_time}...")
    
    schedule.every().day.at(schedule_time).do(job)
    
    while True:
        schedule.run_pending()
        time.sleep(60)

if __name__ == "__main__":
    main()
