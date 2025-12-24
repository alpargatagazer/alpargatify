# Navidrome Telegram Bot

A lightweight, feature-rich Telegram bot that integrates with your Navidrome (Subsonic) music server to deliver both **scheduled notifications** and **interactive commands**.

## 🎵 Features

### Scheduled Notifications
Automatic daily updates about your music library:
- **🆕 New Albums**: Albums added to your library in the last 24 hours
- **🎂 Anniversaries**: Albums released on this day in music history

### Interactive Commands
Chat with your bot to explore your library:
- `/search <query>` - Search for albums by artist or title (up to 50 results)
- `/random` - Get a random album suggestion with cover art
- `/stats` - View library statistics (albums, artists, songs)
- `/help` - Display available commands

### Key Technical Features
- **Group Authorization**: Bot only responds to commands from the authorized group chat - no individual user management needed
- **Incremental Sync**: Efficiently caches your library and only fetches new metadata, reducing API load
- **Rich Formatting**: Beautiful messages with emojis, years, and multiple genres
- **Cover Art**: Album covers sent with random suggestions
- **Alpine-Based**: Optimized Docker image (~105MB) using multi-stage builds
- **Concurrent Architecture**: Runs scheduled jobs and interactive polling simultaneously using a unified bot instance

## 📋 Setup & Deployment

### 1. Secrets Configuration
Create a `secrets/` directory in the project root with these files (plain text, no file extensions):

| File | Content | Example |
|------|---------|---------|
| `navidrome_url.txt` | Your Navidrome server URL | `https://music.example.com` |
| `navidrome_user.txt` | Your Navidrome username | `admin` |
| `navidrome_password.txt` | Your Navidrome password | `mypassword` |
| `telegram_bot_token.txt` | Token from [@BotFather](https://t.me/botfather) | `123456789:ABCdef...` |
| `telegram_chat_id.txt` | **Group chat ID(s)** for notifications and authorization | `-1001234567890` or `-1001111111,-1002222222` |

**How to get your Group Chat ID:**
1. Add your bot to your Telegram group
2. Send any message in the group
3. Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
4. Look for `"chat":{"id":-1001234567890` in the response
5. Copy the negative number (including the minus sign) to `telegram_chat_id.txt`

**Multiple Groups (for testing):** You can authorize multiple groups by separating chat IDs with commas. Scheduled notifications will be sent to **all** authorized groups.

**Security Note**: The bot will **only respond to commands from authorized groups**. Anyone outside these groups cannot interact with the bot.

### 2. Environment Variables
Configure in `docker-compose.yml`:

- `LOGGING`: Log level (`INFO`, `DEBUG`). Default: `INFO`
- `SCHEDULE_TIME`: Daily notification time (24h HH:MM). Default: `08:00`
- `RUN_ON_STARTUP`: Run checks on startup (`true`/`false`). Default: `false`
- `TZ`: Timezone for scheduling. Default: `Europe/Madrid`

### 3. Deploy with Docker Compose
```bash
docker-compose up -d
```

The bot will:
1. Start both the scheduler thread (for daily notifications) and polling thread (for interactive commands)
2. Cache your library in `data/albums_cache.json` for fast subsequent runs
3. Listen for commands from authorized users only

### 4. Verify It's Running
```bash
# Check logs
docker logs -f navidrome_telegram_bot

# You should see:
# Bot authorized for chat ID: -1001234567890
# Scheduler thread started
# Bot polling thread started
```

### 5. Test Interactive Commands
Send a message to your bot on Telegram:
- `/help` - See all available commands
- `/stats` - View your library stats
- `/random` - Get a random album

## 🏗️ Architecture

### Unified Bot Design
The application uses a **single `TelegramBot` class** that handles:
- **Scheduled Notifications**: Sends daily updates about new albums and anniversaries
- **Interactive Commands**: Responds to user queries in real-time
- Uses `pyTelegramBotAPI` for all Telegram communication

### Concurrent Threading
Two daemon threads run simultaneously:
1. **Scheduler Thread**: Runs daily checks at `SCHEDULE_TIME`
2. **Bot Polling Thread**: Listens for user commands via long-polling

Both share the same bot instance for efficiency.

### Docker Optimization
- **Multi-stage Alpine build** reduces image size from 235MB → 105MB (~55% reduction)
- Separates build dependencies (gcc, musl-dev) from runtime
- Only includes essential packages in final image

## 🛠️ Development

### Project Structure
```
telegram-bot/
├── src/
│   ├── main.py              # Entry point, threading orchestration
│   ├── telegram_bot.py      # Unified bot (commands + notifications)
│   ├── navidrome_client.py  # Subsonic API client
│   └── secrets_loader.py    # Docker secrets helper
├── tests/
│   └── test_navidrome.py    # Integration tests
├── secrets/                 # Sensitive configuration
└── data/                    # Persistent cache (volume)
```

### Running Tests
```bash
docker-compose run --rm telegram-bot python tests/test_navidrome.py
```

### Updating the Bot
```bash
# Pull latest changes
git pull

# Rebuild and restart
docker-compose down
docker-compose build
docker-compose up -d
```

## 🔒 Security

- **Group Authorization**: Bot only responds to commands sent in the authorized group chat
- **Docker Secrets**: Credentials never hardcoded, mounted securely at runtime
- **No Public Access**: Anyone outside the group cannot use the bot
- **Logging**: Unauthorized access attempts are logged with chat ID

## 📊 Rich Message Formatting

**Search Results:**
```
🔎 Results for 'pink floyd':

• Pink Floyd - The Dark Side of the Moon 📅 1973 🏷 Progressive Rock
• Pink Floyd - Wish You Were Here 📅 1975 🏷 Progressive Rock
• Pink Floyd - The Wall 📅 1979 🏷 Rock, Progressive Rock
```

**Random Album:**
```
🎲 Why not listen to this?

💿 Kind of Blue
👤 Miles Davis
📅 1959
🏷 Jazz, Cool Jazz

[Album cover image]
```

## 🐛 Troubleshooting

**Bot doesn't respond to commands:**
- Ensure the bot is added to your authorized group
- Verify `telegram_chat_id.txt` has the correct group chat ID (should be negative number)
- Restart container: `docker-compose restart`
- Check logs: `docker logs navidrome_telegram_bot`

**No scheduled notifications:**
- Verify `telegram_chat_id.txt` has correct group chat ID
- Check `SCHEDULE_TIME` is in future (24h format)
- View logs for "Daily check completed" messages

**Cover art not loading:**
- Verify Navidrome is accessible from the bot container
- Check credentials in secrets files
- Try `/random` command and check logs for errors
