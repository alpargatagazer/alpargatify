# docker/beets/Dockerfile
FROM python:3.14

# Install minimal deps (file for mime detection)
RUN apt-get update && apt-get install -y --no-install-recommends \
    file \
    && rm -rf /var/lib/apt/lists/*

# create non-root user
RUN useradd -m beets
WORKDIR /home/beets

# Install beets and select plugins
RUN pip install --no-cache-dir "beets[fetchart,embedart]"

# Copy entrypoint
COPY beets_config.yaml /app/beets_config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER beets

ENTRYPOINT ["/entrypoint.sh"]
