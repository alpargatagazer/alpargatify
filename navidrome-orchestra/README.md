# Navidrome Orchestra

A lightweight orchestration and observability setup for Navidrome and related services.

This folder contains Docker Compose files, configuration templates and persistent volume layouts used to run Navidrome together with a small observability stack (Caddy, Prometheus, Grafana) and supporting assets (backgrounds, dashboard JSON, etc.). The intent is to provide a reproducible, production-ready local/small-host deployment that keeps music data persistent across container upgrades.

**Quick overview**
- **Core compose**: `docker-compose-core.yml` — Navidrome.
- **Monitor compose**: `docker-compose-monitor.yml` — Prometheus + Grafana + exporters.
- **Network compose**: `docker-compose-network.yml` — Caddy and some other network resources.
- **Bootstrap script**: `bootstrap.sh` — initial setup helper to create directories and set permissions.
- **Configs**: `configs/` — contains `Caddyfile`, `navidrome.toml`, `prometheus.yml`, Grafana datasources and other templates.

**Repository purpose**

This subproject orchestrates Navidrome (the lightweight music server) and an observability stack so you can run a single host that serves music and provides metrics, dashboards and TLS/HTTP routing via Caddy. It's opinionated about paths and volumes to make upgrades safe and reproducible.

**Prerequisites**
- Docker (engine) and Docker Compose.
- Sane disk space for music library, cache and time-series data.
- macOS / Linux host knowledge .

Usage
-----

1. Copy or create an environment file

	- The repo contains an example `.env` at `navidrome-orchestra/.env` (this file may be gitignored in your environment). Ensure it contains the values you want (ports, paths, credentials).

2. Bootstrap script deploy all things

	```zsh
	cd navidrome-orchestra
	chmod +x ./bootstrap.sh && ./bootstrap.sh
	```

	`bootstrap.sh` will create the persistent directories under `volumes/` and set permissions. Inspect the script before running.


Configuration and files
-----------------------

- `configs/Caddyfile`, `configs/Caddyfile.custom` — Caddy configuration files; update these to point to your domain, TLS settings, and upstreams.
- `configs/navidrome.toml` — Navidrome server settings: database locations, metadata, transcoding, and other service-specific options.
- `configs/prometheus.yml` and `configs/prometheus.yml.custom` — Prometheus scrape configs; edit to expose/collect metrics from any additional exporters.
- `configs/grafana-datasources.yml` and `grafana-dashboards/` — Grafana datasources and a set of dashboards included for node exporter and Navidrome metrics (if provided).

Persistent data layout
----------------------

Under `volumes/` the compose setup expects persistent directories. Important ones include:

- `volumes/navidrome/` — Navidrome configuration and cache: `navidrome.toml`, `backgrounds/`, `backup/`, `cache/` (images, transcoding cache).
- `volumes/caddy/` — Caddy config and data (ACME certificates, locks, instance id).
- `volumes/grafana/` — Grafana dashboards, plugins, and exported data.
- `volumes/prometheus/` — Prometheus TSDB WAL and chunks.

When you run `bootstrap.sh` it will ensure these folders exist and set the owner where necessary. If you recreate volumes manually, ensure the UID/GID match what the containers expect, or adjust container user mappings.

Monitoring & dashboards
-----------------------

The monitor compose brings up Prometheus and Grafana, and ships some dashboards in `grafana-dashboards/`. The Grafana instance is configured via `configs/grafana-datasources.yml` to use the local Prometheus. Add or edit dashboards in `volumes/grafana/dashboards/` to persist custom dashboards.

Custom assets
-------------

- `backgrounds/` contains images that Navidrome may expose as backgrounds. Copy your album art or backgrounds into the provided `backgrounds/` folder, depending on how your `navidrome.toml` points to them.

Security and TLS
----------------

This setup uses Caddy to provide TLS termination by default (see `configs/Caddyfile`). Caddy will obtain/renew certificates automatically when reachable on the appropriate ports (80/443). If you run this behind another proxy or in an environment without public DNS, switch to a custom `Caddyfile` or provide certificates via the `volumes/caddy` data directory.

Extending the setup
--------------------

- Add exporters to Prometheus scrape by editing `configs/prometheus.yml` and restarting the monitor compose.
- Add Grafana dashboards by placing JSON into `grafama-dashboards/` and restarting Grafana (or import via UI).

Contributing
------------

If you want to improve or extend this setup:

- Send a PR that updates `configs/` or `docker-compose-*.yml` with clear justification.
- Keep backward compatibility for volume paths and public-facing ports when possible.

License
-------
This subproject follows the repository-level license. See the top-level `LICENSE` file for details.

Contact / Questions
-------------------
If you need help customizing the setup for a specific host or provider, open an issue in the main repository or reach out to the maintainer.

---

Generated by repository analysis on the local workspace. Review the files in `configs/` before running containers — they contain the source of truth for runtime behavior.
