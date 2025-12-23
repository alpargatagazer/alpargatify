import requests
import logging
from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class TelegramSender:
    def __init__(self):
        self.token = get_secret("telegram_bot_token")
        self.chat_id = get_secret("telegram_chat_id")
        self.base_url = f"https://api.telegram.org/bot{self.token}"

    def send_message(self, text, parse_mode="HTML"):
        if not self.token or not self.chat_id:
            logger.error("Telegram token or Chat ID missing.")
            return

        url = f"{self.base_url}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": parse_mode
        }
        
        try:
            r = requests.post(url, json=payload)
            r.raise_for_status()
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to send Telegram message: {e}")

    def format_album_list(self, albums, intro_text):
        if not albums:
            return None
            
        message = f"<b>{intro_text}</b>\n\n"
        
        for album in albums:
            title = album.get("name", "Unknown Album")
            artist = album.get("artist", "Unknown Artist")
            
            # Year or Date
            date_display = str(album.get("year", ""))
            # Upgrade to ReleaseDate if available and longer
            if "releaseDate" in album and len(str(album["releaseDate"])) >= 4:
                date_display = str(album["releaseDate"])
            
            # Tags (Genres)
            genre = album.get("genre", "")
            
            message += f"💿 <b>{title}</b>\n"
            message += f"👤 {artist}\n"
            message += f"📅 {date_display}\n"
            if genre:
                message += f"🏷 {genre}\n"
            message += "\n"
            
        return message
