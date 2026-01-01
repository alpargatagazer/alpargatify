# Navidrome Orchestra

A lightweight orchestration and observability stack to run a single-host music server (**Navidrome**) together with small, optional microservices for management and monitoring.

This folder contains the Docker Compose files, configuration templates and helper scripts used to deploy a production-friendly Navidrome instance with additional utilities (reverse proxy, metrics, dashboards, file services, and an optional web UI for container triggers).

## Summary
- **Core**: `docker-compose-core.yml` — runs **Navidrome** and an init helper to set ownership.
- **Monitor**: `docker-compose-monitor.yml` — runs **Prometheus**, **Grafana** and **node-exporter** for observability.
- **Network**: `docker-compose-network.yml` — runs **Caddy** (TLS/HTTP reverse proxy).
- **Storage / Extras**: `docker-compose-storage.yml` & `docker-compose-extratools.yml` — run **SFTP**, **Syncthing**, **FileBrowser**, **WUD** and **MusicBrainz Picard**.
- **Bootstrap helper**: `bootstrap.sh` — prepares directories, renders config templates, validates environment and launches the composed services.
- **Library creation helper**: `new-library.sh` — creates a new Navidrome library and FileBrowser user for isolated user access.

## Primary Technologies
- **Docker**: container runtime for all services.
- **Docker Compose**: orchestrates multi-container services.
- **Caddy**: TLS termination and reverse proxy.
- **Prometheus** and **Grafana**: monitoring + dashboards.
- **Navidrome**: the music streaming server.
- **Syncthing**, **FileBrowser**, **SFTP**: optional storage and access helpers.
- **WUD**: web UI that can trigger compose actions (optional, profile-enabled).
- **MusicBrainz Picard**: music tagger and organizer (optional, profile-enabled).

## What this is for
This setup is intended to run on a remote server (VPS or VM). It brings up a robust music server (**Navidrome**) and a small set of microservices that help operate and observe that server: TLS routing and certificates (**Caddy**), metrics collection and dashboards (**Prometheus** + **Grafana**), container-level exporters (**node-exporter**), storage/exchange helpers (**Syncthing**, **FileBrowser**, **SFTP**), and a management UI to make sure your containers are updated (**WUD**).

## Before you begin
- Fill in the `./.env` file located next to `bootstrap.sh`. The script requires several variables to be present (see list below).
- Install **Docker** and **Docker Compose** on the host.
- Inspect `configs/` (particularly `Caddyfile` and `prometheus.yml`) in case you have any special needs.

## Required .env values (high level)
- `DOMAIN`: your domain (used by Caddy and templates).
- `NAVIDROME_MUSIC_PATH`: path to your music library on the host (absolute).
- `SFTP_USER`, `SFTP_PASSWORD`: credentials for the `sftp` service.

Optional but commonly required depending on enabled profiles:
- `WUD_ADMIN_USER`, `WUD_ADMIN_PASSWORD` — required if WUD is enabled (default yes).
- `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` — required if monitoring is enabled.
- `SYNCTHING_GUI_USER`, `SYNCTHING_GUI_PASSWORD` — required if extra-storage profile is enabled.
- `FILEBROWSER_ADMIN_USER`, `FILEBROWSER_ADMIN_PASSWORD` — required for filebrowser.
- `PICARD_ADMIN_USER`, `PICARD_ADMIN_PASSWORD` — required for MusicBrainz Picard.

See the comments in `bootstrap.sh` for additional variable expectations and port names (any env variable that ends with `_PORT` will be validated).

## What `bootstrap.sh` does
- Creates missing directories such as `volumes/` and your configured `NAVIDROME_MUSIC_PATH`.
- Validates key `.env` variables and checks presence of required credentials for enabled profiles.
- Computes numeric `PUID` and `PGID` from the owner of `NAVIDROME_MUSIC_PATH` and exports them for use by containers.
- Generates a random `CUSTOM_METRICS_PATH` (e.g. `/metrics-abcdef12`) and a random `NAVIDROME_METRICS_PASSWORD` for Prometheus scraping.
- Creates an htpasswd-style hash (`WUD_ADMIN_PASSWORD_HASH`) from `WUD_ADMIN_PASSWORD` (using `openssl` or `htpasswd`) and exports it.
- Renders templates into `configs/*.custom` (currently `prometheus.yml` -> `prometheus.yml.custom` and `Caddyfile` -> `Caddyfile.custom`) by substituting placeholders with environment values.
- Detects the available `docker compose` or `docker-compose` binary and runs compose with all `docker-compose*.yml` files in the folder.

## What `new-library.sh` does
- Creates a new isolated library directory in `/extra-libraries/<username>` on the host (mapped from `NAVIDROME_EXTRA_LIBRARIES_PATH`).
- Links the new library to an existing Navidrome user specified by username.
- Creates or updates a FileBrowser user with the same username, granting access only to the new library directory.
- Requires the Navidrome and FileBrowser containers to be running.
- Temporarily stops FileBrowser during user creation to avoid database locks.
- Validates inputs, checks for existing users/libraries, and provides a summary upon completion.

Usage: `./new-library.sh <username> <password>`

Requirements:
- `.env` file with `NAVIDROME_EXTRA_LIBRARIES_PATH` set.
- Navidrome user with the specified username must already exist.
- FileBrowser admin credentials in `.env` if needed for initial setup.

## Flags and usage of `bootstrap.sh`
Run the script from the `navidrome-orchestra` directory. Examples:
```zsh
cd navidrome-orchestra
chmod +x ./bootstrap.sh
./bootstrap.sh            			# default: create resources and bring services up (compose up -d)
./bootstrap.sh --down     			# stop services (compose down)
./bootstrap.sh --no-wud   			# bring services up but disable the 'wud' profile
./bootstrap.sh --no-monitoring  	# disable the monitoring profile (Prometheus/Grafana/exports)
./bootstrap.sh --no-extra-storage	# disable extra storage services (Syncthing/FileBrowser)
./bootstrap.sh --no-picard      	# disable MusicBrainz Picard
./bootstrap.sh --prod     			# run in production mode (Caddy uses https in templates)
```

Flags explained:
- `--down`: stop all services and remove orphans (`compose down`).
- `--no-wud`: disable the `wud` profile so the `WUD` service and any profile-tagged services are not started.
- `--no-extra-storage`: disable the `extra-storage` profile (disables `syncthing` and `filebrowser`).
- `--no-monitoring`: disable the `monitoring` profile (disables Prometheus, Grafana, exporters).
- `--no-picard`: disable the `picard` profile (disables MusicBrainz Picard).
- `--prod`: tells template rendering to use production behavior (sets `PROTOCOL=https` for templates/Caddy).
- `-h|--help`: prints usage and exits.

Implementation notes about profiles:
- The script will pass `--profile NAME` to the `compose up` command for each enabled profile when the `docker compose` implementation supports profiles. If the `compose` used does not support profiles, the script warns and proceeds (profile filtering is ignored in that case).

## How each microservice fits in the stack
- **Navidrome** (`navidrome` in `docker-compose-core.yml`): the core music server that serves your library.
- **Init helper** (`init-chown`): one-shot container that ensures ownership of `volumes/` and `music/` matches `PUID:PGID` before other containers run.
- **Caddy** (`docker-compose-network.yml`): TLS termination and routing to internal services (exposes ports 80 and 443). Uses `configs/Caddyfile.custom` after rendering.
- **Prometheus** (`docker-compose-monitor.yml`): scrapes metrics from services (including Navidrome at the generated `CUSTOM_METRICS_PATH`). Rendered config is `configs/prometheus.yml.custom`.
- **Grafana** (`docker-compose-monitor.yml`): dashboard for Prometheus data and pre-provisioned dashboards in `grafana-dashboards/`. Accessible via web UI at `grafana.<domain>`.
- **node-exporter** (`docker-compose-monitor.yml`): provide container and host metrics for Prometheus.
- **SFTP** (`docker-compose-storage.yml`): exposes SFTP access to the `NAVIDROME_MUSIC_PATH` for uploads or remote sync.
- **Syncthing** (`docker-compose-storage.yml`, profile `extra-storage`): optional synchronisation service that can mirror music folders between hosts. Two folders are created at its init: one for syncing your music with a remote server and the other to sync the **Navidrome** backups. Accessible via web UI at `syncthing.<domain>`.
- **FileBrowser** (`docker-compose-storage.yml`, profile `extra-storage`): web UI for browsing and managing files inside the music folder. Accessible via web UI at `filebrowser.<domain>`.
- **WUD** (`docker-compose-extratools.yml`, profile `wud`): optional management web UI that can trigger docker-compose actions based on the bundled compose files. Useful for remote triggers and scheduled actions — keep it disabled if you do not want remote-trigger abilities. Accessible via web UI at `wud.<domain>`.
- **MusicBrainz Picard** (`docker-compose-extratools.yml`, profile `picard`): optional music tagger and organizer. Accessible via web UI at `picard.<domain>`.

## Safety and secrets
- `bootstrap.sh` validates presence of required secrets in `.env` and will refuse to run or warn when critical secrets are missing for enabled profiles.
- The script does not print secret values to logs; it only reports presence/absence.

## Troubleshooting
- If you see errors about missing `docker compose` or `docker-compose`, install a Compose implementation and retry.
- If htpasswd generation fails, ensure `openssl` or `htpasswd` is available on the host.
- If services do not start as expected, check the rendered files `configs/Caddyfile.custom` and `configs/prometheus.yml.custom` for substitution issues.

## Examples
- Quick local test (no monitoring):
```zsh
./bootstrap.sh --no-monitoring
```
- Production with HTTPS
```zsh
./bootstrap.sh --prod
```

## Contributing & Issues
- If you have suggestions, feature requests or bugs, please open an issue on the project GitHub repository.

## License
See `LICENSE` at the repository root.