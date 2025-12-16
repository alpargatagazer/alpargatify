# Music library organizer

This small, focused pipeline converts lossless music files and imports them into a **beets**-managed library using **Docker**. It is designed to:

- Reduce audio file size with minimal audible quality loss by converting `.flac` files to `.m4a` (AAC).
- Automatically organize and import the converted files into your music library to save manual tagging and moving.

**Important:** the bundled conversion script uses macOS's `afconvert` tool by default, so the conversion step is macOS-only unless you modify the converter to use a cross-platform tool such as **ffmpeg**.

## What this folder includes
- `flac-to-aac.sh`: converter script (default: `.flac` -> `.m4a` using **afconvert**).
- `wrapper.sh`: orchestrator that runs the converter into a temporary directory and then invokes a one-shot **Docker Compose** service which runs **beets** to import the converted files.
- `parallel-wrapper.sh`: script to execute `wrapper.sh` in parallel for each immediate subdirectory of a given directory, allowing batch processing of multiple albums or collections.
- `beets/`: container bits used by the importer (`beets-config.yaml`, `entrypoint.sh`, `Dockerfile`, `docker-compose.yml`).

## Technologies
**Docker**, **Docker Compose** (or `docker compose`), **beets**, **afconvert** (macOS), optional **metaflac** and **AtomicParsley** for metadata handling.

## Prerequisites
- **macOS** (required for the default `flac-to-aac.sh` which relies on `afconvert`).
- **Docker** and either `docker compose` or `docker-compose` available in PATH.
- Optional: **metaflac** and **AtomicParsley** — these improve metadata and cover art copying when available.
- Enough disk space for temporary converted files (the wrapper creates a temporary directory).

If you are not on macOS and still want to use this pipeline, inspect `flac-to-aac.sh` and replace the `afconvert` steps with **ffmpeg** or another cross-platform encoder.

## Why use this
- **Reduce size:** converting `.flac` -> `.m4a` (AAC) significantly reduces storage while retaining good quality for typical listening.
- **Automate organization:** the wrapper runs **beets** to place files into your library structure and apply metadata rules, avoiding manual file movement.

## Quick start (recommended)
Run from this `library-organizer` directory.

Usage for `wrapper.sh`:
`./wrapper.sh [--dry-run] [--beets-config /abs/path/to/beets-config.yaml] /path/to/source /absolute/path/to/music_library_root`

Examples:
- Convert and import interactively:
	`./wrapper.sh /path/to/raw_flacs /absolute/path/to/music_library_root`
- Dry-run: keep temporary converted output for inspection and skip the import cleanup:
	`./wrapper.sh --dry-run /path/to/raw_flacs /absolute/path/to/music_library_root`

Usage for `parallel-wrapper.sh`:
`./parallel-wrapper.sh [OPTIONS] /path/to/parent/directory /absolute/path/to/music_library_root`

Examples:
- Process all subdirectories in parallel with default settings:
	`./parallel-wrapper.sh /path/to/albums /absolute/path/to/music_library_root`
- Limit to 2 parallel jobs:
	`./parallel-wrapper.sh --max-jobs 2 /path/to/albums /absolute/path/to/music_library_root`
- Dry run with verbose output:
	`./parallel-wrapper.sh --dry-run --verbose /path/to/albums /absolute/path/to/music_library_root`

## Detailed explanation: `wrapper.sh` (what it does and why it matters)
- **Orchestration:** `wrapper.sh` runs `flac-to-aac.sh` to convert your source collection into a temporary directory, then runs a one-shot **Docker Compose** service that launches a **beets** container to import files from that temporary directory into the destination library.
- **Atomic workflow:** conversion and import steps are separated to allow inspection (`--dry-run`) and to avoid touching your live library until import.
- **Config override:** pass `--beets-config /abs/path/to/beets-config.yaml` to mount a custom **beets** configuration into the importer container.

## `parallel-wrapper.sh` (parallel execution)
- **Purpose:** This script automates the processing of multiple music collections by running `wrapper.sh` in parallel for each immediate subdirectory within a specified parent directory. It's ideal for batch importing large numbers of albums or collections without manual intervention.
- **Parallelism:** By default, it uses the number of CPU cores for maximum parallel jobs, but this can be customized with `--max-jobs N`.
- **Options:** Supports all `wrapper.sh` options (e.g., `--dry-run`, `--beets-config PATH`, `--convert-only`, etc.) and passes them through. Additional options include `--max-jobs N` for limiting parallelism and `--verbose` for detailed logging.
- **Logging:** Each job's output is logged to individual files in a temporary log directory for easy troubleshooting.
- **Cleanup:** Automatically cleans up Docker resources after completion and provides a summary of completed and failed jobs.

## `flac-to-aac.sh` (converter) behavior
- Source -> destination: preserves the source directory tree under the destination root and converts each `.flac` to a same-relative-location `.m4a` file.
- Default encoder: **afconvert** with reasonable defaults (e.g. 192 kbps AAC). Override options with the `AF_OPTS` environment variable.
- Metadata: if **metaflac** and **AtomicParsley** are present, the script attempts to copy tags and cover art into the `.m4a` files. If not present, conversion still proceeds but metadata copying is limited. You can install those tools with `brew install flac atomicparsley`.
- If the source files are saved as image instead of tracks, the program will try to split it. You need **xld** (`brew install xld`).
- Flags supported:
	- `--dry-run`: show the `afconvert` commands without executing them (keeps the temporary output for inspection and avoids cleanup)
	- `--force`: overwrite existing destination files (equivalent to `SKIP_EXISTING=no`)
	- `-h` / `--help`: show usage

Environment variables used by the converter and wrapper (common ones):
- `AF_OPTS`: extra arguments to pass to `afconvert` (tokenized by the script). Example: `AF_OPTS='-f mp4f -d "aac" -b 256000'`.
- `SKIP_EXISTING`: `yes` (default) to skip existing converted files, `no` to overwrite.
- `DRY_RUN`: `yes` to enable dry-run behavior.
- `VERBOSE`: `yes` for more logging.

## Beets import step
- The wrapper mounts the temporary conversion directory into the beets container and runs the container entrypoint which calls **beets** to import the files into your library at the provided destination path.
- The beets container uses the bundled `beets/beets-config.yaml` by default. Pass `--beets-config /abs/path/to/beets-config.yaml` to `wrapper.sh` to use a custom config file (the wrapper mounts it into the container).

## Where to look inside this folder
- `wrapper.sh` — the main orchestrator. Read this first to understand the pipeline and to adapt compose detection or mount points.
- `parallel-wrapper.sh` — the parallel execution script. Use this for batch processing multiple directories.
- `flac-to-aac.sh` — the conversion worker (edit `AF_OPTS` or replace `afconvert` if you need cross-platform support).
- `beets/` — container config: `beets/beets-config.yaml`, `beets/entrypoint.sh`, `beets/Dockerfile`, `beets/docker-compose.yml` (used by the wrapper).

## License
See `LICENSE` at the repository root.
