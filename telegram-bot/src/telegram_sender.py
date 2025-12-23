import requests
import logging
from typing import List, Dict, Optional, Any
from secrets_loader import get_secret

logger = logging.getLogger(__name__)

class TelegramSender:
    """
    Handles formatting and sending messages to Telegram via the Bot API.
    """
    def __init__(self):
        """
        Initialize the Telegram sender with credentials.
        """
        self.token: Optional[str] = get_secret("telegram_bot_token")
        self.chat_id: Optional[str] = get_secret("telegram_chat_id")
        self.base_url: str = f"https://api.telegram.org/bot{self.token}"

    def send_message(self, text: str, parse_mode: str = "HTML") -> None:
        """
        Send a text message to the configured Chat ID.
        
        :param text: The message content.
        :param parse_mode: HTML or MarkdownV2.
        """
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

    def format_album_list(self, albums: List[Dict[str, Any]], intro_text: str) -> Optional[str]:
        """
        Format a list of album dictionaries into a readable HTML message.
        
        :param albums: List of album objects from Navidrome API.
        :param intro_text: Header text for the message.
        :return: Formatted string or None if list is empty.
        """
        if not albums:
            return None
            
        message = f"<b>{intro_text}</b>\n\n"
        
        for album in albums:
            title = album.get("name", "Unknown Album")
            artist = album.get("artist", "Unknown Artist")
            
            # Year or Date
            date_display = str(album.get("year", ""))
            # Upgrade to ReleaseDate if available
            if "releaseDate" in album:
                rd = album["releaseDate"]
                if isinstance(rd, dict):
                    # Format dict {'year': 2021, 'month': 2, 'day': 23} to 2021-02-23
                    y = rd.get('year', '????')
                    m = rd.get('month', 1)
                    d = rd.get('day', 1)
                    date_display = f"{y}-{m:02d}-{d:02d}"
                elif len(str(rd)) >= 4:
                     date_display = str(rd)
            
            # Tags (Genres)
            genre_str = ""
            if "genres" in album:
                g_list = album["genres"]
                if isinstance(g_list, list):
                    names = [g.get("name") for g in g_list if isinstance(g, dict) and "name" in g]
                    if names:
                        genre_str = ", ".join(names)
            
            # Fallback to simple 'genre' if empty
            if not genre_str:
                genre_str = album.get("genre", "")
            
            message += f"💿 <b>{title}</b>\n"
            message += f"👤 {artist}\n"
            message += f"📅 {date_display}\n"
            if genre_str:
                message += f"🏷 {genre_str}\n"
            message += "\n"
            
        return message
