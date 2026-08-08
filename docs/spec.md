# Media Server Build Specification

A self-hosted media server for a home network, serving a personal library of
TV, film, and anime to Apple TV via Infuse, with automated acquisition and
management.

---

## 1. Hardware

| Component | Spec | Notes |
|---|---|---|
| CPU | Intel Core i7-8700K (Coffee Lake) | Quick Sync: HEVC 8/10-bit encode+decode, VP9 |
| Motherboard | MSI Z370 GODLIKE GAMING | Killer E2500 NIC (`alx` driver) |
| RAM | 32 GB | Far more than required |
| OS disk | 500 GB SSD | OS, Docker, container configs |
| Media disk | Seagate IronWolf ST8000VN004 (8 TB, CMR, 7200rpm) | Single drive to start |
| Network | Wired gigabit LAN | Onboard WiFi is dead and must be disabled in BIOS |
| GPU | None (discrete card removed) | iGPU used for transcoding |

### 1.1 BIOS configuration

Required:

- **Integrated Graphics: Enabled**
- **IGD Multi-Monitor: Enabled**
- **Initiate Graphic Adapter: IGD**
- **Integrated Graphics Share Memory: 64 MB or higher**
- **Onboard WiFi module: Disabled** (hardware is faulty)
- **Restore on AC Power Loss: Power On** (recovers unattended after outages)
- **Fast Boot: Disabled**
- All **C-states: Enabled**

Recommended for power and noise:

- Disable onboard audio, second LAN port, and unused controllers
- Set a quiet-but-steady fan curve; the box idles 24/7 rather than bursting
- Ensure at least one fan directs airflow across the drive bay

### 1.2 Known board quirks

- **M.2 / SATA lane sharing.** Populating certain M.2 slots disables specific
  SATA ports on Z370. Consult the board manual's block diagram before
  planning drive layout. If more than six SATA ports are eventually needed,
  an LSI 9211-8i flashed to IT mode is the standard solution.
- **Idle power** on this flagship board is high relative to a purpose-built
  NAS, realistically 60-90 W with drives spinning.

---

## 2. Operating System

**Debian 13 (Trixie), minimal server install.**

- No desktop environment
- SSH server enabled
- Non-free firmware included (installer default in Debian 13)
- Static IP or DHCP reservation on the LAN
- Unattended-upgrades enabled for security updates only

Rationale: five-year support lifecycle, no SELinux friction with Docker bind
mounts, and the assumed baseline for essentially all self-hosting
documentation.

### 2.1 Post-install packages

```
docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
smartmontools
intel-gpu-tools
vainfo
curl git htop
```

Docker must come from Docker's official repository, not Debian's `docker.io`
package.

### 2.2 Remote access — WireGuard

Remote administration is a self-hosted WireGuard server, `wg-easy`, running as
part of the stack rather than as a host package. There is nothing to install
here: `docker compose up -d` brings it up and it creates `wg0` on first start.

Two host prerequisites, both handled by `setup.sh`, and both needed because the
container uses host networking and therefore cannot set them itself:

- the `wireguard` module loaded at boot, via `/etc/modules-load.d`
- IPv4/IPv6 forwarding, via `/etc/sysctl.d/99-wireguard.conf`

The router forwards **UDP `WG_PORT`** in addition to TCP 80 and 443. The wg-easy
admin UI on `WG_UI_PORT` is never forwarded — it is reachable from the LAN and
through the tunnel only.

Peers are issued a **split tunnel**: `AllowedIPs` covers the LAN subnet and the
WireGuard subnet, nothing else. That is what makes an address like
`http://<lan-ip>:8989` resolve identically at home and away, which the landing
page depends on — it templates one `ADMIN_HOST` and has no way to render a
different link per network. See decisions.md D26.

---

## 3. Storage

### 3.1 Layout

The 8 TB drive is mounted at `/mnt/disk1`, and `/data` is a bind mount onto it.
This indirection exists so that adding drives later means swapping the bind
mount for a mergerfs pool, with zero changes to container paths, no library
rescan, and no broken hardlinks.

```
/mnt/disk1/data/
├── torrents/
│   ├── movies/
│   ├── tv/
│   └── anime/
├── usenet/
│   ├── incomplete/
│   └── complete/
│       ├── movies/
│       ├── tv/
│       └── anime/
└── media/
    ├── movies/
    ├── tv/
    └── anime/
```

`usenet/` is a sibling of `torrents/` and `media/` for the same reason they are
siblings of each other: everything must sit on one filesystem or imports stop
hardlinking (§3.3). Both download trees have to be checked, not just one.

`/data` is bind-mounted to `/mnt/disk1/data` and is the only path any
container ever sees.

### 3.2 Filesystem

- ext4, formatted with `-m 0` (the default 5% root reserve wastes ~400 GB)
- Mounted by UUID in `/etc/fstab`
- Mount options: `defaults,noatime`

Example `/etc/fstab` entries:

```
UUID=<disk1-uuid>  /mnt/disk1  ext4  defaults,noatime  0  2
/mnt/disk1/data    /data       none  bind              0  0
```

### 3.3 Critical constraint: hardlinks

`torrents/` and `media/` **must** be on the same filesystem. Sonarr and Radarr
hardlink completed downloads into the library rather than copying, which means
imports are instant, disk usage is not doubled, and seeding continues
uninterrupted. Splitting these across filesystems silently degrades to copying.

### 3.4 Permissions

Create a dedicated service user and use its UID/GID for all containers.

```
groupadd -g 1000 media
useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin media
chown -R media:media /mnt/disk1/data
chmod -R 775 /mnt/disk1/data
```

Set `PUID=1000` and `PGID=1000` in the container environment.

The `media` user must also be in the `render` group for `/dev/dri` access.

### 3.5 SMART monitoring

Configure `smartd` with:

- Short self-test daily
- Long self-test weekly
- Email alert on any attribute failure or reallocated sector growth

This is not optional. A single-drive setup has no redundancy, so early warning
is the only protection.

### 3.6 Growth path

When a second drive is added:

1. Mount it at `/mnt/disk2`, same ext4 and permissions setup
2. Install `mergerfs`
3. Replace the `/data` bind mount with a mergerfs pool over `/mnt/disk*`
4. Set create policy to `epmfs` (existing path, most free space) so that a
   given title's download and library file land on the same physical disk,
   preserving hardlinks
5. Restart the stack

SnapRAID can be added later with a dedicated parity drive, sized at or above
the largest data drive.

**Note:** neither mergerfs nor SnapRAID is a backup. Irreplaceable data
(personal photos, home video, documents) must not live solely on this machine.

---

## 4. Application Stack

All services run as Docker containers, orchestrated by a single
`docker-compose.yml`. Container configs live on the SSD at
`/opt/mediaserver/<service>`.

| Service | Image | Port | Purpose |
|---|---|---|---|
| Jellyfin | `lscr.io/linuxserver/jellyfin` | 8096 | Media server, Infuse source |
| Jellyseerr | `fallenbagel/jellyseerr` | 5055 | Requests — the household front door |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | 9696 | Indexer manager |
| Sonarr | `lscr.io/linuxserver/sonarr` | 8989 | TV and anime |
| Radarr | `lscr.io/linuxserver/radarr` | 7878 | Films |
| Bazarr | `lscr.io/linuxserver/bazarr` | 6767 | Subtitles |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | 8080 | Torrent download client |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | 8085 | Usenet download client |
| Recyclarr | `ghcr.io/recyclarr/recyclarr` | n/a | Trash Guides quality profile sync |
| Caddy | `caddy:alpine` | 80/443 | Reverse proxy, bound to the LAN address |
| wg-easy | `ghcr.io/wg-easy/wg-easy` | 51820/udp, 51821 | Remote access — WireGuard server, host networking |
| Gluetun | `qmcgaw/gluetun` | n/a | Outbound VPN for qBittorrent (deferred, see §7) |

Both download protocols are present deliberately. The *arrs speak both and pick
per release: SABnzbd is given priority 1 because Usenet is faster, has better
retention and carries no seeding obligation, and qBittorrent priority 2. They
are not redundant — Usenet covers anime poorly, so in practice Usenet carries TV
and film while torrents carry anime. Note that Usenet needs two subscriptions
from different companies: a **provider** (the news server holding the articles)
and an **indexer** (the catalogue that hands over an `.nzb`). Indexers alone
download nothing. See decisions.md D14.

### 4.1 Volume mapping rule

Every container that touches media mounts the **same** path:

```yaml
volumes:
  - /data:/data
```

Not `/data/media:/media`. Not `/data/tv:/tv`. Identical paths across all
containers is what makes hardlinking work and is the single most common source
of "why won't it import" failures.

Config volumes are per-service and live on the SSD:

```yaml
  - /opt/mediaserver/sonarr:/config
```

### 4.2 Hardware transcoding

Jellyfin requires GPU passthrough:

```yaml
devices:
  - /dev/dri:/dev/dri
group_add:
  - "<render-gid>"   # from: getent group render
```

In Jellyfin's playback settings:

- Hardware acceleration: **VAAPI**
- Device: `/dev/dri/renderD128`
- Enable hardware decoding for H.264, HEVC, VP9
- Enable hardware encoding

Verify on the host before starting: `vainfo` should list H.264 and HEVC
encode/decode entrypoints. If `/dev/dri` does not exist, the iGPU is disabled
in BIOS.

Note: with Infuse as the primary client, transcoding is rarely invoked because
Infuse direct-plays nearly all codecs and containers. This config matters for
browser playback and remote clients.

---

## 5. Network and Access

### 5.1 Access model

There are two doors, and which one you use depends on who you are.

- **The household — public.** `media.thorby.tech` over the internet: the landing
  page, Jellyfin and Jellyseerr, and nothing else. Ports 80 and 443 are
  forwarded from the router to Caddy. No VPN, no app to install.
- **The administrator — WireGuard.** The seven admin apps are reached at
  `<lan-ip>:<port>`, directly, with no proxy in front of them. On the LAN that
  works already; from anywhere else, bring up the tunnel first and the same
  address works. Nothing about them is public, and nothing about them is routed.
- **Local LAN:** direct access to all services by IP and port, unchanged.
- **Apple TV:** Infuse connects to Jellyfin over LAN. Remote playback goes
  through the public Jellyfin name rather than the VPN, so the Apple TV needs no
  client of its own.

The asymmetry is the point. The two apps the household needs are the two whose
worst case is a leaked media library; the ones it does not need are those whose
worst case is a shell (§5.3).

### 5.2 Caddy

Caddy serves **three names and no more**, on the LAN address the router forwards
to. Certificates come from Let's Encrypt over HTTP-01, which requires both 80
and 443 to be forwarded.

Reverse proxy targets:

- `media.thorby.tech` -> the landing page (static, served by Caddy itself)
- `jellyfin.media.thorby.tech` -> `jellyfin:8096`
- `seerr.media.thorby.tech` -> `jellyseerr:5055`

Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent and SABnzbd have **no route here
and no DNS record**. That is the mechanism enforcing §5.3 — not a firewall rule
that could be edited, not a password that could be weak, but the absence of any
path from the internet to them. `scripts/validate.sh` fails if one of those six
names appears in `caddy/sites.caddy` at all.

Caddy also writes a JSON access log. It is the only entry point from the internet
and none of the apps behind it record who reached them, so it is the only place
an access record can exist. It is also what the fail2ban `caddy-auth` jail reads,
and the only log that sees the true client address — Jellyfin and Jellyseerr both
see Caddy's container IP unless `KnownProxies` says otherwise.

### 5.3 Security constraints

**The *arr web UIs and qBittorrent must never be exposed to the public
internet.** qBittorrent's "run external program on torrent completion" feature
is arbitrary command execution by design; a valid session is equivalent to a
shell. The *arr apps authenticate API access by a key visible in their own UI.
Neither was designed for hostile network exposure.

Since §5.1 now forwards ports from the router, this constraint needs a
mechanism rather than a promise. It has three, in order of how hard they are to
undo by accident:

1. **No route.** Those six are absent from `caddy/sites.caddy`, so the proxy has
   nowhere to send a request for them even if one arrived. Asserted by
   `validate.sh`.
2. **No DNS.** Only three names exist publicly. Nothing resolves to the box for
   the other six.
3. **No packet.** The `DOCKER-USER` chain returns only ports 80 and 443 from
   off-box; a WAN packet aimed at 8989 is DNAT'd to Sonarr and then dropped.

Additionally:

- Change qBittorrent's default credentials on first login
- Enable authentication in every *arr app
- Leave qBittorrent's external-program setting empty
- UFW: allow SSH, `wg0`, the LAN, 80/443 and the WireGuard port; deny otherwise

None of these can be left to a human remembering. Each is either pinned in
configuration or asserted by `scripts/audit-auth.sh`, which is run against the
live stack and fails loudly. Three things are worth stating explicitly because
they are not obvious:

- **Authentication must be required for *all* addresses, not just remote ones.**
  The *arrs offer `AuthenticationRequired = DisabledForLocalAddresses`, which is
  common advice and is wrong here: Caddy reaches the backends over the compose
  bridge, so every proxied request carries a private source address and skips
  authentication. Verified — with that setting, `GET /` returns 200 with no
  login. The auth method and scope are therefore pinned as environment variables
  in `docker-compose.yml`, which are re-applied on every container start, so an
  accidental UI change reverts rather than persisting.
- **UFW does not filter Docker-published ports.** Published ports are DNAT'd and
  traverse `FORWARD`, never `INPUT`, so `ufw default deny incoming` does not
  apply to any service in this stack. `setup.sh` installs matching rules in the
  `DOCKER-USER` chain; without them the only real boundary is the absence of a
  router port forward. See decisions.md D19.
- **SABnzbd is the same class of risk as qBittorrent.** It runs post-processing
  scripts, so an open SABnzbd UI is arbitrary command execution just as an open
  qBittorrent UI is. Bazarr has full write access to the library.

---

## 6. Configuration Sequence

Order matters; each step depends on the previous.

1. **qBittorrent.** Set credentials. Create categories `movies`, `tv`, `anime`
   with save paths under `/data/torrents/`. Enable preallocation. Set
   incomplete downloads to a subfolder within the same path (not a different
   filesystem).
2. **Prowlarr.** Add indexers. Include anime-specific ones (see §8).
3. **Prowlarr -> apps.** Add Sonarr and Radarr under Settings > Apps. Indexers
   sync automatically from this point on.
4. **Sonarr and Radarr -> qBittorrent.** Add as download client, matching the
   category names from step 1.
5. **Root folders.** Sonarr: `/data/media/tv` and `/data/media/anime`. Radarr:
   `/data/media/movies`.
6. **Verify hardlinking.** In Sonarr/Radarr, ensure "Use Hardlinks instead of
   Copy" is enabled. Test with one import and confirm via `ls -li` that the
   inode is shared and disk usage did not double. **Do not skip this check.**
7. **Bazarr.** Connect to Sonarr and Radarr, configure subtitle providers and
   languages.
8. **Jellyfin.** Create libraries pointing at `/data/media/movies`,
   `/data/media/tv`, `/data/media/anime`. Configure hardware acceleration.
9. **Infuse.** Add Jellyfin as a source. This preserves watch state, resume
   position, and library sync across devices, which a plain SMB share does not.

### 6.1 Naming conventions

Use the Trash Guides recommended naming schemes in Sonarr and Radarr. Jellyfin
matches reliably against them, and they encode quality and edition information
that Infuse surfaces.

---

## 7. Deferred: VPN for qBittorrent

Gluetun is included in the compose file but **commented out** initially, as no
provider has been selected yet.

When enabling:

1. Uncomment the `gluetun` service and populate provider credentials
2. Change qBittorrent's `network_mode` to `service:gluetun`
3. Remove qBittorrent's `ports:` block and move those port mappings onto
   `gluetun`
4. Configure port forwarding and set the forwarded port as qBittorrent's
   listening port

**Port forwarding is the deciding feature** when choosing a provider. Without
it, inbound peer connections fail and seeding is severely degraded. Note that
Mullvad and IVPN have both removed port forwarding and are unsuitable for this
role despite being otherwise excellent.

Candidate providers with working port forwarding and Gluetun support: Proton
VPN Plus (NAT-PMP, Gluetun can auto-configure qBittorrent's port), AirVPN
(manual port assignment via web panel), Private Internet Access.

---

## 8. Anime Handling

Anime requires specific configuration and should be kept separate from the
main TV library.

- **Series Type: Anime** in Sonarr enables absolute episode numbering, which
  is how the vast majority of anime releases are named.
- **Dedicated root folder** `/data/media/anime`, added to Jellyfin as its own
  library. TVDB season splits frequently disagree with release numbering, so
  isolation prevents that inconsistency from affecting the main TV library.
- **Anime indexers are mandatory.** Nyaa.si, AnimeTosho, and SubsPlease.
  General-purpose trackers carry very little anime; without these, Sonarr will
  find nothing.
- **Separate quality profile** with "Anime Release Group" as a preferred term.
  Decide on dual-audio versus subtitle-only up front, as this drives group
  preferences significantly.
- **Recyclarr** provides maintained anime quality profiles that encode
  community release-group rankings. Strongly recommended over hand-tuning.
- **Anime films** are handled by Radarr with no special configuration.

For very large or long-running collections where TVDB mapping proves
inadequate, Shoko Server with AniDB metadata is the more rigorous option, at
the cost of considerable additional setup.

---

## 9. Deliverables

Claude Code should produce:

1. `docker-compose.yml` implementing §4, with Gluetun present but commented
2. `.env` template for `PUID`, `PGID`, `TZ` (Africa/Johannesburg), and paths
3. `Caddyfile` implementing §5.2, bound to the LAN address the router forwards to
4. `setup.sh` covering: package installation, user and group creation,
   directory tree creation, fstab entries, smartd configuration, SSH hardening,
   unattended security updates, the config-backup timer, and UFW rules
   (including the `DOCKER-USER` chain — see §5.3)
5. `README.md` documenting the configuration sequence in §6 and the mergerfs
   migration path in §3.6

### 9.1 Verification checklist

Before considering the build complete:

- [ ] `vainfo` reports HEVC and H.264 encode/decode entrypoints
- [ ] `/dev/dri/renderD128` is visible inside the Jellyfin container
- [ ] A test import produces a shared inode (`ls -li`), not a copy —
      for **both** `torrents/` and `usenet/`
- [ ] Disk usage does not double after import
- [ ] Admin apps reachable over WireGuard at the same `<lan-ip>:<port>` used on
      the LAN, and none of them reachable over the public IP
- [ ] `smartd` sends a test alert successfully
- [ ] qBittorrent default credentials changed
- [ ] `scripts/audit-auth.sh` passes — every app enforces authentication
- [ ] A config backup restores and the restored Sonarr database opens
- [ ] Machine boots unattended and all containers start after a hard power cut
