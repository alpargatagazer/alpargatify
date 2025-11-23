# Music library processor

Small, focused pipeline to convert lossless music files and import them into a beets-managed library using Docker.

This folder contains a lightweight converter + wrapper that:
- converts a local source collection (default: FLAC) to a target format
- places converted files into a temporary directory
- runs a one-shot beets Docker service to import the converted files into your music library

## Overview

What this package provides:
- A converter script that (by default) converts FLAC -> AAC: `flac-to-aac.sh`
- A wrapper that runs the converter into a temporary directory and then invokes a one-shot beets import service via Docker Compose: `wrapper.sh`
- Docker Compose configuration and a beets image used for importing: `docker/docker-compose.yml` and `docker/beets/Dockerfile`
- Beets entrypoint and default config used inside the container: `docker/beets/entrypoint.sh` and `docker/beets/beets_config.yaml`

## Prerequisites

- macOS (the converter script uses macOS audio tooling by default). The scripts assume a POSIX shell (bash/zsh).
- Docker (either `docker compose` or `docker-compose` must be available)
- Optional utilities commonly used by the converter: `metaflac` and `AtomicParsley` (install only if your chosen converter tool requires them)
- Sufficient disk space for temporary converted files (wrapper creates a temp dir)

If you are not on macOS or want to use `ffmpeg` exclusively, inspect and adapt `flac-to-aac.sh` before running.

## Quick start

Usage (run from this directory):

```sh
./wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] /path/to/source /absolute/path/to/music_library_root
```

Examples:

```sh
# convert and import (interactive)
./wrapper.sh /path/to/raw_flacs /absolute/path/to/music_library_root

# dry-run: keep temp output for inspection
./wrapper.sh --dry-run /path/to/raw_flacs /absolute/path/to/music_library_root
```

Notes:
- `--dry-run` preserves the temporary converted output for inspection and does not remove it on exit.
- `--force` (if implemented) can be used to overwrite or skip confirmation steps during import.
- `--beets-config /abs/path/to/beets_config.yaml` lets you supply a custom beets configuration YAML (absolute path) — this file is mounted into the container.

## Environment variables and behavior

The wrapper exports and/or passes a few environment variables into the Docker compose run. Common ones you may see in the wrapper or container:
- `BEETS_CONFIG` — path to the beets YAML config file that will be mounted into the beets container
- `DRY_RUN` — when `yes`, converter runs in dry-run mode and temporary output is preserved
- `DEST` / `DEST_PATH` — absolute path to the destination music library root where beets will place files
- `IMPORT_SRC` / `TMP_DEST` — temporary directory containing converted files to be imported by beets
- `COMPOSE_CMD` — the wrapper auto-detects `docker compose` vs `docker-compose` and sets this accordingly

The wrapper performs two main steps:
1. Run the converter: `flac-to-aac.sh` (writes into a temp dir).
2. Run the Docker Compose one-shot service which runs beets to import from that temp dir using `docker/docker-compose.yml`.

Inside the container, the beets entrypoint (`docker/beets/entrypoint.sh`) reads the mounted `BEETS_CONFIG_PATH`, `IMPORT_SRC_PATH`, and `DRY_RUN` variables to control the import.

## Files of interest

- `wrapper.sh` — orchestrates conversion + beets import; exports env vars used by compose.
- `flac-to-aac.sh` — conversion script invoked by the wrapper (adjust if you need a different encoder).
- `docker/docker-compose.yml` — compose file for the beets importer service.
- `docker/beets/Dockerfile` — Docker image used for the beets importer.
- `docker/beets/entrypoint.sh` — container entrypoint that runs the beets import command.
- `docker/beets/beets_config.yaml` — default beets configuration bundled in the image; you can override it by passing `--beets-config` to the wrapper.

## Troubleshooting

- "docker not found" / compose missing: ensure Docker Desktop is installed and the `docker` CLI is in your PATH. Confirm either `docker compose version` or `docker-compose --version` works.
- Non-zero exit codes: the wrapper sets `set -euo pipefail` and will stop on errors — read the printed output from the converter step and the beets container run for details.
- Temporary output: the wrapper creates a temporary directory with `mktemp -d`. This directory is removed on successful exit unless `--dry-run` is used.
- macOS tools: if audio conversion fails, confirm the tools referenced by `flac-to-aac.sh` are installed.

## License

See `LICENSE` at the repository root.
