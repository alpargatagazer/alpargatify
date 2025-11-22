# Music library processor

A small, personal music import pipeline: convert lossless files to a target format and import them into a beets-managed music library using **Docker**.

## Overview

This repository provides:

- A converter script that (by default) converts FLAC -> AAC: [`converter/flac-to-aac.sh`](converter/flac-to-aac.sh)
- A wrapper that runs the converter into a temporary directory and then invokes a one-shot beets import service via Docker Compose: [`converter/wrapper.sh`](converter/wrapper.sh)
- Docker Compose configuration and a beets image that imports the converted files: [`converter/docker/docker-compose.yml`](converter/docker/docker-compose.yml) and [`converter/docker/beets/Dockerfile`](converter/docker/beets/Dockerfile)
- Beets entrypoint and config used inside the container: [`converter/docker/beets/entrypoint.sh`](converter/docker/beets/entrypoint.sh) and [`converter/docker/beets/beets_config.yaml`](converter/docker/beets/beets_config.yaml)

## Prerequisites

- MacOS, since the converter script uses a tool only available in that OS. **metaflag** and **AtomicParsley** are also need for the tool.
- **Docker** (and either `docker compose` or `docker-compose`)
- A Unix-like shell (the scripts use bash)
- Optional: edit the beets config at [`converter/docker/beets/beets_config.yaml`](converter/docker/beets/beets_config.yaml)

## Quick start

Run the wrapper which performs conversion then imports via beets:

```sh
./converter/wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] /path/to/source /absolute/path/to/music_library_root
```

Notes about important variables and behavior (see [`converter/wrapper.sh`](converter/wrapper.sh)):

- [`BEETS_CONFIG`](converter/wrapper.sh) — path to the beets YAML config file passed into the container.
- [`DRY_RUN`](converter/wrapper.sh) — when `yes`, converter is invoked in dry-run and temporary output is preserved.
- [`DEST_PATH`](converter/wrapper.sh) / [`DEST`](converter/wrapper.sh) — the absolute destination library root that beets will place files into.
- [`IMPORT_SRC`](converter/wrapper.sh) / [`TMP_DEST`](converter/wrapper.sh) — temporary directory where the converter writes output before beets imports it.
- [`COMPOSE_CMD`](converter/wrapper.sh) — wrapper auto-detects `docker compose` vs `docker-compose`.

The wrapper does two steps:

1. Run the converter: [`converter/flac-to-aac.sh`](converter/flac-to-aac.sh) (writes into a temp dir).
2. Run Docker Compose one-shot service which runs beets to import from that temp dir: [`converter/docker/docker-compose.yml`](converter/docker/docker-compose.yml). The beets container uses [`converter/docker/beets/entrypoint.sh`](converter/docker/beets/entrypoint.sh) which reads `BEETS_CONFIG_PATH`, `IMPORT_SRC_PATH`, and `DRY_RUN` inside the container.

Example:

```sh
# convert and import (interactive)
./converter/wrapper.sh /path/to/raw_flacs /absolute/path/to/music_library_root

# dry-run: keep temp output for inspection
./converter/wrapper.sh --dry-run /path/to/raw_flacs /absolute/path/to/music_library_root
```

## Files of interest

- [`converter/wrapper.sh`](converter/wrapper.sh) — orchestrates conversion + beets import; exports env vars used by compose.
- [`converter/flac-to-aac.sh`](converter/flac-to-aac.sh) — conversion script invoked by the wrapper.
- [`converter/docker/docker-compose.yml`](converter/docker/docker-compose.yml) — compose file for the beets importer service.
- [`converter/docker/beets/Dockerfile`](converter/docker/beets/Dockerfile) — image used for the beets importer.
- [`converter/docker/beets/entrypoint.sh`](converter/docker/beets/entrypoint.sh) — container entrypoint that runs beets import.
- [`converter/docker/beets/beets_config.yaml`](converter/docker/beets/beets_config.yaml) — default beets configuration bundled in the image; you can override by passing `--beets-config` to the wrapper.

## Troubleshooting

- If the wrapper prints "docker not found" or "neither 'docker compose' nor 'docker-compose' found", ensure Docker is installed and the CLI is available.
- If the wrapper exits with a non-zero code, inspect the printed output — the wrapper sets `set -euo pipefail` and reports exit codes from both conversion and the beets container run.
- Temporary converter output is created under a temp dir (`mktemp -d`) and removed on exit unless `--dry-run` is used; see [`TMP_DEST`](converter/wrapper.sh).

## License

See [LICENSE](LICENSE).
