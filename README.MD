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
- **Audiobookshelf** - audiobooks
- **Directus** - CMS for Geteizem
- **Immich** - photo management
- **Navidrome** - music server
- **Nginx Proxy Manager** - reverse proxy
- **Sure** - finances
- **Uptime Kuma** - status page

## Networking
> I wanted to use pods initially, but I had some trouble getting them to work so no pods for now. I do want to try again sometime.

All containers are on the `homelab` network. In Quadlet files, use `Network=homelab` 

> (NOT `Network=homelab.network`, that creates a ghost `systemd-homelab` network instead).

NPM reaches all services by container name over the homelab network. No `PublishPort` needed for proxied services, only for direct LAN access.

## Secrets
- `immich_db_password`
- `sure_db_password`
- `sure_secret_key_base`
- `directus_secret` (Geteizem CMS)
- `directus_db_password` (Geteizem CMS DB)
- `adventurelog_db_password`
- `adventurelog_secret_key`
- `adventurelog_admin_password`

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

### Immich upload/storage mount
Immich expects its data at `/data` inside the container (not `/usr/src/app/upload`):
```ini
Volume=/opt/immich/upload:/data:Z
Volume=/mnt/data/photos:/data/library:Z  # photos on 2nd drive
```
On fresh install, Immich creates its own `.immich` marker files - no need to create them manually.

### Creating Podman secrets
```sh
# Predefined value (no trailing newline - important!)
echo -n "my-pass" | podman secret create secret_name -
# Random secret
openssl rand -hex 32 | tr -d '\n' | podman secret create secret_name -
# Check secret value (to debug newline issues etc.)
podman secret inspect secret_name --showsecret
```