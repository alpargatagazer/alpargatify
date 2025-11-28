# alpargatify

This is a small collection of tools and orchestrations to run a personal music streaming service and helper utilities. I created this because commercial music streaming platforms have shortcomings and I wanted a self-hosted solution I control — and to make it easier for others who want to run their own.

**Primary idea**: provide a production-friendly Navidrome stack (reverse proxy, observability and optional storage helpers) and a small library organizer toolset — ready to deploy on a typical Ubuntu server.

## Technologies used

- **Docker** — container runtime used across the project.
- **Docker Compose** — orchestrates the multi-container setups.
- **Caddy** — TLS termination and reverse proxy for routing.
- **Prometheus** — metrics collection.
- **Grafana** — dashboards and visualization for metrics.
- **Navidrome** — the music streaming server.
- **Syncthing** — optional sync service for music folders.
- **FileBrowser** — web UI for browsing and managing files.
- **SFTP** — secure file transfer to your music folder.
- **WUD** — optional web UI to trigger compose actions.
- **ddclient / Cloudflare** — optional dynamic DNS support.
- **beets** — tools used in the library-organizer for tagging/organization.

## Folder overview
- `navidrome-orchestra/`: A lightweight orchestration and observability stack centered on **Navidrome**. It contains Docker Compose files, configuration templates and helper scripts to run Navidrome together with optional services such as **Caddy**, **Prometheus**, **Grafana**, **node-exporter**, **Syncthing**, **FileBrowser**, **SFTP** and the optional **WUD** management UI. See `navidrome-orchestra/README.md` for full details and usage instructions.
- `library-organizer/`: Tools and helper scripts to organize music libraries and transcode files. Includes a `beets` configuration and helper wrappers to run tagging and conversion workflows. See `library-organizer/README.md` for details.

## Server bootstrap helper
To help deploy this on a fresh Ubuntu host, I include a small bash script that automates common server setup tasks (user creation, Docker install, SSH hardening, firewall, fail2ban) and helps copy the `navidrome-orchestra` files to the server. You can use it as a starting point to provision a machine ready to run `navidrome-orchestra`.

Below is the script (fill in the variables at the top before running):

```bash
#!/usr/bin/env bash

###############################################################################
# Server Initialization Script for Navidrome & Orchestra Deployment
# -----------------------------------------------------------------------------
# This script automates the setup of a new Ubuntu server, including:
# - System updates
# - User creation
# - Docker installation
# - SSH hardening
# - Firewall setup
# - Fail2ban configuration
# - Local deployment steps
#
# Fill in the variables below before running.
###############################################################################

# ====== CONFIGURATION ======
SERVER_IP=""
USER="navidrome"
PASSWORD=""
PRIVATE_KEY="$HOME/.ssh/navidrome_key"
SSH_PORT=""

# ====== FUNCTIONS ======
install_docker() {
	echo "[*] Installing Docker..."
	sudo apt install -y ca-certificates curl
	sudo install -m 0755 -d /etc/apt/keyrings
	sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	sudo chmod a+r /etc/apt/keyrings/docker.asc

	sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

	sudo apt update
	sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	sudo usermod -aG docker "$USER"

	echo "[*] Docker installation complete."
}

# ====== SERVER SETUP (run as root) ======
server_setup() {
	echo "[*] Updating system..."
	sudo apt update && sudo apt upgrade -y

	echo "[*] Creating user $USER..."
	sudo adduser "$USER" --disabled-password --gecos ""
	echo "$USER:$PASSWORD" | sudo chpasswd
	sudo usermod -aG sudo "$USER"

	install_docker

	echo "[*] Generating SSH key..."
	ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -q -N ""
	chmod 400 "$PRIVATE_KEY" "${PRIVATE_KEY}.pub"

	echo "[*] Copying SSH key to server..."
	ssh-copy-id -p 22 -i "$PRIVATE_KEY" "$USER@$SERVER_IP"

	echo "[*] Changing SSH port to $SSH_PORT..."
	sudo mkdir -p /etc/systemd/system/ssh.socket.d/
	sudo tee /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
	sudo systemctl restart ssh

	echo "[*] Configuring firewall..."
	sudo apt install -y ufw
	sudo ufw allow OpenSSH
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow "$SSH_PORT"/tcp
	yes | sudo ufw enable

	echo "[*] Installing Fail2ban..."
	sudo apt install -y fail2ban
	sudo tee /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 15m

[sshd]
enabled = true
port = $SSH_PORT
EOF
	sudo systemctl restart fail2ban

	echo "[*] Server setup complete."
}

# ====== LOCAL DEPLOYMENT ======
local_deploy() {
	echo "[*] Copying Orchestra files to server..."
	scp -i "$PRIVATE_KEY" -P "$SSH_PORT" -r navidrome-orchestra/* "$USER@$SERVER_IP:/home/$USER/orchestra"

	echo "[*] Now SSH into the server as $USER and run:"
	echo "    mkdir -p ~/orchestra-volumes ~/music"
	echo "    cd ~/orchestra"
	echo "    # Create .env file manually"
	echo "    bash bootstrap.sh --prod"
}

# Uncomment one of the following depending on what you want to run:
# server_setup
# local_deploy
```

## Contributing

If you have suggestions or find issues, please open an issue on GitHub. Contributions and feedback are welcome.

For more detailed documentation see the README files in each folder:

- `navidrome-orchestra/README.md`
- `library-organizer/README.md`

Enjoy — and happy self-hosting!
