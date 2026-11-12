# Server Quadlets
The stuff running on my homelab. I'm just getting started, but I will expand on this readme. This serves mostly as a reminder for me how it's configured and some troubleshooting steps I had to go through, since I will most certainly forget.

> I do feel like my quadlets are a bit of a mess. I will get to cleaning them up later...

## The 'Server' 

A repurposed Lenovo IdeaPad S540 acting as a home server.

| | |
|---|---|
| **OS** | Debian 13 (Trixie) |
| **CPU** | Intel Core i7-8565U (8th gen, undervolted) |
| **RAM** | 20GB (4GB soldered + 16GB SODIMM — thanks Lenovo) |
| **Storage** | 512GB M.2 2280 (OS & apps) + 512GB M.2 2242 DRAM-less (data like audiobooks, images etc.) |

## Services
- **AdGuard Home** - network-wide DNS ad blocking, the router hands it out as LAN DNS (host networking, see Networking section)
- **AdventureLog** - trip tracker
- **Attic** - home inventory tracker
- **Audiobookshelf** - audiobooks
- **authentik** - SSO / identity provider
- **Crab Fit** - group availability scheduler (built from source)
- **Directus** - CMS for Geteizem
- **Faved** - bookmark manager
- **FreshRSS** - RSS feed reader
- **Home Assistant** - home automation (host networking, see Networking section)
- **Immich** - photo management
- **Jellyfin** - Media server
- **Navidrome** - music server
- **Nginx Proxy Manager** - reverse proxy
- **Ollama** - local LLM inference (GPU-accelerated), internal only, no auth
- **Open WebUI** - chat UI + OpenAI-compatible API gateway in front of Ollama
- **Paperless-ngx** - Document management system
- **RustFS** - S3-compatible object storage
- **Seafile** - file sync & share (+ SeaDoc for online docs)
- **Sure** - finances
- **Uptime Kuma** - status page

## Networking
> I wanted to use pods initially, but I had some trouble getting them to work so no pods for now. I do want to try again sometime.

All containers are on the `homelab` network. In Quadlet files, use `Network=homelab` 

> (NOT `Network=homelab.network`, that creates a ghost `systemd-homelab` network instead).

The `homelab.network` quadlet file itself needs `NetworkName=homelab` under `[Network]`, otherwise `podman network create` names it `systemd-homelab` (the quadlet's default naming convention) instead of `homelab`, and every container referencing `Network=homelab` fails with `unable to find network with name or ID homelab: network not found`.

NPM reaches all services by container name over the homelab network. No `PublishPort` needed for proxied services, only for direct LAN access.

**Exception: Home Assistant** uses `Network=host` instead of the `homelab` bridge, so mDNS/SSDP-based local device discovery (HomeKit, Chromecast, Sonos, etc.) works. It's not reachable by container-name DNS as a result.

NPM's proxy host for it must forward to the literal pasta gateway IP `169.254.1.2` (port `8123`), **not** the `host-gateway` hostname, even though NPM's own quadlet has `AddHost=host-gateway:host-gateway` and that entry resolves fine via `getent`/`curl` inside the container. NPM's nginx config uses a variable `proxy_pass`, which resolves the upstream at request time through nginx's own DNS resolver — that resolver never consults `/etc/hosts`, so a hostname that only exists as a hosts-file alias (like `host-gateway`) gets NXDOMAIN and a 502, even though it works for any tool that goes through libc's resolver. Always use the raw IP for host-networked apps behind NPM.

**Exception: AdGuard Home** also uses `Network=host`. Per the official docs that's what lets it see real client IPs (on a bridge every query shows up as coming from one address). Port 53 binds rootless fine because `net.ipv4.ip_unprivileged_port_start=53` (in `/etc/sysctl.d`). Its admin UI must stay on port `3000` (pick that in the setup wizard, not the default `80`) since NPM's rootlessport already owns `80`/`443` on the host. NPM proxy host forwards to `169.254.1.2:3000`, same raw-IP rule as HA.

HA also rejects proxied requests by default (`400`, logged as "HTTP integration is not set-up for reverse proxies") until it trusts the proxy's IP. **This can no longer be configured via `configuration.yaml`** — HA's `http` integration migrates its reverse-proxy config to internal storage on first boot and ignores YAML for it from then on (editing the YAML just produces a silently-ignored change plus a "YAML is being ignored" repair item). Fix it via the UI instead: log in directly at `http://<server-lan-ip>:8123` (bypassing NPM, since a direct request carries no `X-Forwarded-For` and sails through unchecked) and go to **Settings → System → Network** to enable "Use X-Forwarded-For" and add the proxy's IP (as seen by HA once pasta forwards it — the host's own LAN IP, not the container-side pasta address) as a trusted proxy. Saving restarts HA to trial the change; confirm it within 5 minutes (via `https://ha.irisa.dev`) or it auto-reverts.

## Secrets
- `attic_db_password`
- `attic_session_secret`
- `attic_admin_password`
- `immich_db_password`
- `sure_db_password`
- `sure_secret_key_base`
- `directus_secret` (Geteizem CMS)
- `directus_db_password` (Geteizem CMS DB)
- `adventurelog_db_password`
- `adventurelog_secret_key`
- `adventurelog_admin_password`
- `paperless_db_password`
- `paperless_secret_key`
- `paperless_admin_password`
- `authentik_db_password`
- `authentik_secret_key`
- `authentik_bootstrap_password_hash`
- `freshrss_oidc_client_id`
- `freshrss_oidc_client_secret`
- `freshrss_oidc_client_crypto_key`
- `openwebui_secret_key` (JWT signing key)
- `rustfs_access_key`
- `rustfs_secret_key`
- `seafile_db_password`
- `seafile_db_root_password` (MariaDB root, Seafile uses it once on first start to create its DBs/user)
- `seafile_admin_password` (initial admin `me@iserila.com`, first start only)
- `seafile_jwt_private_key` (shared by seafile and seadoc, must match)

> `directus_db_password` is a special case: Directus needs its DB password embedded inside a plain env var, and Quadlet's `Secret=...,type=env,target=X` can only map a secret to one whole env var — it can't interpolate a value into part of a larger string. That one is pasted in as plaintext directly in `directus/directus.container`, so keep the secret and the plaintext value in sync if it's ever rotated.
>
> `attic_db_password` hits the same problem (Attic only accepts a single `ATTIC_DATABASE_URL` connection string, no `_FILE` convention) but avoids the plaintext-in-git issue: the secret is mounted as a *file* (`Secret=...,type=mount`) and `attic/attic.container` overrides the entrypoint to build `ATTIC_DATABASE_URL` from that file at container start, before re-exec'ing the image's normal startup chain. Prefer this pattern over pasting plaintext when an app's entrypoint is a simple enough shell script to wrap safely.

## GPU passthrough (Ollama)
The GTX 1650 (4GB VRAM) is passed into the rootless `ollama` container via CDI, using `AddDevice=nvidia.com/gpu=all` in `ollama/ollama.container` — not `--privileged --gpus=all`, that's unnecessary with CDI and works against rootless least-privilege.

Prerequisites (already satisfied on this host, but if setting this up again elsewhere):
- NVIDIA driver + `nvidia-container-toolkit` installed (`nvidia-smi`, `nvidia-ctk --version`).
- CDI spec generated: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`. Must be regenerated after any driver update (the spec embeds the exact driver version in its library-mount paths and hooks).
- **The invoking user must be in the `render` group**, not just `video`. The CDI device bundles `/dev/nvidia0` together with `/dev/dri/card1` *and* `/dev/dri/renderD129`, and the render node is `crw-rw---- root:render`. Without `render` group membership, rootless Podman can't bind-mount it in and the container fails to start. Fix: `sudo usermod -aG render <user>` then `sudo systemctl restart user@1000.service` (the running `systemd --user` manager snapshots its groups at start, so a plain re-login of the SSH session isn't enough — the user manager itself needs to restart).

Ollama's own memory-fit logic (`LLAMA_ARG_FIT_TARGET`, default 1024MiB) reserves a per-device safety margin before deciding how many layers to put on GPU vs CPU — on this 4GB card that margin alone pushed several qwen3:4b layers to CPU even though the model fits. Since nothing else uses this GPU, `ollama/ollama.container` lowers it to 256MiB (`Environment=LLAMA_ARG_FIT_TARGET=256`) to get the full model on GPU. Verify with `podman exec ollama ollama ps` — should show `100% GPU`, not a CPU/GPU split.

## Misc notes
- After editing any `.container` file, always run `systemctl --user daemon-reload`
- `ContainerName=` sets the DNS name on the network, always set it
- Use `podman unshare chown -R 1000:1000 /opt/myapp/data` for volume permissions

## Troubleshooting & snippets

### NPM failing to install certbot-dns-cloudflare / API unhealthy
NPM loses internet access after a reboot because pasta (rootless network backend) doesn't reinitialize properly.
```sh
sudo systemctl restart user@1000.service
```
This restarts all user services. All containers come back up automatically.

> I should fix this sometime..

### Container crash-looping with no logs
Logs disappear because systemd removes the container before you can read them. Run it manually to see output:
```sh
systemctl --user stop <service>.service
podman run --rm --network homelab -e KEY=value <image>
```

### ip_forward disabled (containers have no internet)
Check:
```sh
cat /proc/sys/net/ipv4/ip_forward
```
Fix temporarily:
```sh
sudo sysctl -w net.ipv4.ip_forward=1
```
Made permanent via `/etc/sysctl.d/99-forwarding.conf` - should survive reboots.

### Volume permission denied
Containers run as a remapped UID. Regular `chown` doesn't work:
```sh
# Wrong
sudo chown -R iserila:iserila /opt/myapp/data
# Right
podman unshare chown -R 1000:1000 /opt/myapp/data
```

### homelab network missing MASQUERADE / containers have no outbound internet
Symptom: DNS resolution fails inside containers (`getent hosts google.com` returns nothing), NPM crash-loops trying to install the certbot cloudflare plugin, but the containers are running and the host itself has internet fine.

Check for the NAT rule:
```sh
sudo iptables -t nat -L POSTROUTING -n -v
```
If empty (no MASQUERADE for the bridge subnet), netavark's NAT rule got wiped somehow. Fix by fully recreating the network:
```sh
systemctl --user stop <every service on homelab, see below>
podman network rm homelab
systemctl --user daemon-reload
systemctl --user start homelab-network.service
podman network ls   # confirm it shows `homelab`, not `systemd-homelab`
systemctl --user start <every service on homelab>
```
No static IPs are used anywhere, so recreating the network is safe, containers just get fresh DHCP-style addresses from the bridge and find each other via container-name DNS as usual.

> Root cause unconfirmed, suspect an iptables-nft/netavark interaction or a package update. Watch for recurrence.

### Immich upload/storage mount
Immich expects its data at `/data` inside the container (not `/usr/src/app/upload`):
```ini
Volume=/opt/immich/upload:/data:Z
Volume=/mnt/data/photos:/data/library:Z  # photos on 2nd drive
```
On fresh install, Immich creates its own `.immich` marker files - no need to create them manually.

### Faved: "unable to open database file" on setup
Faved's Apache worker processes run as `www-data` (uid/gid 33) inside the container, not root, so the storage volume needs to be owned by that UID in the container's user namespace before clicking "Create Database":
```sh
podman unshare chown -R 33:33 /opt/faved/storage
```

### Home Assistant (or any host-networked app) 502s in NPM after an update/reboot
The pasta gateway IP used for the `ha.irisa.dev` proxy host (`169.254.1.2`) is a pasta/podman default, not a guaranteed-stable value. Recheck it and update the NPM proxy host's Forward Hostname/IP if it drifted:
```sh
podman exec systemd-nginx-proxy-manager getent hosts host-gateway
```

### AdGuard Home setup / router DNS
First run: `mkdir -p /opt/adguard/{work,conf}`, start the service, open `http://<server-lan-ip>:3000` and run the wizard: admin web interface on all interfaces port **3000**, DNS server on all interfaces port 53.

Router side:
- Give the server a **DHCP reservation** (the router points at its IP, so it must not change).
- Set the server's IP as DNS in the router's **LAN DHCP** settings (what it hands out to clients), not the WAN/ISP DNS field. If the router itself forwards queries, every query in AdGuard shows as coming from the router.

Notes from the official docs:
- Only edit `/opt/adguard/conf/AdGuardHome.yaml` while the container is stopped, the running program overwrites changes.
- In-app auto-update is disabled in Docker, update by pulling the image and restarting the service.

### Seafile setup
Based on the official Seafile 13 CE docker compose (`seafile-server.yml` + `seadoc.yml`), translated to quadlets, with Caddy swapped for NPM per the "Use other reverse proxy" docs page. Container names are `seafile-*` instead of the compose's generic `db`/`redis`, since everything shares the `homelab` network.

First run:
```sh
sudo mkdir -p /opt/seafile/{db,seadoc} && sudo chown -R iserila:iserila /opt/seafile
mkdir -p /mnt/data/seafile
systemctl --user daemon-reload
systemctl --user start seafile-db seafile-redis seafile seadoc
podman logs -f seafile   # wait for "seafile server is running now."
```

All of `/shared` (conf, logs *and* file data) lives on `/mnt/data/seafile`. Splitting just the file data out with a nested mount on `/shared/seafile/seafile-data` doesn't work: the image's `bootstrap.py` skips first-time setup whenever that folder already exists.

After the first start, add this to `/mnt/data/seafile/seafile/conf/seahub_settings.py` and `systemctl --user restart seafile` (Django 4 CSRF origin check behind a proxy, see the Seafile 11 upgrade notes / seahub_settings docs). Without it, logins and forms fail with CSRF errors:
```python
CSRF_TRUSTED_ORIGINS = ["https://seafile.irisa.dev"]
```

NPM proxy host `seafile.irisa.dev` forwards to `seafile:80` with SSL enabled. Put this in its **Advanced** tab. These are the docs' nginx `/sdoc-server/` and `/socket.io` locations pointed at `seadoc:80`, plus the docs' body size and timeout from `location /`. Upstreams go through a variable so a stopped seadoc can't stop NPM's nginx from starting:
```nginx
client_max_body_size 0;
proxy_read_timeout 310s;

location /sdoc-server/ {
    set $seadoc_upstream http://seadoc:80;
    rewrite ^/sdoc-server/(.*)$ /$1 break;
    proxy_pass $seadoc_upstream;
    proxy_redirect     off;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Host  $server_name;
    client_max_body_size 100m;
}

location /socket.io {
    set $seadoc_upstream http://seadoc:80;
    proxy_pass $seadoc_upstream;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_redirect off;
    proxy_buffers 8 32k;
    proxy_buffer_size 64k;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
    proxy_set_header X-NginX-Proxy true;
}
```

Notes from the official docs:
- `INIT_SEAFILE_*` values (admin account, DB root password) only matter on the first start. Reset the admin with `podman exec -it seafile /opt/seafile/seafile-server-latest/reset-admin.sh`.
- Deleted files leave orphaned blocks behind (dedup), so run Seafile GC now and then to reclaim space.
- To start over after a failed install, stop everything and wipe `/mnt/data/seafile` and `/opt/seafile/{db,seadoc}`.

### Crab Fit setup
Upstream publishes no container images (the API runs on Fly.io, the frontend on Vercel), so both are built from source by Quadlet `.build` units (`crabfit/crabfit-*.build` + the `.Containerfile`s next to them). The `.container` files use `Image=crabfit-*.build`, so starting a service builds its image first. Both Containerfiles check out a pinned upstream commit (`CRABFIT_REF`). The repo has been inactive since Aug 2023.

Why the API Containerfile doesn't just reuse upstream's `api/Dockerfile`:
- Upstream builds on `rust:latest` (now trixie) but runs on `debian:bullseye-slim`, so the glibc/libssl versions don't match. Both stages are pinned to bookworm here.
- The lockfile's `time 0.3.21` doesn't compile on Rust >= 1.80, hence `rust:1.79`.
- It uses `--features sql-adaptor` with SQLite (`DATABASE_URL=sqlite:///data/crabfit.db?mode=rwc`) instead of Google Datastore. Migrations run on startup.
- `crabfit/sqlite-inline-fk.patch` fixes upstream's SQLite support, which is broken despite being advertised. The only migration adds the `person` → `event` foreign key with a separate `ALTER TABLE`, which SQLite can't do, so the API panics on first start with `Sqlite does not support modification of foreign key constraints to existing tables`. The patch declares the FK inline in `CREATE TABLE`, which every backend supports.

`NEXT_PUBLIC_API_URL` is baked into the frontend bundle at **build time**, so it's a `--build-arg` (via `PodmanArgs=`) in `crabfit-frontend.build`, not an env var. The share links and `metadataBase` are hardcoded to `https://crab.fit` upstream, and the Containerfile `sed`s them to `FRONTEND_URL`.

First run (the first build of the Rust API takes a while):
```sh
sudo mkdir -p /opt/crabfit/data && sudo chown -R iserila:iserila /opt/crabfit
podman unshare chown -R 1000:1000 /opt/crabfit/data   # API runs as uid 1000 "app"
systemctl --user daemon-reload
systemctl --user start crabfit-api crabfit-frontend
journalctl --user -fu crabfit-api-build                # follow the build
```

NPM proxy hosts (SSL on both):
- `crab.irisa.dev` → `crabfit-frontend:3000`
- `crab-api.irisa.dev` → `crabfit-api:3000`

Updating: bump `CRABFIT_REF` in both Containerfiles (or change a `--build-arg` in `PodmanArgs`, Podman 5.4 has no `BuildArg=` key yet), then `systemctl --user daemon-reload && systemctl --user restart crabfit-api-build crabfit-frontend-build crabfit-api crabfit-frontend`.

Notes:
- The API rate limit (burst 20, +1 per 500ms) is keyed on peer IP, which is always NPM's, so every user shares one bucket. Fine for a few people.
- Events not visited in 3 months are only removed when something calls `GET https://crab-api.irisa.dev/tasks/cleanup`. Nothing schedules that yet.
- The frontend includes Vercel's `<Analytics/>`, whose script 404s here. That's harmless.

### Creating Podman secrets
```sh
# Predefined value (no trailing newline - important!)
echo -n "my-pass" | podman secret create secret_name -
# Random secret
openssl rand -hex 32 | tr -d '\n' | podman secret create secret_name -
# Check secret value (to debug newline issues etc.)
podman secret inspect secret_name --showsecret
```
