# Media Server Build Specification

A self-hosted media server for a home network, serving a personal library of
TV, film, anime and music to Apple TV via Infuse, with automated acquisition and
management.

---

## 1. Hardware

| Component | Spec | Notes |
|---|---|---|
| CPU | Intel Core i7-8700K (Coffee Lake) | Quick Sync: HEVC 8/10-bit encode+decode, VP9 |
| Motherboard | MSI Z370 GODLIKE GAMING | Killer E2500 NIC (`alx` driver) |
| RAM | 32 GB | Far more than required |
| OS disk | 500 GB SSD | OS, Docker, container configs |
| Media disk | 2 TB, temporary — 10 TB CMR planned | Single drive; see §3.2 |
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
page depends on — it templates one `ADMIN_HOST` for every admin link and has no
way to tell a tunnel client from a LAN one. See decisions.md D26.

What it *can* tell is a private client from a public one, and since D31 it uses
that: the two public tiles render `http://<lan-ip>:<port>` for anyone inside and
the public name for everyone else. Same single `ADMIN_HOST`, so the property
above still has to hold — one address that works at home and away.

---

## 3. Storage

### 3.1 Layout

The media drive is mounted at `/mnt/disk1`, and `/data` is a bind mount onto it.
This indirection exists so that adding *or replacing* drives later means
swapping the bind mount, with zero changes to container paths, no library
rescan, and no broken hardlinks. It is what makes the 2 TB → 10 TB swap in §3.2
a mount-point change rather than a migration.

```
/mnt/disk1/data/
├── torrents/
│   ├── movies/
│   ├── tv/
│   ├── anime/
│   └── music/
├── usenet/
│   ├── incomplete/
│   └── complete/
│       ├── movies/
│       ├── tv/
│       ├── anime/
│       └── music/
└── media/
    ├── movies/
    ├── tv/
    ├── anime/
    └── music/
```

`usenet/` is a sibling of `torrents/` and `media/` for the same reason they are
siblings of each other: everything must sit on one filesystem or imports stop
hardlinking (§3.3). Both download trees have to be checked, not just one.

`/data` is bind-mounted to `/mnt/disk1/data` and is the only path any
container ever sees.

### 3.2 Filesystem

**The current disk is a temporary 2 TB.** A 10 TB CMR drive is planned and will
replace it rather than join it, at which point the box is expected to be rebuilt
from this repo rather than migrated in place — which is the cheaper option while
the library is small, and is only affordable because nothing here hardcodes a
capacity. Everything below is size-independent.

Two consequences worth holding while the 2 TB is in place. The Radarr profile is
sized for the 10 TB (§8), so the disk fills in roughly 65–130 films; and nothing
in the stack warns as it approaches full — see decisions.md D27 for what is
deliberately *not* implemented.

- ext4, formatted with `-m 0` — the default 5% root reserve is for a system
  disk that must not fill, and on a pure data disk it is simply lost (~100 GB
  on 2 TB, ~500 GB on 10 TB)
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
groupadd -g 1001 media
useradd -u 1001 -g 1001 -M -s /usr/sbin/nologin media
chown -R media:media /mnt/disk1/data
chmod -R 775 /mnt/disk1/data
```

Set `PUID=1001` and `PGID=1001` in the container environment.

1001 rather than 1000: Debian assigns 1000 to the first human account created
during installation, so on this box it belongs to `nick`. `setup.sh` refuses to
bind the media tree to an account it did not create. Keeping the service user
off the administrator's uid is also what makes it a service user — a container
escape lands on something with no shell and no sudo (decisions.md D32).

The `media` user must also be in the `render` group for `/dev/dri` access, and
the administrator should be in the `media` group so the 775 tree stays editable
by hand without sudo. `setup.sh` does both.

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
| Lidarr | `lscr.io/linuxserver/lidarr` | 8686 | Music — API is v1, not v3 |
| Bazarr | `lscr.io/linuxserver/bazarr` | 6767 | Subtitles |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | 8080 | Torrent download client |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | 8085 | Usenet download client |
| Cleanuparr | `ghcr.io/cleanuparr/cleanuparr` | 11011 | Download queue cleanup — qBittorrent only |
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

Two asymmetries in that table are deliberate and worth stating rather than
rediscovering. **Lidarr has no request path**: Jellyseerr is a film and TV
product and cannot request music, so unlike Sonarr and Radarr nothing in front
of it is household-facing — adding an artist is an administrator's job. Recyclarr
has no Lidarr support either, so its quality profiles are set by hand.
**Cleanuparr cleans qBittorrent only**: it has no SABnzbd support, and since
SABnzbd holds download-client priority 1 the queue carrying most TV and film is
not covered by it. Both are accepted; see decisions.md D29 and D30.

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

**There is one door: WireGuard** (decisions.md D33). This section described two
until the box was built; the public one is closed.

- **At home — direct.** Every service is reached at `<lan-ip>:<port>` on the
  LAN, and the three served names (`media.thorby.tech`, `jellyfin.` and
  `seerr.`) resolve to that same LAN address. Nothing leaves the house.
- **Away — WireGuard first.** The tunnel puts the peer on the LAN, so every
  address above works unchanged from anywhere. This applies to the household as
  well as the administrator; there is no unauthenticated path in for anyone.
- **Apple TV:** Infuse connects to Jellyfin over the LAN and needs no client of
  its own at home. A set taken elsewhere needs the WireGuard tvOS app.
- **The router forwards `WG_PORT` and nothing else.** No 80, no 443. `.env`'s
  `PUBLIC_HTTP` switch gates that, and `setup.sh` closes those ports if an
  earlier run opened them.

Certificates therefore come from **DNS-01** against the Cloudflare zone, since
no HTTP-01 challenge can reach a box with nothing forwarded (`caddy/Dockerfile`).

The old asymmetry — the two apps the household needs are the two whose worst
case is a leaked library, the rest have a worst case of a shell — still shapes
§5.3, and is now defence in depth rather than the boundary itself.

### 5.2 Caddy

Caddy serves **three names and no more**, on the LAN address the router forwards
to. Certificates come from Let's Encrypt over HTTP-01, which requires both 80
and 443 to be forwarded.

Reverse proxy targets:

- `media.thorby.tech` -> the landing page (static, served by Caddy itself)
- `jellyfin.media.thorby.tech` -> `jellyfin:8096`
- `seerr.media.thorby.tech` -> `jellyseerr:5055`

Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, qBittorrent, SABnzbd and Cleanuparr
have **no route here and no DNS record**. That is the mechanism enforcing §5.3 —
not a firewall rule that could be edited, not a password that could be weak, but
the absence of any path from the internet to them. `scripts/validate.sh` fails if
one of those eight names appears in `caddy/sites.caddy` at all.

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

Under D33 the router forwards nothing but the WireGuard port, so the first-order
answer is that no packet from the internet reaches any of them at all. The three
mechanisms below are kept anyway, because they are what makes that still true
the day someone sets `PUBLIC_HTTP=true` — which is exactly the day nobody will
re-derive this reasoning:

1. **No route.** Those eight are absent from `caddy/sites.caddy`, so the proxy
   has nowhere to send a request for them even if one arrived. Asserted by
   `validate.sh`.
2. **No DNS.** Only three names resolve to the box, and they resolve to a
   private address. Nothing resolves at all for the other eight.
3. **No packet.** The `DOCKER-USER` chain drops anything arriving off-box; with
   `PUBLIC_HTTP=false` not even 80 and 443 are returned.

**Cleanuparr is on that list at one remove, and belongs there.** It runs no
scripts of its own, but it holds the qBittorrent WebUI credential and every *arr
API key in order to do its job — so a session on Cleanuparr reaches the same
arbitrary command execution the paragraph above is about, with one extra click.
It is excluded by the same three mechanisms and audited like the rest (D30).

**The ninth admin surface is the wg-easy UI, and it is excluded differently.**
The eight above are Docker publishes, which is why they need `DOCKER-USER` — UFW
never sees them. wg-easy runs with host networking, so `WG_UI_PORT` is an
ordinary host listener that `ufw default deny incoming` genuinely filters, and
the router never forwards it. Same outcome, different mechanism; `validate.sh`'s
route check does not cover it because there is no route to check, so the control
that matters there is `audit-auth.sh` (decisions.md D26).

Additionally:

- Change qBittorrent's default credentials on first login
- Enable authentication in every *arr app
- Leave qBittorrent's external-program setting empty
- UFW: allow SSH, `wg0`, the LAN, 80/443 and the WireGuard port; deny otherwise

None of these can be left to a human remembering. Each is either pinned in
configuration or asserted by `scripts/audit-auth.sh`, which is run against the
live stack and fails loudly. Four things are worth stating explicitly because
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
- **Cleanuparr ships the same trap under a different name.** Its setting is
  called "Disable Auth for Local Addresses", and its built-in trusted ranges
  include `172.16.0.0/12` — Docker's default address pool. Switching it on does
  not merely trust the LAN, it exempts every container on the compose bridge.
  Unlike the *arrs there is no environment variable to pin it, so this one is
  asserted at runtime only: `audit-auth.sh` reads `/api/auth/status` and fails
  on `authBypassActive` (decisions.md D30).

---

## 6. Configuration Sequence

Order matters; each step depends on the previous.

1. **qBittorrent.** Set credentials. Create categories `movies`, `tv`, `anime`,
   `music` with save paths under `/data/torrents/`. Enable preallocation. Set
   incomplete downloads to a subfolder within the same path (not a different
   filesystem).
2. **Prowlarr.** Add indexers. Include anime-specific ones (see §8).
3. **Prowlarr -> apps.** Add Sonarr, Radarr and Lidarr under Settings > Apps.
   Indexers sync automatically from this point on.
4. **Sonarr, Radarr and Lidarr -> qBittorrent.** Add as download client, matching
   the category names from step 1.
5. **Root folders.** Sonarr: `/data/media/tv` and `/data/media/anime`. Radarr:
   `/data/media/movies`. Lidarr: `/data/media/music` — note that Lidarr requires
   a default quality *and* metadata profile on the root folder, which Sonarr and
   Radarr do not.
6. **Verify hardlinking.** In Sonarr/Radarr/Lidarr, ensure "Use Hardlinks instead
   of Copy" is enabled. Test with one import and confirm via `ls -li` that the
   inode is shared and disk usage did not double. **Do not skip this check.**
7. **Bazarr.** Connect to Sonarr and Radarr, configure subtitle providers and
   languages. It has nothing to do with Lidarr.
8. **Cleanuparr.** Create the admin account before anyone else can — it has a
   first-run setup flow and no way to pin credentials ahead of time. Leave
   "Disable Auth for Local Addresses" off (§5.3). Add qBittorrent and the four
   *arrs. Leave the destructive cleaners disabled until you have watched it run
   once: it has write access to `/data` and the library is not backed up.
9. **Jellyfin.** Create libraries pointing at `/data/media/movies`,
   `/data/media/tv`, `/data/media/anime` and `/data/media/music`. Configure
   hardware acceleration.
10. **Infuse.** Add Jellyfin as a source. This preserves watch state, resume
    position, and library sync across devices, which a plain SMB share does not.

Steps 3 to 6 are done for you by `scripts/provision.sh`; the rest are manual.

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
5. Set `QBIT_HOST=gluetun` in `.env` and re-run `provision.sh`, so the *arrs
   follow qBittorrent to its new network identity
6. Change Cleanuparr's download client to `gluetun:8080` **by hand**. It stores
   the host in its own database and reads nothing from `.env`, so step 5 does
   not reach it and nothing will report that it has gone deaf (D30)

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
