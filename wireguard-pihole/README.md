# WireGuard + Pi-hole

Runs a WireGuard VPN server alongside a Pi-hole DNS sinkhole. When your phone (or any device) connects to the VPN, all DNS queries are automatically routed through Pi-hole for ad blocking and privacy.

```
Phone / Laptop
     │  WireGuard tunnel (UDP 51820)
     ▼
┌─────────────────────────────────────┐
│  Docker host (your server)          │
│                                     │
│  ┌───────────┐    ┌──────────────┐  │
│  │ WireGuard │───▶│   Pi-hole    │  │
│  │ 10.13.13.1│    │ 172.20.0.2   │  │
│  └───────────┘    └──────────────┘  │
└─────────────────────────────────────┘
```

**Tunnel subnet:** `10.13.13.0/24`  
**Docker network:** `172.20.0.0/24`  
**Client DNS:** `172.20.0.2` (Pi-hole) – set automatically in every peer config

---

## Quick start

### 1. Prerequisites

- Docker and Docker Compose v2 installed on the server
- UDP port `51820` (or your chosen port) open in the server firewall / security group
- `git clone` or copy this folder to the server

### 2. Configure

```bash
cp .env.example .env
nano .env          # set SERVER_URL, PIHOLE_PASSWORD, TIMEZONE
```

| Variable | Description |
|---|---|
| `SERVER_URL` | Public IP or domain of the server (used as the WireGuard endpoint) |
| `SERVER_PORT` | UDP port (default `51820`) |
| `PIHOLE_PASSWORD` | Pi-hole web admin password |
| `TIMEZONE` | e.g. `Europe/Berlin` |
| `INITIAL_PEERS` | Comma-separated peer names created on first startup (default `phone`) |

### 3. Start the stack

```bash
docker compose up -d
```

On first run the WireGuard container generates:
- Server keys in `config/wireguard/`
- One peer config + QR code per name listed in `INITIAL_PEERS`

### 4. Connect your phone

```bash
# View the QR code for the initial "phone" peer
docker exec wireguard cat /config/peer_phone/peer_phone.png | display   # if imagemagick is available
# or just cat the config
cat config/wireguard/peer_phone/peer_phone.conf
```

Import the `.conf` file or scan the QR code (`peer_phone.png`) in the **WireGuard** app on your phone. Connect and all DNS will go through Pi-hole automatically.

---

## Adding more clients

Use the included script to generate a new peer without restarting the stack:

```bash
./add-client.sh <client-name>
```

**Examples:**

```bash
./add-client.sh laptop
./add-client.sh tablet
./add-client.sh work-pc
```

The script will:
1. Generate a new key pair and preshared key inside the WireGuard container
2. Find the next free IP in `10.13.13.0/24`
3. Add the peer to the live WireGuard interface (active immediately)
4. Append the peer block to `wg0.conf` for persistence across restarts
5. Save the client config to `config/wireguard/peer_<name>/<name>.conf`
6. Print a QR code (requires `qrencode` on the host: `apt-get install qrencode`)

---

## Pi-hole web interface

| Location | URL |
|---|---|
| From the server itself | `http://localhost:8080/admin` |
| While connected via WireGuard | `http://172.20.0.2/admin` |

To restrict the web UI to WireGuard clients only, comment out the `ports` block under the `pihole` service in `docker-compose.yml`.

---

## Directory layout

```
wireguard-pihole/
├── docker-compose.yml
├── .env.example          ← copy to .env and fill in values
├── add-client.sh         ← script to add new WireGuard peers
├── README.md
└── config/               ← created automatically on first run
    ├── wireguard/
    │   ├── wg_confs/wg0.conf   ← server config (peers appended here)
    │   ├── server_privatekey
    │   ├── server_publickey
    │   └── peer_<name>/        ← one dir per peer
    │       ├── <name>.conf     ← client config (import this)
    │       └── <name>.png      ← QR code image
    └── pihole/
        ├── etc-pihole/
        └── etc-dnsmasq.d/
```

> **Note:** The `config/` directory contains private keys. Keep it out of version control (it is already in `.gitignore` if you use the default setup).

---

## Updating

```bash
docker compose pull
docker compose up -d
```

## Stopping

```bash
docker compose down
```
