# Navidrome Telegram Bot

A Python microservice that connects to your Navidrome server (via Subsonic API) and posts daily updates to a Telegram group.

## Features

- **Daily New Albums**: Checks for albums added in the last 24 hours.
- **On This Day**: Checks for albums released on the current day (matching Day/Month).
- **Dockerized**: Fully containerized with Docker and Docker Compose.
- **Secure**: Uses Docker Secrets for sensitive information.

## Technology

- **Language**: Python 3.12
- **Libraries**: `requests` (API), `schedule` (Job timing)
- **Container**: Docker (Alpine/Slim based)

## Setup

### 1. Secrets
Create a `secrets` folder in this directory and add the following files with your configuration:

- `secrets/navidrome_url.txt`: Full URL to your Navidrome instance (e.g., `https://music.example.com`)
- `secrets/navidrome_user.txt`: Your Username
- `secrets/navidrome_password.txt`: Your Password (or Token)
- `secrets/telegram_bot_token.txt`: Your Telegram Bot API Token
- `secrets/telegram_chat_id.txt`: The Chat ID (Group or User) to send messages to

### 2. Configuration
Edit `docker-compose.yml` environment variables if needed:
- `TZ`: Your Timezone (default: `Europe/Madrid`)
- `SCHEDULE_TIME`: Time to run the check (default: `08:00`)
- `LOGGING`: Log level (default: `INFO`). Set to `DEBUG` for verbose output.
- `RUN_ON_STARTUP`: Set to `true` to run a check immediately when the container starts (good for testing).

### 3. Run
```bash
docker-compose up -d --build
```

### Caching
The bot maintains a local cache of your album library using a JSON file in the `data/` directory. This is mapped to the container volume to persist across restarts.
- **Optimization**: The first run will fetch all albums (which may take time). Subsequent runs (within 24h) use the cache.
- The `get_new_albums` check always queries the API directly (with optimized pagination) to ensure accuracy.

### Verification (Dry Run)
You can test the connection to Navidrome without sending Telegram messages by running the test script inside the container:
```bash
docker-compose run --rm telegram-bot python tests/test_navidrome.py
```
This will run a diagnostic check and print the results to the console.

## How it works

The bot runs a continuous loop using the python `schedule` library.
1. At 8:00 AM (or configured time), it authenticates with Navidrome using the Subsonic API protocol (establishing a salt and token).
2. It fetches the list of "newest" albums.
3. It iterates through your library (paging through albums) to find matches for "Date Released" = Today.
    - *Note*: This depends on your music files having accurate `releaseDate` or `date` tags that Navidrome has indexed.
4. If matches are found, it formats an HTML message and sends it to Telegram.
