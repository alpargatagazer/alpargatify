# docker/beets/Dockerfile
FROM python:3.14-slim AS builder

ARG BEETS_VERSION=2.5
ENV DEBIAN_FRONTEND=noninteractive

# Install system deps needed for beets plugins (file, ffmpeg if needed, libmagic, buildessentials, etc.)
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     build-essential \
  && rm -rf /var/lib/apt/lists/*

# Create a venv and install pinned beets into it
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy pinned requirements (you should generate this with pip-compile or hand-pin)
# For simplicity we install beets with extras: fetchart,embedart
RUN pip install --upgrade pip setuptools wheel \
  && pip install "beets[lastgenre,fetchart,embedart,lyrics]==${BEETS_VERSION}"

# ---- final (runtime) image ----
FROM python:3.14-slim AS runtime

ENV PATH="/opt/venv/bin:$PATH"
COPY --from=builder /opt/venv /opt/venv

# non-root user
RUN useradd -m beets
WORKDIR /home/beets

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run as non-root user
USER beets
ENTRYPOINT ["/entrypoint.sh"]
