import logging
from functools import wraps
from typing import Optional, List, Dict

import telebot
from telebot.types import Message

from navidrome_client import NavidromeClient
from secrets_loader import get_secret

logger = logging.getLogger(__name__)


class TelegramBot:
    """
    Interactive Telegram bot for Navidrome music library.
    Handles user commands with authorization via whitelist.
    """
    def __init__(self):
        """
        Initialize the bot with token, chat ID, and authorized user IDs.
        """
        token = get_secret("telegram_bot_token")
        if not token:
            raise ValueError("telegram_bot_token not found in secrets")
        
        self.bot = telebot.TeleBot(token)
        self.navidrome = NavidromeClient()
        self.notification_chat_id: Optional[str] = get_secret("telegram_chat_id")
        
        # Load authorized user IDs from secret
        user_ids_str = get_secret("telegram_user_ids", "")
        self.allowed_user_ids: List[int] = []
        
        if user_ids_str:
            try:
                self.allowed_user_ids = [int(uid.strip()) for uid in user_ids_str.split(",") if uid.strip()]
                logger.info(f"Loaded {len(self.allowed_user_ids)} authorized user IDs")
            except ValueError as e:
                logger.error(f"Error parsing telegram_user_ids: {e}")
        else:
            logger.warning("No authorized user IDs configured. Bot will reject all requests.")
        
        # Register command handlers
        self._register_handlers()
    
    def _is_authorized(self, user_id: int, username: Optional[str] = None) -> bool:
        """
        Check if a user is authorized to use the bot.
        
        :param user_id: Telegram user ID
        :param username: Telegram username (for logging)
        :return: True if authorized, False otherwise
        """
        if user_id in self.allowed_user_ids:
            return True
        else:
            logger.warning(f"Unauthorized access attempt from: {username or 'Unknown'} (ID: {user_id})")
            return False
    
    def authorized_only(self, func):
        """
        Decorator to restrict commands to authorized users only.
        """
        @wraps(func)
        def wrapper(message: Message):
            if not self._is_authorized(message.from_user.id, message.from_user.username):
                self.bot.reply_to(message, "⛔ You are not authorized to use this bot.")
                return
            return func(message)
        return wrapper
    
    def _register_handlers(self):
        """
        Register all bot command handlers.
        """
        @self.bot.message_handler(commands=['start', 'help'])
        @self.authorized_only
        def send_welcome(message: Message):
            help_text = (
                "👋 *Hello! I am the Navidrome Bot.*\n\n"
                "Available commands:\n"
                "• /search <text> - Search for an artist or album\n"
                "• /random - Suggest a random album\n"
                "• /stats - Show server statistics\n"
                "• /help - Show this message"
            )
            self.bot.reply_to(message, help_text, parse_mode="Markdown")
            logger.info(f"User {message.from_user.username} requested help")
        
        @self.bot.message_handler(commands=['stats'])
        @self.authorized_only
        def get_stats(message: Message):
            logger.info(f"User {message.from_user.username} requested stats")
            try:
                self.bot.reply_to(message, "🔄 Fetching server statistics...")
                stats = self.navidrome.get_server_stats()
                
                if stats:
                    stats_text = (
                        "📊 *Navidrome Library Statistics*\n\n"
                        f"💿 Albums: {stats.get('albums', 'N/A')}\n"
                        f"👤 Artists: {stats.get('artists', 'N/A')}\n"
                        f"🎵 Songs: {stats.get('songs', 'N/A')}\n"
                    )
                    self.bot.send_message(message.chat.id, stats_text, parse_mode="Markdown")
                else:
                    self.bot.send_message(message.chat.id, "❌ Failed to retrieve statistics.")
                    
            except Exception as e:
                logger.error(f"Error fetching stats: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error: {str(e)}")
        
        @self.bot.message_handler(commands=['random'])
        @self.authorized_only
        def get_random_album(message: Message):
            logger.info(f"User {message.from_user.username} requested random album")
            try:
                self.bot.reply_to(message, "🎲 Finding a random album...")
                album = self.navidrome.get_random_album()
                
                if album:
                    title = album.get('name', 'Unknown')
                    artist = album.get('artist', 'Unknown')
                    year = album.get('year', '')
                    cover_id = album.get('coverArt')
                    
                    # Build caption with year and genres
                    caption = f"🎲 *Why not listen to this?*\n\n💿 *{title}*\n👤 {artist}"
                    
                    if year:
                        caption += f"\n📅 {year}"
                    
                    # Add genres if available (check both 'genres' list and 'genre' string)
                    genre_str = ""
                    if "genres" in album and album["genres"]:
                        g_list = album["genres"]
                        if isinstance(g_list, list):
                            names = [g.get("name") for g in g_list if isinstance(g, dict) and "name" in g]
                            if names:
                                genre_str = ", ".join(names)
                    
                    # Fallback to simple 'genre' if empty
                    if not genre_str:
                        genre_str = album.get('genre', '')
                    
                    if genre_str:
                        caption += f"\n🏷 {genre_str}"
                    
                    # Try to send with cover art
                    if cover_id:
                        try:
                            cover_bytes = self.navidrome.get_cover_art_bytes(cover_id)
                            if cover_bytes:
                                self.bot.send_photo(
                                    message.chat.id,
                                    cover_bytes,
                                    caption=caption,
                                    parse_mode="Markdown"
                                )
                                return
                        except Exception as e:
                            logger.warning(f"Failed to send cover art: {e}")
                    
                    # Fallback: send as text only
                    self.bot.send_message(message.chat.id, caption, parse_mode="Markdown")
                else:
                    self.bot.reply_to(message, "❌ No albums found in the library.")
                    
            except Exception as e:
                logger.error(f"Error fetching random album: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error: {str(e)}")
        
        @self.bot.message_handler(commands=['search'])
        @self.authorized_only
        def search_music(message: Message):
            # Extract query from message: "/search radiohead" -> "radiohead"
            # Remove command and bot mentions (e.g., @botname)
            query = message.text.replace("/search", "").strip()
            
            # Remove bot mention if present (e.g., @alpargatibot)
            if query.startswith('@'):
                parts = query.split(maxsplit=1)
                query = parts[1] if len(parts) > 1 else ""
            
            query = query.strip()
            
            if not query:
                self.bot.reply_to(
                    message, 
                    "Please provide a search term. Example: `/search Radiohead`", 
                    parse_mode="Markdown"
                )
                return
            
            logger.info(f"User {message.from_user.username} searching for: {query}")
            
            try:
                self.bot.reply_to(message, f"🔎 Searching for '{query}'...")
                results = self.navidrome.search_albums(query, limit=50)
                
                if not results:
                    self.bot.send_message(message.chat.id, f"❌ No albums found matching '{query}'.")
                    return
                
                msg_lines = [f"🔎 *Results for '{query}':*\n"]
                
                for album in results:
                    name = album.get('name', 'Unknown')
                    artist = album.get('artist', 'Unknown')
                    year = album.get('year', '')
                    
                    # Get genres (check both 'genres' list and 'genre' string)
                    genre_str = ""
                    if "genres" in album and album["genres"]:
                        g_list = album["genres"]
                        if isinstance(g_list, list):
                            names = [g.get("name") for g in g_list if isinstance(g, dict) and "name" in g]
                            if names:
                                genre_str = ", ".join(names)
                    
                    # Fallback to simple 'genre' if empty
                    if not genre_str:
                        genre_str = album.get('genre', '')
                    
                    line = f"• {artist} - {name}"
                    if year:
                        line += f" 📅 {year}"
                    if genre_str:
                        line += f" 🏷 {genre_str}"
                    
                    msg_lines.append(line)
                
                self.bot.send_message(message.chat.id, "\n".join(msg_lines), parse_mode="Markdown")
                
            except Exception as e:
                logger.error(f"Error searching: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error searching: {str(e)}")
    
    def start_polling(self):
        """
        Start the bot polling loop. This is a blocking call.
        """
        logger.info("Starting Telegram bot polling...")
        self.bot.infinity_polling()

    # ========== Notification Methods (for scheduled messages) ==========

    def send_notification(self, text: str, parse_mode: str = "HTML") -> None:
        """
        Send a notification message to the configured chat ID.
        Automatically splits messages that exceed Telegram's 4096 character limit.
        Used for scheduled notifications (new albums, anniversaries).
        
        :param text: The message content.
        :param parse_mode: HTML or Markdown.
        """
        if not self.notification_chat_id:
            logger.error("Notification chat ID not configured.")
            return

        # Telegram's message limit is 4096 characters
        max_length = 4096
        messages = self._split_message(text, max_length)
        
        for msg in messages:
            try:
                self.bot.send_message(
                    chat_id=self.notification_chat_id,
                    text=msg,
                    parse_mode=parse_mode
                )
                logger.debug("Notification sent successfully.")
            except Exception as e:
                logger.error(f"Failed to send notification: {e}")

    @staticmethod
    def _split_message(text: str, max_length: int) -> List[str]:
        """
        Split a message into chunks that fit within Telegram's character limit.
        Tries to split at album boundaries (double newlines) to keep albums together.
        
        :param text: The full message text.
        :param max_length: Maximum characters per message.
        :return: List of message chunks.
        """
        if len(text) <= max_length:
            return [text]
        
        chunks = []
        # Split by album entries (double newline)
        albums = text.split('\n\n')
        
        current_chunk = ""
        for album in albums:
            # Check if adding this album would exceed the limit
            test_chunk = current_chunk + album + '\n\n' if current_chunk else album + '\n\n'
            
            if len(test_chunk) > max_length:
                # If current chunk has content, save it
                if current_chunk:
                    chunks.append(current_chunk.rstrip())
                    current_chunk = album + '\n\n'
                else:
                    # Single album is too long, force split it
                    chunks.append(album[:max_length])
                    logger.warning(f"Album entry exceeded max length, truncated.")
            else:
                current_chunk = test_chunk
        
        # Add the last chunk if it has content
        if current_chunk:
            chunks.append(current_chunk.rstrip())
        
        logger.info(f"Split message into {len(chunks)} parts.")
        return chunks

    @staticmethod
    def format_album_list(albums: List[Dict], intro_text: str) -> Optional[str]:
        """
        Format a list of album dictionaries into a readable HTML message.
        Used for scheduled notifications.

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
