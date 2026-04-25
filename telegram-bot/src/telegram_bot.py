import threading
import logging
import math
import re
import time
from functools import wraps
from typing import Optional, List, Dict

import telebot
from telebot.types import Message, InputMediaPhoto

import credentials_db
import user_activity
from navidrome_client import NavidromeClient
from secrets_loader import get_secret
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

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
        
        self.authorized_users_cache = {}  # user_id -> (is_authorized, timestamp)
        self.bot = telebot.TeleBot(token)
        
        # Configure global retries for Telegram API interactions
        # This fixes intermittent 'Network is unreachable' errors during send_message
        retry_strategy = Retry(
            total=5,
            backoff_factor=2,  # Increase backoff (2s, 4s, 8s, 16s, 32s)
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET", "POST"]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        
        # Create a new session with the adapter and assign it to apihelper
        # This ensures proper initialization and usage of retries
        session = requests.Session()
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        telebot.apihelper.session = session

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
    
    
    def _is_authorized(self, message: Message) -> bool:
        """
        Check if a command comes from an authorized chat.
        Handle private chats by checking membership in authorized groups.
        
        :param message: Telegram message object.
        :return: True if the chat/user is authorized, False otherwise.
        """
        if not self.authorized_chat_ids:
            return False
        
        # 1. Direct match with authorized groups
        chat_id_str = str(message.chat.id)
        if chat_id_str in self.authorized_chat_ids:
            return True
        
        # 2. For private chats, we must check if the user belongs to one of the authorized groups.
        # However, bots cannot arbitrarily query get_chat_member for any user ID unless the bot 
        # has seen the user in the group or the user has interacted with the bot.
        if message.chat.type == 'private':
            user_id = message.from_user.id
            now = time.time()
            
            # Check cache (1 hour TTL)
            if user_id in self.authorized_users_cache:
                is_auth, last_check = self.authorized_users_cache[user_id]
                if now - last_check < 3600:
                    return is_auth
            
            # Not in cache or expired, check membership
            is_member = False
            for group_id in self.authorized_chat_ids:
                try:
                    chat_member = self.bot.get_chat_member(group_id, user_id)
                    # chat_member.status can be 'creator', 'administrator', 'member', 'restricted', 'left', 'kicked'
                    if chat_member.status in ['creator', 'administrator', 'member', 'restricted']:
                        is_member = True
                        break
                except Exception as e:
                    # Log at debug to avoid spam, usually means user not found or bot not in group
                    logger.debug(f"Failed to check membership for user {user_id} in {group_id}: {e}")
                    continue
            
            # Cache results
            self.authorized_users_cache[user_id] = (is_member, now)
            
            if is_member:
                return True
            else:
                logger.warning(f"Unauthorized DM attempt from user: {message.from_user.username} ({user_id}). Bot may not know them yet.")
                self.bot.reply_to(
                    message, 
                    "⛔ Sorry, I can only interact with members of authorized groups.\n\n"
                    "*Tip*: If you are in the group, try sending any message in the group first so I can re-sync my user list, then try sending me a DM again.",
                    parse_mode="Markdown"
                )
                return False

        logger.warning(f"Unauthorized access attempt from chat ID: {message.chat.id} ({message.chat.type})")
        return False
    
    def authorized_only(self, allow_dms=False):
        """
        Decorator to restrict command access to authorized group chats.
        Optionally allows access via private DMs if the user is a group member.

        :param allow_dms: If True, authorized group members can use this command in private DMs.
        :return: The decorated function.
        """
        def decorator(func):
            @wraps(func)
            def wrapper(message: Message, *args, **kwargs):
                if not self._is_authorized(message):
                    # _is_authorized already sends a reply for DMs, so only reply broadly here for groups if needed
                    if message.chat.type != 'private':
                        self.bot.reply_to(message, "⛔ This bot is only available for authorized groups.")
                    return
                
                # Check DM restriction
                if message.chat.type == 'private' and not allow_dms:
                    self.bot.reply_to(message, "⚠️ This command can only be used in the group chat, not in private messages.")
                    return
                    
                return func(message, *args, **kwargs)
            return wrapper
        return decorator
    
    def _register_handlers(self):
        """
        Register all Telegram message and callback handlers.
        """
        @self.bot.message_handler(commands=['start', 'help'])
        @self.authorized_only(allow_dms=True)
        def send_welcome(message: Message):
            """
            Handle /start and /help commands.
            
            :param message: Telegram message object.
            """
            help_text = (
                "👋 *Hello! I am the Navidrome Bot.*\n\n"
                "Available commands:\n"
                "• /search <text> - Search for an artist or album\n"
                "• /year <year> - Discover albums from a specific year or decade\n"
                "• /random - Suggest a random album\n"
                "• /recent - Show recently added albums\n"
                "• /nowplaying - Show who is listening to what\n"
                "• /genres - Browse albums by genre\n"
                "• /recommend - Get music recommendations from other users\n"
                "• /stats - Show server statistics\n"
                "• /help - Show this message\n\n"
                "🔒 *Private Commands (DM only)*:\n"
                "• /login <user> <pass> - Store credentials to share your favorites\n"
            )
            self.bot.reply_to(message, help_text, parse_mode="Markdown")
            logger.info(f"User {message.from_user.username} requested help")
        
        @self.bot.message_handler(commands=['stats'])
        @self.authorized_only(allow_dms=False)
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
        @self.authorized_only(allow_dms=False)
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
                    
                    # Extract album type tag (EP, Single, Live, etc.)
                    type_tag = self._get_album_type_tag(album)
                    
                    # Build caption with year and genres
                    caption = f"🎲 *Why not listen to this?*\n\n💿 *{title}*{type_tag}\n👤 {artist}"
                    
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
        @self.authorized_only(allow_dms=False)
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
                # ForceReply flow
                force_reply = telebot.types.ForceReply(selective=True)
                self.bot.reply_to(
                    message, 
                    "🔎 What do you want to search for?", 
                    reply_markup=force_reply
                )
                return
            
            self._perform_search(message, query)

        @self.bot.message_handler(func=lambda m: m.reply_to_message and m.reply_to_message.text and "what do you want to search for?" in m.reply_to_message.text.lower())
        @self.authorized_only(allow_dms=False)
        def handle_search_reply(message: Message):
            """
            Handle the reply to the ForceReply search prompt.
            """
            query = message.text.strip()
            if query:
                self._perform_search(message, query)


        @self.bot.message_handler(commands=['nowplaying'])
        @self.authorized_only(allow_dms=False)
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
                album_name = entry.get('album', 'Unknown')
                year = entry.get('year', 'Unknown')
                album_id = entry.get('albumId')
                
                # Try to get album type from cache for more context
                type_tag = ""
                if album_id:
                    # sync_library(force=False) returns the list of enriched albums
                    all_albums = self.navidrome.sync_library(force=False)
                    # Find this specific album to get its release type
                    album_obj = next((a for a in all_albums if a.get('id') == album_id), None)
                    if album_obj:
                        type_tag = self._get_album_type_tag(album_obj)
                
                msg += f"👤 <b>{user}</b> is listening to:\n🎵 {artist} - {title} ({album_name}{type_tag}, {year})\n\n"

            self.send_message(message.chat.id, msg, parse_mode="HTML")

        # NOTE: /top command is preserved but disabled (Navidrome doesn't support global history)
        # @self.bot.message_handler(commands=['top'])
        # @self.authorized_only(allow_dms=False)
        # def top_albums_start(message: Message):
        #     """
        #     Handle /top command to show the global top albums.
        #     """
        #     pass

        @self.bot.message_handler(commands=['genres'])
        @self.authorized_only(allow_dms=False)
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

    
        @self.bot.message_handler(commands=['year'])
        @self.authorized_only(allow_dms=False)
        def filter_by_year(message: Message):
            """
            Handle /year command.
            Usage:
            - /year 1994 -> Albums from 1994
            - /year 90s -> Albums from 1990-1999
            - /year -> Show buttons for decades
            """
            # Extract argument
            arg = message.text.replace("/year", "").strip()
            
            # Remove bot mention if present (e.g., @alpargatibot)
            if arg.startswith('@'):
                parts = arg.split(maxsplit=1)
                arg = parts[1] if len(parts) > 1 else ""
            
            arg = arg.strip()
            
            if not arg:
                # Show decades menu
                from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
                markup = InlineKeyboardMarkup(row_width=3)
                
                buttons = []
                decades = ["50s", "60s", "70s", "80s", "90s", "00s", "10s", "20s"]
                for d in decades:
                    buttons.append(InlineKeyboardButton(d, callback_data=f"year:{d}"))
                
                # Add current year
                current_year = datetime.datetime.now().year
                buttons.append(InlineKeyboardButton(f"Current ({current_year})", callback_data=f"year:{current_year}"))
                
                markup.add(*buttons)
                self.bot.send_message(message.chat.id, "📅 Select a decade or year:", reply_markup=markup)
                return

            self._process_year_request(message.chat.id, arg)


        @self.bot.message_handler(commands=['recent'])
        @self.authorized_only(allow_dms=False)
        def get_recent_albums_handler(message: Message):
            self.get_recent_albums(message)

        @self.bot.message_handler(commands=['recommend'])
        @self.authorized_only(allow_dms=False)
        def recommend_start(message: Message):
            """
            Handle /recommend command. Shows type selection menu.
            """
            logger.info(f"User {message.from_user.username} requested recommendations")
            from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
            markup = InlineKeyboardMarkup(row_width=3)
            markup.add(
                InlineKeyboardButton("🎵 Songs (20)", callback_data="rec_type:song"),
                InlineKeyboardButton("💿 Albums (10)", callback_data="rec_type:album"),
                InlineKeyboardButton("👤 Artists (5)", callback_data="rec_type:artist")
            )
            self.bot.send_message(
                message.chat.id,
                "🎯 <b>Recommendations</b>\n\nWhat type of recommendations do you want?",
                reply_markup=markup,
                parse_mode="HTML"
            )

        @self.bot.callback_query_handler(func=lambda call: call.data.startswith('rec_type:'))
        def handle_rec_type(call):
            """Handle recommendation type selection -> show user selection."""
            item_type = call.data.split(':')[1]
            self.bot.answer_callback_query(call.id, "Validating active users...")

            base_url = self.navidrome._base_url or ""
            users = user_activity.validate_and_get_users(base_url)
            if not users:
                self.bot.edit_message_text(
                    "⚠️ No users have registered yet. To share your favorites, "
                    "send me a private message (DM) with: \n`/login username password`",
                    call.message.chat.id, call.message.message_id, parse_mode="Markdown"
                )
                return

            from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
            markup = InlineKeyboardMarkup(row_width=2)
            markup.add(InlineKeyboardButton("🎲 Random", callback_data=f"rec_user:{item_type}:__random__"))
            for user in users:
                markup.add(InlineKeyboardButton(f"👤 {user}", callback_data=f"rec_user:{item_type}:{user}"))

            type_labels = {'song': 'songs', 'album': 'albums', 'artist': 'artists'}
            self.bot.edit_message_text(
                f"🎯 <b>{type_labels.get(item_type, item_type).capitalize()} Recommendations</b>\n\n"
                f"Whose recommendations would you like to get?",
                call.message.chat.id, call.message.message_id,
                reply_markup=markup,
                parse_mode="HTML"
            )

        @self.bot.callback_query_handler(func=lambda call: call.data.startswith('rec_user:'))
        def handle_rec_user(call):
            """Handle recommendation user selection -> fetch and display."""
            parts = call.data.split(':', 2)
            item_type = parts[1]
            chosen_user = parts[2]
            self.bot.answer_callback_query(call.id, "⏳ Fetching recommendations...")

            # Delete the menu
            self.bot.delete_message(call.message.chat.id, call.message.message_id)

            limits = {'song': 20, 'album': 10, 'artist': 5}
            limit = limits.get(item_type, 10)
            base_url = self.navidrome._base_url or ""

            try:
                if chosen_user == '__random__':
                    # Try to exclude the current user if we can identify them
                    caller_nd_user = credentials_db.get_navidrome_user_by_telegram_id(call.from_user.id)
                    result = user_activity.get_random_user_recommendations(
                        item_type, limit, base_url, exclude_username=caller_nd_user
                    )
                    if not result or not result.get('items'):
                        self.send_message(call.message.chat.id,
                            "❌ No favorites found for any user.")
                        return
                    source_user = result['username']
                    items = result['items']
                else:
                    items = user_activity.get_recommendations(
                        chosen_user, item_type, limit, base_url
                    )
                    source_user = chosen_user
                    if items is None:
                        self.send_message(call.message.chat.id,
                            f"❌ Could not get favorites for {chosen_user}.")
                        return

                if not items:
                    self.send_message(call.message.chat.id,
                        f"📭 {source_user} has no favorites of this type.")
                    return

                self._format_and_send_recommendations(
                    call.message.chat.id, source_user, item_type, items
                )

            except Exception as e:
                logger.error(f"Error fetching recommendations: {e}", exc_info=True)
                self.send_message(call.message.chat.id, f"❌ Error: {str(e)}")

        @self.bot.message_handler(commands=['login'])
        @self.authorized_only(allow_dms=True)
        def handle_login(message: Message):
            """
            Handle /login command in DMs only.
            Supports both "/login user pass" and interactive step-by-step mode.
            """
            if message.chat.type != 'private':
                self.send_message(
                    message.chat.id, 
                    "⚠️ The `/login` command can only be used in private messages (DM) with me for security."
                )
                return

            parts = message.text.split(' ', 2)
            
            # Case 1: Credentials provided in the command line
            if len(parts) >= 3:
                # Delete the message as quickly as possible to hide the password
                try:
                    self.bot.delete_message(message.chat.id, message.message_id)
                except Exception as e:
                    logger.warning(f"Failed to delete /login message: {e}")
                
                username = parts[1].strip()
                password = parts[2].strip()
                
                if not username or not password:
                    self.send_message(message.chat.id, "❌ Username and password cannot be blank.")
                    return
                
                self._process_login(message, username, password)
                return

            # Case 2: Interactive login
            msg = self.bot.send_message(message.chat.id, "👤 Please enter your Navidrome **username**:", parse_mode="Markdown")
            self.bot.register_next_step_handler(msg, self._login_step_get_username)

        @self.bot.callback_query_handler(func=lambda call: call.data.startswith('genre:') or call.data.startswith('year:'))
        def handle_callback(call):
            """
            Handle all inline keyboard callback queries (genre and year selection).
            """
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
                    self.send_message(call.message.chat.id, msg, parse_mode="HTML")
            
            elif call.data.startswith('year:'):
                arg = call.data.split(':')[1]
                self.bot.answer_callback_query(call.id, f"Selecting {arg}...")
                
                # Delete the menu message
                self.bot.delete_message(call.message.chat.id, call.message.message_id)
                self._process_year_request(call.message.chat.id, arg)

    # --- Login Step Handlers (Class Methods) ---

    def _login_step_get_username(self, message: Message):
        """Interactive login: Get username step."""
        username = message.text.strip()
        if not username:
            msg = self.bot.reply_to(message, "❌ Username cannot be blank. Please try again:")
            self.bot.register_next_step_handler(msg, self._login_step_get_username)
            return
            
        msg = self.bot.send_message(message.chat.id, "🔑 Now enter your **password**:", parse_mode="Markdown")
        self.bot.register_next_step_handler(msg, self._login_step_get_password, username)

    def _login_step_get_password(self, message: Message, username: str):
        """Interactive login: Get password step."""
        # Delete the password message immediately
        try:
            self.bot.delete_message(message.chat.id, message.message_id)
        except Exception as e:
            logger.warning(f"Failed to delete password message in interactive flow: {e}")

        password = message.text.strip()
        if not password:
            msg = self.bot.send_message(message.chat.id, "❌ Password cannot be blank. Please try again:")
            self.bot.register_next_step_handler(msg, self._login_step_get_password, username)
            return

        self._process_login(message, username, password)

    def _process_login(self, message: Message, username: str, password: str):
        """
        Shared logic to validate credentials, store them, and start initial sync.
        """
        bot_msg = self.bot.send_message(message.chat.id, "⏳ Verifying credentials with Navidrome...")
        
        base_url = self.navidrome._base_url or ""
        if not base_url:
            self.bot.edit_message_text("❌ Error: Navidrome URL not configured.", message.chat.id, bot_msg.message_id)
            return

        try:
            # Validate credentials using a ping request
            client = NavidromeClient.from_credentials(base_url, username, password)
            response = client._request('ping')
            
            if not response or response.get('status') != 'ok':
                self.bot.edit_message_text(
                    "❌ Invalid credentials. Check your username and password and try again.",
                    message.chat.id, bot_msg.message_id
                )
                return

            # Store credentials with Telegram ID association
            credentials_db.upsert_credential(username, password, telegram_id=message.from_user.id)
            logger.info(f"Credentials stored via DM for user: {username} (TG: {message.from_user.id})")

            # Start initial sync in background
            def _initial_sync():
                try:
                    user_activity.sync_user_starred(username, password, base_url)
                    logger.info(f"Initial favorites sync completed for {username}")
                    self.send_message(message.chat.id, f"✅ Your favorites have been successfully synchronized.")
                except Exception as e:
                    logger.error(f"Initial sync failed for {username}: {e}")
            
            threading.Thread(target=_initial_sync, daemon=True).start()

            self.bot.edit_message_text(
                f"✅ Credentials verified and saved for <b>{username}</b>.\n\n"
                f"Your favorites are syncing in the background. You can now return to the group and use <code>/recommend</code>.",
                message.chat.id, bot_msg.message_id, parse_mode="HTML"
            )

        except Exception as e:
            err_msg = str(e).lower()
            if "wrong username or password" in err_msg or "code: 40" in err_msg:
                user_friendly_err = "❌ Invalid credentials. Please check your Navidrome username and password."
            elif "network" in err_msg or "connection" in err_msg:
                user_friendly_err = "❌ Connection error. The bot could not reach the Navidrome server."
            else:
                user_friendly_err = "❌ An error occurred while verifying the credentials."
                
            logger.error(f"Login error for user {username}: {e}", exc_info=True)
            self.bot.edit_message_text(user_friendly_err, message.chat.id, bot_msg.message_id)

    
    def _format_and_send_recommendations(
        self, chat_id: int, source_user: str, item_type: str, items: list
    ) -> None:
        """
        Format and send recommendations to the chat.

        :param chat_id: Telegram chat ID.
        :param source_user: Username whose favorites are being recommended.
        :param item_type: One of 'song', 'album', 'artist'.
        :param items: List of item dicts from the Subsonic API.
        """
        type_labels = {'song': 'songs', 'album': 'albums', 'artist': 'artists'}
        type_emojis = {'song': '🎵', 'album': '💿', 'artist': '👤'}
        label = type_labels.get(item_type, item_type)
        emoji = type_emojis.get(item_type, '🎯')

        type_labels = {'song': 'songs', 'album': 'albums', 'artist': 'artists'}
        type_emojis = {'song': '🎵', 'album': '💿', 'artist': '👤'}
        emoji = type_emojis.get(item_type, '🎯')

        header = f"🎯 <b>{label.capitalize()} Recommendations</b>\n📌 Based on favorites by <b>{source_user}</b>"
        
        if item_type == 'song':
            lines = [header, ""]
            for item in items:
                title = item.get('title', 'Unknown')
                artist = item.get('artist', 'Unknown')
                album = item.get('album', '')
                genre = item.get('genre', '')
                
                line = f"{emoji} <b>{title}</b> — {artist}"
                if album:
                    line += f" ({album})"
                if genre:
                    line += f" 🏷 {genre}"
                lines.append(line)
            
            self.send_message(chat_id, "\n".join(lines), parse_mode="HTML")

        elif item_type == 'album':
            lines = [header, ""]
            media_group = []
            
            for item in items:
                name = item.get('name', item.get('album', 'Unknown'))
                artist = item.get('artist', item.get('albumArtist', 'Unknown'))
                year = item.get('year', '')
                genre = item.get('genre', '')
                cover_id = item.get('coverArt')
                
                line = f"{emoji} <b>{name}</b> — {artist}"
                if year:
                    line += f" 📅 {year}"
                if genre:
                    line += f" 🏷 {genre}"
                lines.append(line)

                if cover_id:
                    try:
                        photo_bytes = self.navidrome.get_cover_art_bytes(cover_id)
                        if photo_bytes:
                            media_group.append(InputMediaPhoto(photo_bytes))
                    except Exception as e:
                        logger.warning(f"Failed to fetch cover for album {name}: {e}")

            full_caption = "\n".join(lines)
            
            if media_group:
                # Truncate caption if it exceeds Telegram's 1024 limit for media captions
                if len(full_caption) > 1024:
                    full_caption = full_caption[:1021] + "..."
                
                # Assign the full caption to the FIRST item in the group
                media_group[0].caption = full_caption
                media_group[0].parse_mode = "HTML"
                
                for k in range(0, len(media_group), 10):
                    self.bot.send_media_group(chat_id, media_group[k:k+10])
            else:
                self.send_message(chat_id, full_caption, parse_mode="HTML")

        elif item_type == 'artist':
            lines = [header, ""]
            media_group = []
            
            for item in items:
                name = item.get('name', 'Unknown')
                artist_id = item.get('id')
                
                genres = []
                if artist_id:
                    try:
                        genres = self.navidrome.get_artist_genres(artist_id)
                    except Exception as e:
                        logger.warning(f"Failed to fetch genres for artist {name}: {e}")
                
                line = f"{emoji} <b>{name}</b>"
                if genres:
                    line += f" 🏷 {', '.join(genres)}"
                lines.append(line)

                if artist_id:
                    try:
                        photo_bytes = self.navidrome.get_cover_art_bytes(artist_id)
                        if photo_bytes:
                            media_group.append(InputMediaPhoto(photo_bytes))
                    except Exception as e:
                        logger.warning(f"Failed to fetch image for artist {name}: {e}")

            full_caption = "\n".join(lines)

            if media_group:
                if len(full_caption) > 1024:
                    full_caption = full_caption[:1021] + "..."
                
                media_group[0].caption = full_caption
                media_group[0].parse_mode = "HTML"
                
                for k in range(0, len(media_group), 10):
                    self.bot.send_media_group(chat_id, media_group[k:k+10])
            else:
                self.send_message(chat_id, full_caption, parse_mode="HTML")

    def _perform_search(self, message: Message, query: str):
        """
        Execute the search logic (common for /search command and ForceReply).
        """
        logger.info(f"User {message.from_user.username} searching for: {query}")
        
        try:
            self.bot.reply_to(message, f"🔎 Searching for '{query}'...")
            results = self.navidrome.search_albums(query, limit=50)
            
            if not results:
                self.send_message(message.chat.id, f"❌ No albums found matching '{query}'.")
                return
            
            msg_lines = [f"🔎 <b>Results for '{query}':</b>\n"]
            
            # Fetch full library once for enrichment lookups
            all_albums = self.navidrome.sync_library(force=False)
            
            for album in results:
                name = album.get('name', 'Unknown')
                artist = album.get('artist', 'Unknown')
                year = album.get('year', '')
                album_id = album.get('id')
                
                # Try to get enriched metadata (releasedTypes, isCompilation) from cache
                enriched_album = album
                if album_id:
                    cached = next((a for a in all_albums if a.get('id') == album_id), None)
                    if cached:
                        enriched_album = cached
                        
                type_tag = self._get_album_type_tag(enriched_album)
                
                # Get genres (check both 'genres' list and 'genre' string)
                genre_str = ""
                if "genres" in enriched_album and enriched_album["genres"]:
                    g_list = enriched_album["genres"]
                    if isinstance(g_list, list):
                        names = [g.get("name") for g in g_list if isinstance(g, dict) and "name" in g]
                        if names:
                            genre_str = ", ".join(names)
                
                # Fallback to simple 'genre' if empty
                if not genre_str:
                    genre_str = enriched_album.get('genre', '')
                
                line = f"• {artist} - <b>{name}</b>{type_tag}"
                if year:
                    line += f" 📅 {year}"
                if genre_str:
                    line += f" 🏷 {genre_str}"
                
                msg_lines.append(line)
            
            self.send_message(message.chat.id, "\n".join(msg_lines), parse_mode="HTML")
            
        except Exception as e:
            logger.error(f"Error searching: {e}", exc_info=True)
            self.bot.reply_to(message, f"❌ Error searching: {str(e)}")

    def _process_year_request(self, chat_id: int, arg: str):
        """
        Process the logic for fetching albums by year/decade string.
        """
        import re
        import datetime
        
        # Validate argument
        # Patterns: "1994", "2023", "90s", "80s", "current"
        
        start_year = 0
        end_year = 0
        display_str = arg
        
        current_year = datetime.datetime.now().year
        
        if arg.lower() == "current":
            start_year = end_year = current_year
            display_str = str(current_year)
            
        elif re.match(r'^\d{4}$', arg):
            y = int(arg)
            if 1950 <= y <= current_year + 1:
                start_year = end_year = y
            else:
                self.send_message(chat_id, "❌ Please provide a valid year between 1950 and now.")
                return
                
        elif re.match(r'^\d0s$', arg):
            # Decade: 90s, 80s, 00s, 10s
            decade_prefix = int(arg[:2])
            
            # Handle 2-digit century mapping
            # 50s-90s -> 1950-1999
            # 00s-20s -> 2000-2029
            if 50 <= decade_prefix <= 99:
                base = 1900 + decade_prefix
            elif 0 <= decade_prefix <= 40: # ample buffer for future 30s, 40s
                base = 2000 + decade_prefix
            else:
                self.send_message(chat_id, "❌ Invalid decade.")
                return
                
            start_year = base
            end_year = base + 9
            display_str = f"the {arg}"
            
        else:
             self.send_message(chat_id, "❌ Invalid format. Use `/year 1994` or `/year 90s`.")
             return

        try:
            self.send_message(chat_id, f"📅 Finding albums from {display_str}...")
            albums = self.navidrome.get_albums_by_year(start_year, end_year, limit=40)
            
            if not albums:
                self.send_message(chat_id, f"❌ No albums found for {display_str}.")
                return

            msg = self.format_album_list(albums, f"📅 Random albums from <b>{display_str}</b>:")
            if msg:
                self.send_message(chat_id, msg)
                
        except Exception as e:
            logger.error(f"Error fetching year albums: {e}", exc_info=True)
            self.send_message(chat_id, f"❌ Error: {str(e)}")

    def start_polling(self) -> None:
        """
        Start the bot polling loop with a custom resilient mechanism.
        Uses long-polling with increased timeout and backoff on error to prevent tight loops.
        """
        logger.info("Starting resilient Telegram bot polling...")
        
        while True:
            try:
                # Use infinity_polling but with custom parameters for more control
                # non_stop=True: try to recover on any error
                # timeout: time between requests if no updates
                # long_polling_timeout: time the request waits for new updates
                self.bot.polling(non_stop=True, timeout=60, long_polling_timeout=30)
            except Exception as e:
                logger.error(f"Telegram polling crashed: {e}. Retrying in 5 seconds...", exc_info=True)
                time.sleep(5)

    def get_recent_albums(self, message: Message):
        """
        Handle /recent command to show newly added albums.
        """
        logger.info(f"User {message.from_user.username} requested recent albums")
        try:
            # get_new_albums usually defaults to 24h, allows override
            # We want the absolute latest 10, regardless of specific time window? 
            # The generic method might filter by "N hours". 
            # Let's use a large window (e.g. 30 days) ensuring we get at least some content, 
            # then slice the top 10.
            
            recent = self.navidrome.get_new_albums(hours=24 * 30, force=False)
            
            if not recent:
                self.bot.reply_to(message, "📭 No albums added in the last 30 days.")
                return
            
            # Sort by 'created' DESC is already done in get_new_albums
            top_10 = recent[:10]
            
            msg = self.format_album_list(top_10, "🆕 <b>Recently Added Albums:</b>")
            self.send_message(message.chat.id, msg)

        except Exception as e:
            logger.error(f"Error fetching recent: {e}", exc_info=True)
            self.bot.reply_to(message, f"❌ Error: {str(e)}")

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
    def _get_album_type_tag(album: Dict) -> str:
        """
        Extract and format the album release type tag.
        
        :param album: Album dictionary from Navidrome API.
        :return: Formatted tag string like " [EP]" or empty string for studio albums.
        """
        # Map release types to display labels
        type_map = {
            "ep": "EP",
            "single": "Single",
            "live": "Live",
            "compilation": "Compilation",
            "soundtrack": "Soundtrack",
            "other": "Other"
        }
        
        detected_type = None
        
        # 1. Check standard OpenSubsonic releaseTypes (list of strings)
        release_types = album.get("releaseTypes", [])
        if isinstance(release_types, list):
            for t in release_types:
                t_lower = t.lower()
                if t_lower in type_map:
                    detected_type = type_map[t_lower]
                    break
                    
        # 2. Fallback to standard Subsonic isCompilation flag
        if not detected_type and album.get("isCompilation"):
            detected_type = "Compilation"
            
        # 3. Heuristic: Check if title already contains keywords
        title = album.get("name", "")
        if not detected_type:
            title_lower = title.lower()
            
            # Sub-maps for broader detection
            compilation_keywords = ["compilation", "anthology", "collection", "complete", "hits", "best of", "essentials", "box set"]
            
            for key, label in type_map.items():
                if f" {key}" in title_lower or f"({key}" in title_lower or f"[{key}" in title_lower or title_lower.startswith(f"{key} "):
                    detected_type = label
                    break
            
            # Additional check for compilation synonyms
            if not detected_type:
                for word in compilation_keywords:
                    if f" {word}" in title_lower or f"({word}" in title_lower or f"[{word}" in title_lower or title_lower.startswith(f"{word} "):
                        detected_type = "Compilation"
                        break
        
        if detected_type:
            # Strictly ensure brackets are used
            tag = f"[{detected_type}]"
            title_stripped = title.strip()
            
            # Check if title already ends with this tag (in any bracket style)
            if title_stripped.endswith(f" {tag}") or \
               title_stripped.endswith(f" [{detected_type.lower()}]") or \
               title_stripped.endswith(f" ({detected_type})") or \
               title_stripped.endswith(f" ({detected_type.lower()})"):
                return ""
            
            return f" {tag}"
            
        return ""

    @staticmethod
    def _extract_best_date(album: Dict) -> Optional[str]:
        """
        Extract the most detailed date string available from the album metadata.
        Prioritizes fields with year+month+day over year-only fields.
        """
        possible_keys = ["originalReleaseDate", "releaseDate"]
        
        candidates = []
        for key in possible_keys:
            val = album.get(key)
            if not val:
                continue
                
            if isinstance(val, dict):
                y = val.get('year')
                m = val.get('month')
                d = val.get('day')
                
                score = 0
                if y: score += 1
                if m: score += 1
                if d: score += 1
                
                fmt = ""
                if y and m and d:
                    fmt = f"{y}-{m:02d}-{d:02d}"
                elif y and m:
                    fmt = f"{y}-{m:02d}"
                elif y:
                    fmt = str(y)
                
                if fmt:
                    candidates.append((score, fmt))
            elif isinstance(val, str) and len(val) >= 4:
                # If it's a string, we assume it's already formatted or at least has the year
                score = 1 if len(val) == 4 else (2 if len(val) <= 7 else 3)
                candidates.append((score, val))
        
        if not candidates:
            return None
            
        # Sort by score (desc) to get the most detailed date
        candidates.sort(key=lambda x: x[0], reverse=True)
        return candidates[0][1]

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
            type_tag = TelegramBot._get_album_type_tag(album)

            # Year or Date - prioritize more detailed info from originalReleaseDate or releaseDate
            best_date = TelegramBot._extract_best_date(album)
            date_display = best_date if best_date else str(album.get("year", ""))

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

            message += f"💿 <b>{title}</b>{type_tag}\n"
            message += f"👤 {artist}\n"
            message += f"📅 {date_display}\n"
            if genre_str:
                message += f"🏷 {genre_str}\n"
            message += "\n"

        return message
