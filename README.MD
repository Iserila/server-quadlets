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
- **AdventureLog** - trip tracker
- **Attic** - home inventory tracker
- **Audiobookshelf** - audiobooks
- **authentik** - SSO / identity provider
- **Directus** - CMS for Geteizem
- **Faved** - bookmark manager
- **FreshRSS** - RSS feed reader
- **Immich** - photo management
- **Jellyfin** - Media server
- **Navidrome** - music server
- **Nginx Proxy Manager** - reverse proxy
- **Ollama** - local LLM inference (GPU-accelerated), internal only, no auth
- **Open WebUI** - chat UI + OpenAI-compatible API gateway in front of Ollama
- **Paperless-ngx** - Document management system
- **RustFS** - S3-compatible object storage
- **Sure** - finances
- **Uptime Kuma** - status page

## Networking
> I wanted to use pods initially, but I had some trouble getting them to work so no pods for now. I do want to try again sometime.

All containers are on the `homelab` network. In Quadlet files, use `Network=homelab` 

> (NOT `Network=homelab.network`, that creates a ghost `systemd-homelab` network instead).

The `homelab.network` quadlet file itself needs `NetworkName=homelab` under `[Network]`, otherwise `podman network create` names it `systemd-homelab` (the quadlet's default naming convention) instead of `homelab`, and every container referencing `Network=homelab` fails with `unable to find network with name or ID homelab: network not found`.

NPM reaches all services by container name over the homelab network. No `PublishPort` needed for proxied services, only for direct LAN access.

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

### Creating Podman secrets
```sh
# Predefined value (no trailing newline - important!)
echo -n "my-pass" | podman secret create secret_name -
# Random secret
openssl rand -hex 32 | tr -d '\n' | podman secret create secret_name -
# Check secret value (to debug newline issues etc.)
podman secret inspect secret_name --showsecret
```
