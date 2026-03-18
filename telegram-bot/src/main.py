import datetime
import logging
import os
import sys
import threading
import time

import schedule

from navidrome_client import NavidromeClient
from telegram_bot import TelegramBot
import recommendations
import credentials_db

# Configure Logging
log_level_str: str = os.environ.get("LOGGING", "INFO").upper()
log_level: int = getattr(logging, log_level_str, logging.INFO)

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

# Global bot instance (shared between scheduler and polling threads)
bot_instance: TelegramBot = None

def daily_job() -> None:
    """
    Scheduled job that checks for new albums and anniversaries.
    Uses the global bot instance for sending notifications.
    """
    logger.info(f"Starting daily check at {datetime.datetime.now()}")
    
    client = NavidromeClient()
    
    # 1. New Albums (Last 24h)
    logger.info("Checking for new albums...")
    try:
        new_albums = client.get_new_albums(hours=24)
        if new_albums:
            logger.info(f"Found {len(new_albums)} new albums.")
            msg = bot_instance.format_album_list(new_albums, "🆕 Freshly Added Albums (Last 24h)")
            logger.debug(f"Message: {msg}")
            if msg:
                bot_instance.send_notification(msg)
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
            msg = bot_instance.format_album_list(anniversaries, f"🎂 On this day ({now.strftime('%B %d')}) in music history")
            logger.debug(f"Message: {msg}")
            if msg:
                bot_instance.send_notification(msg)
        else:
            logger.info("No anniversaries found.")
    except Exception as e:
        logger.error(f"Error checking anniversaries: {e}", exc_info=True)

    logger.info("Daily check completed.")


def purge_inactive_users_job() -> None:
    """
    Scheduled job that purges users who haven't logged into Navidrome
    in over 30 days from the credentials database.
    """
    logger.info("Starting inactive user purge check...")
    try:
        admin_client = NavidromeClient()
        purged = recommendations.purge_inactive_users(admin_client, max_days=30)
        if purged:
            logger.info(f"Purged {len(purged)} inactive user(s): {', '.join(purged)}")
        else:
            logger.info("No inactive users to purge.")
    except Exception as e:
        logger.error(f"Error during user purge: {e}", exc_info=True)


def run_scheduler():
    """
    Run the scheduled job loop in a separate thread.
    """
    logger.info("Scheduler thread started")
    
    # Optional: Run once on startup if ENV var set
    if os.environ.get("RUN_ON_STARTUP", "false").lower() == "true":
        daily_job()
    
    # Schedule daily job
    schedule_time = os.environ.get("SCHEDULE_TIME", "08:00")
    logger.info(f"Scheduling daily job at {schedule_time}")
    schedule.every().day.at(schedule_time).do(daily_job)
    
    # Schedule inactive user purge (daily at 04:00)
    logger.info("Scheduling daily inactive user purge at 04:00")
    schedule.every().day.at("04:00").do(purge_inactive_users_job)
    
    while True:
        schedule.run_pending()
        time.sleep(60)

def run_bot_polling():
    """
    Run the Telegram bot polling loop in a separate thread.
    Uses the global bot instance.
    """
    logger.info("Bot polling thread started")
    try:
        bot_instance.start_polling()
    except Exception as e:
        logger.error(f"Bot polling error: {e}", exc_info=True)

def main() -> None:
    """
    Main entrypoint for the application. Runs scheduler and bot polling concurrently.
    """
    global bot_instance
    
    logger.info("Navidrome Telegram Bot Starting...")
    
    # Initialize the database to ensure tables exist
    try:
        credentials_db.init_db()
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}", exc_info=True)
        sys.exit(1)
    
    # Initialize single bot instance shared by both threads
    bot_instance = TelegramBot()
    
    # Create threads for scheduler and bot polling
    scheduler_thread = threading.Thread(target=run_scheduler, daemon=True, name="Scheduler")
    bot_thread = threading.Thread(target=run_bot_polling, daemon=True, name="BotPolling")
    
    # Start all threads
    scheduler_thread.start()
    bot_thread.start()
    
    logger.info("All threads started (scheduler, bot polling)")
    
    # Keep main thread alive
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down gracefully...")

if __name__ == "__main__":
    main()
