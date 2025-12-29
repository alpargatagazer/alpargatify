import logging
import math
from functools import wraps
from typing import Optional, List, Dict

import telebot
from telebot.types import Message

from navidrome_client import NavidromeClient
from secrets_loader import get_secret

logger = logging.getLogger(__name__)


class TelegramBot:
    """
    Unified Telegram bot for Navidrome music library.
    Handles both interactive commands (with group authorization) and scheduled notifications.
    """
    def __init__(self):
        """
        Initialize the Telegram bot.
        Loads configuration from secrets and registers command handlers.
        """
        token = get_secret("telegram_bot_token")
        if not token:
            raise ValueError("telegram_bot_token not found in secrets")
        
        self.bot = telebot.TeleBot(token)
        self.navidrome = NavidromeClient()
        
        # Load authorized chat ID(s) - can be single ID or comma-separated list
        chat_ids_str = get_secret("telegram_chat_id", "")
        self.authorized_chat_ids: List[str] = []
        
        if chat_ids_str:
            # Split by comma and clean whitespace
            self.authorized_chat_ids = [cid.strip() for cid in chat_ids_str.split(",") if cid.strip()]
            logger.info(f"Bot authorized for {len(self.authorized_chat_ids)} chat(s): {', '.join(self.authorized_chat_ids)}")
        else:
            logger.warning("No authorized chat IDs configured. Bot will reject all requests.")
        
        # Register command handlers
        self._register_handlers()
    
    
    def _is_authorized(self, chat_id: int) -> bool:
        """
        Check if a command comes from an authorized chat.
        
        :param chat_id: Telegram chat ID to check.
        :return: True if the chat is authorized, False otherwise.
        """
        if not self.authorized_chat_ids:
            return False
        
        # Convert chat_id to string for comparison (can be negative for groups)
        chat_id_str = str(chat_id)
        if chat_id_str in self.authorized_chat_ids:
            return True
        else:
            logger.warning(f"Unauthorized access attempt from chat ID: {chat_id}")
            return False
    
    def authorized_only(self, func):
        """
        Decorator to restrict command access to authorized group chats only.

        :param func: The function to be decorated.
        :return: The decorated function.
        """
        @wraps(func)
        def wrapper(message: Message):
            if not self._is_authorized(message.chat.id):
                self.bot.reply_to(message, "⛔ This bot is only available in the authorized group.")
                return
            return func(message)
        return wrapper
    
    def _register_handlers(self):
        """
        Register all Telegram message and callback handlers.
        """
        @self.bot.message_handler(commands=['start', 'help'])
        @self.authorized_only
        def send_welcome(message: Message):
            """
            Handle /start and /help commands.
            
            :param message: Telegram message object.
            """
            help_text = (
                "👋 *Hello! I am the Navidrome Bot.*\n\n"
                "Available commands:\n"
                "• /search <text> - Search for an artist or album\n"
                "• /random - Suggest a random album\n"
                "• /nowplaying - Show who is listening to what\n"
                "• /genres - Browse albums by genre\n"
                "• /stats - Show server statistics\n"
                "• /help - Show this message\n\n"
                "⚠️ Note: /top command is currently disabled due to Navidrome API limitations."
            )
            self.bot.reply_to(message, help_text, parse_mode="Markdown")
            logger.info(f"User {message.from_user.username} requested help")
        
        @self.bot.message_handler(commands=['stats'])
        @self.authorized_only
        def get_stats(message: Message):
            """
            Handle /stats command to show library statistics.
            
            :param message: Telegram message object.
            """
            logger.info(f"User {message.from_user.username} requested stats")
            try:
                self.bot.reply_to(message, "🔄 Fetching server statistics...")
                stats = self.navidrome.get_server_stats()
                
                if stats:
                    size_bytes = stats.get('size_bytes', 0)
                    formatted_size = self.format_size(size_bytes)
                    
                    stats_text = (
                        "📊 *Navidrome Library Statistics*\n\n"
                        f"💿 Albums: {stats.get('albums', 'N/A')}\n"
                        f"👤 Artists: {stats.get('artists', 'N/A')}\n"
                        f"🎵 Songs: {stats.get('songs', 'N/A')}\n"
                        f"📦 Total Size: {formatted_size}\n"
                    )
                    self.send_message(message.chat.id, stats_text, parse_mode="Markdown")
                else:
                    self.send_message(message.chat.id, "❌ Failed to retrieve statistics.")
                    
            except Exception as e:
                logger.error(f"Error fetching stats: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error: {str(e)}")
        
        @self.bot.message_handler(commands=['random'])
        @self.authorized_only
        def get_random_album(message: Message):
            """
            Handle /random command to suggest a random album from the library.
            
            :param message: Telegram message object.
            """
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
                    self.send_message(message.chat.id, caption, parse_mode="Markdown")
                else:
                    self.bot.reply_to(message, "❌ No albums found in the library.")
                    
            except Exception as e:
                logger.error(f"Error fetching random album: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error: {str(e)}")
        
        @self.bot.message_handler(commands=['search'])
        @self.authorized_only
        def search_music(message: Message):
            """
            Handle /search <query> command to find albums by artist or title.
            
            :param message: Telegram message object.
            """
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
                    self.send_message(message.chat.id, f"❌ No albums found matching '{query}'.")
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
                
                self.send_message(message.chat.id, "\n".join(msg_lines), parse_mode="Markdown")
                
            except Exception as e:
                logger.error(f"Error searching: {e}", exc_info=True)
                self.bot.reply_to(message, f"❌ Error searching: {str(e)}")

        @self.bot.message_handler(commands=['nowplaying'])
        @self.authorized_only
        def now_playing(message: Message):
            """
            Handle /nowplaying command to show real-time playback.
            
            :param message: Telegram message object.
            """
            entries = self.navidrome.get_now_playing()
            if not entries:
                self.bot.reply_to(message, "🤫 Nobody is listening to music right now.")
                return

            msg = "🎧 <b>Now Playing:</b>\n\n"
            for entry in entries:
                user = entry.get('username', 'Someone')
                title = entry.get('title', 'Unknown')
                artist = entry.get('artist', 'Unknown')
                album = entry.get('album', 'Unknown')
                year = entry.get('year', 'Unknown')
                msg += f"👤 <b>{user}</b> is listening to:\n🎵 {title} - {artist} ({album}, {year})\n\n"

            self.send_message(message.chat.id, msg, parse_mode="HTML")

        # NOTE: /top command is preserved but disabled (Navidrome doesn't support global history)
        # @self.bot.message_handler(commands=['top'])
        # @self.authorized_only
        # def top_albums_start(message: Message):
        #     """
        #     Handle /top command to show the period selection menu.
        #     """
        #     from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
        #     markup = InlineKeyboardMarkup()
        #     markup.row(
        #         InlineKeyboardButton("1 Day", callback_data="top:1"),
        #         InlineKeyboardButton("3 Days", callback_data="top:3")
        #     )
        #     markup.row(
        #         InlineKeyboardButton("7 Days", callback_data="top:7"),
        #         InlineKeyboardButton("30 Days", callback_data="top:30")
        #     )
        #     self.bot.send_message(message.chat.id, "📊 Select the period for the Top 10 albums:", reply_markup=markup)

        @self.bot.message_handler(commands=['genres'])
        @self.authorized_only
        def list_genres(message: Message):
            """
            Handle /genres command to list available genres.
            
            :param message: Telegram message object.
            """
            genres = self.navidrome.get_genres()
            if not genres:
                self.bot.reply_to(message, "📭 No genres found.")
                return

            from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
            markup = InlineKeyboardMarkup(row_width=2)
            # Create buttons for each genre
            buttons = [InlineKeyboardButton(g.get('value', 'None'), callback_data=f"genre:{g.get('value', 'None')}") for g in genres if g.get('value')]
            
            # Explicitly add 'None' if it's a valid query but not in the list as 'None'
            if not any(g.get('value') == 'None' for g in genres):
                 buttons.append(InlineKeyboardButton("No Genre", callback_data="genre:None"))
            
            # Limit number of buttons to avoid huge keyboards
            buttons = buttons[:80] 
            
            markup.add(*buttons)
            self.bot.send_message(message.chat.id, "🎷 Select a genre to explore:", reply_markup=markup)

        @self.bot.callback_query_handler(func=lambda call: call.data.startswith('genre:'))
        def handle_callback(call):
            """
            Handle all inline keyboard callback queries (genre selection).
            
            :param call: Telegram callback query object.
            """
            # Preservation of top callback logic (Disabled: Navidrome doesn't support global stats)
            # if call.data.startswith('top:'):
            #     days = int(call.data.split(':')[1])
            #     self.bot.answer_callback_query(call.id, f"Calculating top for {days} days...")
            #     albums = self.navidrome.get_top_albums_from_history(days=days, limit=10)
            #     
            #     if not albums:
            #         self.bot.edit_message_text(f"📉 No playback data found for the last {days} days.", 
            #                                   call.message.chat.id, call.message.message_id)
            #         return
            #
            #     msg = f"🏆 <b>Top 10 Albums ({days} days):</b>\n\n"
            #     for i, alb in enumerate(albums, 1):
            #         msg += f"{i}. <b>{alb.get('name')}</b> - {alb.get('artist')} ({alb.get('playCount')} plays)\n"
            #     
            #     self.bot.edit_message_text(msg, call.message.chat.id, call.message.message_id, parse_mode="HTML")

            if call.data.startswith('genre:'):
                genre = call.data.split(':')[1]
                self.bot.answer_callback_query(call.id, f"Searching for {genre} albums...")
                albums = self.navidrome.get_albums_by_genre(genre, limit=25)
                
                if not albums:
                    self.bot.edit_message_text(f"❓ No albums found for genre '{genre}'.", 
                                              call.message.chat.id, call.message.message_id)
                    return

                # For large lists, we send a new message and delete the menu for a cleaner experience
                intro = f"🎸 Random albums from <b>{genre}</b>:"
                if genre == 'None':
                    intro = "🎸 Random albums with <b>no defined genre</b>:"
                
                msg = self.format_album_list(albums, intro)
                if msg:
                    self.bot.delete_message(call.message.chat.id, call.message.message_id)
                    self.send_message(call.message.chat.id, msg)
    
    def start_polling(self) -> None:
        """
        Start the bot polling loop (blocking).
        """
        logger.info("Starting Telegram bot polling...")
        self.bot.infinity_polling()

    # ========== Notification Methods ==========

    def send_message(self, chat_id: int, text: str, parse_mode: str = "HTML", **kwargs) -> None:
        """
        Send a message to a specific chat, automatically splitting it if it exceeds limits.
        
        :param chat_id: The Telegram chat ID.
        :param text: The message content.
        :param parse_mode: HTML or Markdown.
        :param kwargs: Additional arguments for send_message (e.g., reply_markup).
        """
        # Telegram's message limit is 4096 characters
        max_length = 4096
        messages = self._split_message(text, max_length)
        
        for i, msg in enumerate(messages):
            try:
                # Include kwargs (like reply_markup) only for the last message chunk
                current_kwargs = kwargs if i == len(messages) - 1 else {}
                self.bot.send_message(
                    chat_id=chat_id,
                    text=msg,
                    parse_mode=parse_mode,
                    **current_kwargs
                )
                logger.debug(f"Message sent to chat {chat_id}")
            except Exception as e:
                logger.error(f"Failed to send message to chat {chat_id}: {e}")

    def send_notification(self, text: str, parse_mode: str = "HTML") -> None:
        """
        Send a notification message to all authorized chats.
        Used for scheduled notifications.
        
        :param text: The message content.
        :param parse_mode: HTML or Markdown.
        """
        if not self.authorized_chat_ids:
            logger.error("No authorized chat IDs configured.")
            return

        for chat_id in self.authorized_chat_ids:
            self.send_message(chat_id, text, parse_mode)

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
    def format_size(size_bytes: int) -> str:
        """
        Format a size in bytes into a human-readable string (MB, GB, TB).
        
        :param size_bytes: Size in bytes.
        :return: Formatted string (e.g. "1.2 GB").
        """
        if size_bytes <= 0:
            return "0 B"
        
        size_names = ("B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB")
        i = int(math.floor(math.log(size_bytes, 1024)))
        p = math.pow(1024, i)
        s = round(size_bytes / p, 2)
        return f"{s} {size_names[i]}"

    @staticmethod
    def format_album_list(albums: List[Dict], intro_text: str) -> Optional[str]:
        """
        Format a list of album dictionaries into a readable HTML message.
        Used for both scheduled notifications and command responses.

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
