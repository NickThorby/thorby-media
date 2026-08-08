# thorby-media

Docker configuration for a single-box home media server: Jellyfin plus the *arr
stack and qBittorrent, reached over Tailscale, played on Apple TV via Infuse.

Full requirements are in [`docs/spec.md`](docs/spec.md). This README is the
operator's guide: how to bring it up, configure it in the right order, and grow
it later.

> **Status.** All deliverables are implemented and validated on a macOS dev box.
> Hardware transcoding, `*.ts.net` certificates, tailnet binding, UFW, smartd
> delivery, and unattended boot are **untested** — they need the Debian machine.
> See [`docs/verification.md`](docs/verification.md).

---

## The design in one paragraph

An 8 TB ext4 disk is mounted at `/mnt/disk1` and bind-mounted to `/data`. Every
container mounts `/data:/data` — the same path on both sides, no exceptions —
so that downloads and the library sit on one filesystem and Sonarr/Radarr import
by hardlink instead of copying. Both download protocols land under that root
(`torrents/` and `usenet/`, siblings of `media/`), so imports hardlink whichever
one a release came from. Container config lives separately on the SSD
under `/opt/mediaserver`. Caddy binds only to the Tailscale interface and is the
sole remote entry point; nothing is forwarded from the router. The `/data` bind
mount is deliberate indirection: adding disks later means swapping it for a
mergerfs pool with no container changes and no library rescan.

---

## Prerequisites

The target machine, per spec §1–§2:

- Debian 13 (Trixie), minimal install, SSH enabled, static IP or DHCP reservation
- BIOS: integrated graphics enabled and set as primary adapter, onboard WiFi
  disabled, **Restore on AC Power Loss: Power On**, Fast Boot disabled
- Docker from Docker's official repository — not Debian's `docker.io`
- Tailscale installed and joined to the tailnet (`tailscale up`); note the
  tailnet IP, Caddy binds to it
- HTTPS Certificates and MagicDNS enabled for the tailnet in the Tailscale admin
  console, or Caddy cannot issue certs for `*.ts.net`

Confirm the iGPU is alive before going further — `vainfo` must list H.264 and
HEVC entrypoints. If `/dev/dri` does not exist, it is disabled in BIOS.

---

## Deployment

Clone the repo onto the target, then:

```bash
cp .env.example .env
```

Leave the MAC DEV block at the bottom commented out — the production values are
the defaults, so a Debian box needs no override file and no flags.

**1. Dry run first.** `setup.sh` rewrites `/etc/fstab`, creates a system user,
enables a firewall and can format a disk. None of that can be rehearsed on the
dev machine, so start by looking at exactly what it intends to do:

```bash
sudo ./setup.sh --dry-run --disk /dev/sdX
```

Every mutation is printed and nothing is applied. Confirm `/dev/sdX` is the disk
you think it is (`lsblk -f`) before going further.

**2. Provision the host.** Add `--format-disk` only if the media disk is blank
and you want the script to make the filesystem. It refuses any device that
already carries a filesystem or partition table, so it will not destroy an
existing library — but check anyway.

```bash
sudo ./setup.sh --disk /dev/sdX [--format-disk]
```

This installs packages from Docker's official repository, creates the `media`
user, builds the directory tree, adds the fstab entries, configures msmtp and
smartd, sets UFW rules, and prints the values you need for the next step.

**3. Finish `.env`.** Paste in what the script reported:

| Variable | Where it comes from |
|---|---|
| `RENDER_GID` | `getent group render` |
| `BIND_ADDR` | `127.0.0.1` for now — widened in step 7, once the wizards are done |
| `CADDY_BIND_ADDR` | `tailscale ip -4` |
| `CADDY_DOMAIN` | the machine's fully qualified `<host>.ts.net` |
| `LAN_SUBNET` | your home network, e.g. `192.168.1.0/24` |
| `SMTP_*`, `ALERT_EMAIL` | your mail relay — without these SMART alerts go nowhere |
| `USENET_USER`, `USENET_PASS` | your news server (Eweka etc). Blank = no Usenet downloads |
| `NZBGEEK_API_KEY`, `NZBPLANET_API_KEY` | Usenet indexer keys, from each site's profile page |

`BIND_ADDR` has no default and the stack will not start without it. That is
deliberate: a default of `0.0.0.0` fails open, so deleting the line would
silently publish everything on every interface.

`LAN_SUBNET` matters more than it looks, in two directions. Leave it blank and
the firewall blocks LAN clients from reaching Jellyfin, so Infuse on the Apple TV
will not find it unless the Apple TV is on the tailnet. But leave it blank and
`setup.sh` also **skips the `DOCKER-USER` rules entirely** — and those are what
actually keep the service ports off the internet, because plain UFW does not
filter Docker-published ports. Re-run `sudo ./setup.sh --skip-packages` after
editing to apply the firewall change.

**4. Verify the iGPU** before starting anything:

```bash
vainfo | grep -Ei 'h264|hevc'
```

Both H.264 and HEVC must show decode and encode entrypoints. If `/dev/dri` is
missing entirely, integrated graphics is disabled in BIOS — revisit §1.1.

**5. Generate API keys and start the stack — on loopback first.**

Set `BIND_ADDR=127.0.0.1` in `.env` before this step. Jellyfin and Jellyseerr
both serve an open first-run wizard until someone completes it, and the first
visitor to reach one becomes its administrator. On a LAN that includes every
device on the network. Everything else in the stack now comes up already closed:
the *arr auth settings are pinned in `docker-compose.yml`, and `provision.sh`
sets the credentials for the *arrs, qBittorrent, SABnzbd and Bazarr.

```bash
./scripts/provision.sh --init-keys    # writes keys into .env, chmods it 0600
docker compose up -d
docker compose exec recyclarr recyclarr sync   # creates the quality profiles
./scripts/provision.sh                # wires everything together
```

The Recyclarr sync is not optional and has to come first: `provision.sh` links
Jellyseerr to Radarr and Sonarr by quality-profile *name*, and those profiles do
not exist until Recyclarr has run. Recyclarr's own schedule is `@daily`, so
without this the first provision run skips the Jellyseerr step.

**6. Finish the two wizards that cannot be automated,** over an SSH tunnel so
they are never exposed:

```bash
ssh -L 8096:localhost:8096 -L 5055:localhost:5055 <user>@<host>
```

Jellyfin first (create the admin account and the three libraries), then
Jellyseerr — see steps 8 and 9 of the configuration sequence below. Re-run
`./scripts/provision.sh` afterwards to wire Jellyseerr up.

**7. Check it, then open it to the LAN.**

```bash
./scripts/validate.sh
./scripts/audit-auth.sh
./scripts/test-hardlinks.sh
```

`audit-auth.sh` must pass before you widen `BIND_ADDR`. It asks each running app
what it actually enforces, rather than trusting that a wizard was completed.

Only then set `BIND_ADDR` to `0.0.0.0` (or the LAN IP) and
`docker compose up -d`. Make sure `LAN_SUBNET` is set in `.env` and re-run
`sudo ./setup.sh` — the firewall rules that keep those ports off the internet
depend on it.

The hardlink test is not optional. It writes a file as qBittorrent and links it
as Sonarr, then compares device, inode and link count — the same thing step 6 of
the configuration sequence asks you to check by hand, done automatically. Run it
a second time for the Usenet tree, as
[`docs/verification.md`](docs/verification.md) shows.

Then work through [`docs/verification.md`](docs/verification.md).

### Developing on another machine

The macOS dev workflow is in [`docs/dev-testing.md`](docs/dev-testing.md). In
short: uncomment the MAC DEV block in `.env` and `docker compose up -d`. That
layers `docker-compose.dev.yml`, which strips the `/dev/dri` passthrough and
puts `/data` on a named volume so hardlinks and permissions behave as they do on
ext4.

---

## Configuration sequence

Order matters — each step depends on the one before it. (Spec §6.)

> **Steps 1–6 are automated by `./scripts/provision.sh`.** They're documented
> here anyway, because you need to know what it did and where to change it. What
> the script leaves for you is steps 2 (indexers), 7 (Bazarr) and 8–9
> (Jellyfin and Infuse).

### 1. qBittorrent — `:8080`

The temporary admin password is printed to the container log on first start:
`docker compose logs qbittorrent`.

- Change the credentials immediately (Settings → Web UI)
- Leave **Run external program on torrent completion** empty — it is arbitrary
  command execution
- Create categories `movies`, `tv`, and `anime`, with save paths under
  `/data/torrents/` respectively
- Enable preallocation
- Put incomplete downloads in a subfolder of the *same* path — never a different
  filesystem, or hardlinking breaks

### 2. Prowlarr — `:9696`

`provision.sh` already added the public torrent indexers from `TORRENT_INDEXERS`
— **Nyaa.si, SubsPlease, AnimeTosho, Tokyo Toshokan** — and the Usenet ones if
their keys were in `.env`. They sync through to Sonarr and Radarr automatically.

The anime ones are not optional: general trackers carry very little anime and
Usenet covers it poorly, so without them Sonarr finds nothing for an anime
series.

Add any private trackers by hand here — they need per-site credentials. Never
add indexers directly in Sonarr or Radarr; Prowlarr owns them.

### 3. Prowlarr → apps

Settings → Apps, add Sonarr and Radarr with their API keys. From this point
indexers sync automatically and are never configured in the *arr apps directly.

### 4. Sonarr and Radarr → download clients

Add **both** clients in each app, with the category names from step 1 (`tv` and
`anime` in Sonarr, `movies` in Radarr):

- **SABnzbd** at priority **1** — Usenet is preferred where both have a release
- **qBittorrent** at priority **2**

Priority is lowest-wins. They are not redundant: Usenet is faster, has better
retention and carries no seeding obligation, but covers anime poorly, so in
practice Usenet carries TV and film while torrents carry anime.

`provision.sh` does all of this already; this section is what it is doing.

### 5. Root folders

- Sonarr: `/data/media/tv` **and** `/data/media/anime`
- Radarr: `/data/media/movies`

### 6. Verify hardlinking — do not skip

In each app, Media Management → **Use Hardlinks instead of Copy** must be on.
Then run one real import and check:

```bash
ls -li /data/torrents/movies/<release>/<file>.mkv \
       /data/media/movies/<Title>/<file>.mkv
```

The inode numbers must match. If they differ, it copied — stop and fix it before
importing anything else. Full procedure in
[`docs/verification.md`](docs/verification.md).

### 7. Bazarr — `:6767`

Connect to Sonarr and Radarr, then configure subtitle providers and languages.

### 8. Jellyfin — `:8096`

Create three libraries: `/data/media/movies`, `/data/media/tv`, and
`/data/media/anime` as its own library. Then Dashboard → Playback:

- Hardware acceleration: **VAAPI**
- Device: `/dev/dri/renderD128`
- Enable hardware decoding for H.264, HEVC, and VP9, and enable hardware
  encoding

With Infuse as the primary client this rarely fires — Infuse direct-plays almost
everything. It matters for browser and remote playback.

### 9. Jellyseerr — `:5055`

The front door for everyone who is not you. **Do step 8 first** — the wizard asks
you to select Jellyfin libraries and offers nothing if none exist, which looks
like a broken Continue button.

Run the wizard once at `http://localhost:5055/setup`:

- Sign in with your **Jellyfin admin account**
- For the server address, enter the hostname **`jellyfin`** and port **8096** —
  not `localhost` (that is Jellyseerr itself) and not the full URL (some fields
  reject it with `INVALID_URL`). Leave **URL Base blank**; it is only for apps
  served under a subpath.
- Select the three libraries
- **Stop there** — skip the Radarr and Sonarr steps

Then `./scripts/provision.sh` connects Radarr and Sonarr with the right root
folders and quality profiles, including a separate anime profile and directory so
anime requests land in `/data/media/anime`.

From then on nobody else needs Sonarr or Radarr at all: they search, click
Request, and it appears.

### 10. Infuse

Add Jellyfin as a source (not an SMB share — the Jellyfin source is what
preserves watch state, resume position, and library sync across devices). For
playback away from home, install Tailscale on the Apple TV.

### Naming

Use the Trash Guides naming schemes in Sonarr and Radarr. Jellyfin matches them
reliably, and they carry the quality and edition information Infuse surfaces.

---

## Anime

Anime is kept apart from the main TV library on purpose — TVDB season splits
frequently disagree with how releases are numbered, and isolating it stops that
inconsistency leaking into the TV library.

- Set **Series Type: Anime** in Sonarr for absolute episode numbering, which is
  how nearly all anime releases are named
- Keep `/data/media/anime` as a separate root folder and a separate Jellyfin
  library
- Use a separate quality profile with *Anime Release Group* as a preferred term
- Decide dual-audio versus subtitle-only up front — it drives release-group
  preferences heavily
- [Recyclarr](https://recyclarr.dev) maintains anime quality profiles encoding
  community release-group rankings; strongly preferred over hand-tuning
- Anime films go through Radarr with no special handling

---

## Adding a second drive (mergerfs migration)

The `/data` bind mount exists so this is cheap. Container paths never change, so
there is no library rescan and no broken hardlinks. (Spec §3.6.)

1. Mount the new drive at `/mnt/disk2` — same ext4 (`mkfs.ext4 -m 0`), same
   `defaults,noatime`, same `media:media` ownership and `775` permissions
2. `apt install mergerfs`
3. Replace the `/data` bind mount in `/etc/fstab` with a mergerfs pool over
   `/mnt/disk*`
4. Set the create policy to **`epmfs`** (existing path, most free space). This
   is the part that matters: it keeps a given title's download and its library
   file on the same physical disk, so hardlinks survive. Any other policy will
   eventually split a pair across drives and silently degrade to copying
5. Restart the stack

SnapRAID can be layered on later with a dedicated parity drive, sized at or
above the largest data drive.

**Neither mergerfs nor SnapRAID is a backup.** Irreplaceable data — photos, home
video, documents — must not live only on this machine.

---

## Operating it

**Updates** are deliberate, not automatic:

```bash
docker compose pull && docker compose up -d
```

Back up `/opt/mediaserver` first — that is where every app's database and
settings live. The media disk holds no configuration.

**Drive health** is the single point of failure in a one-disk build. `smartd`
runs a short self-test daily and a long one weekly, and alerts on attribute
failure or reallocated-sector growth. Confirm alerts actually deliver — an
alerting path that has never been tested is not an alerting path.

**Security posture**, restated because it is easy to erode:

- Nothing is forwarded from the router; the public IP listens on nothing
- Remote access is Tailscale, only
- The *arr UIs, qBittorrent and SABnzbd are not built for hostile exposure and
  must never reach the internet. qBittorrent's external-program setting and
  SABnzbd's post-processing scripts are both arbitrary command execution
- Authentication is enforced in every app — and asserted, not assumed. Run
  `./scripts/audit-auth.sh` after any change to a UI setting, and never set the
  *arrs to "disabled for local addresses": Caddy reaches them over the compose
  bridge, so that exemption covers every proxied request
- **UFW alone does not protect the service ports.** Docker publishes bypass its
  INPUT chain entirely. The `DOCKER-USER` rules `setup.sh` installs are what
  actually enforce this, and they need `LAN_SUBNET` set in `.env`

Back up before updating — `docker compose pull` on `:latest` tags can land a
breaking major version:

```bash
./scripts/backup-config.sh
docker compose pull && docker compose up -d
```

A daily backup timer is installed by `setup.sh`; `./scripts/backup-config.sh
--list` shows what is there. Restore is tested in
[`docs/verification.md`](docs/verification.md) item 10 — an untested backup is
not a backup.

---

## Troubleshooting

**"It downloaded but won't import."** Almost always the volume paths. Every
media-touching container must mount `/data:/data` — identical on both sides. If
qBittorrent reports a file at `/downloads/x.mkv` and Sonarr is looking under
`/data/torrents/`, they are describing the same file by different names and the
import fails. Check `docker compose config` and compare.

**Imports are slow and disk usage doubles.** Hardlinking silently fell back to
copying. Either the setting is off, or `torrents/` and `media/` are not on one
filesystem — `df /data/torrents /data/media` should show the same device.

**Transcoding pins the CPU.** `/dev/dri` is not reaching the container, or
`RENDER_GID` does not match the host's `render` group. Check
`docker compose exec jellyfin ls -l /dev/dri`, and watch `intel_gpu_top` during
playback.

**Sonarr finds nothing for anime.** Anime indexers are missing, or Series Type
is not set to Anime.

---

## Repo contents

| Path | What |
|---|---|
| `docker-compose.yml` | The production stack. Complete on its own; no flags needed on Debian |
| `docker-compose.dev.yml` | macOS-only override, layered via `COMPOSE_FILE` in `.env` |
| `.env.example` | Every host-specific value, with a commented Mac block |
| `setup.sh` | Debian host provisioning — idempotent, `--dry-run`, opt-in disk format |
| `caddy/sites.caddy` | The reverse-proxy routes, shared by both environments |
| `caddy/Caddyfile` | Production: `*.ts.net` certs from tailscaled |
| `caddy/Caddyfile.dev` | Dev: internal CA |
| `caddy/site/` | The landing page — Watch / Request, admin tools collapsed |
| `config/recyclarr/recyclarr.yml` | Quality profile templates, incl. anime |
| `scripts/provision.sh` | Wire the stack together over the apps' APIs — idempotent |
| `scripts/validate.sh` | Static checks — run before every commit |
| `scripts/audit-auth.sh` | Runtime checks — assert every app enforces authentication |
| `scripts/backup-config.sh` | Back up `${CONFIG_ROOT}` to the media disk, with retention |
| `scripts/init-tree.sh` | Create the §3.1 `/data` tree in a running stack |
| `scripts/test-hardlinks.sh` | Prove the hardlink invariant |
| [`CLAUDE.md`](CLAUDE.md) | Working guidance for Claude Code |
| [`docs/spec.md`](docs/spec.md) | The build specification — source of truth |
| [`docs/decisions.md`](docs/decisions.md) | Implementation choices and open questions |
| [`docs/dev-testing.md`](docs/dev-testing.md) | What is testable on the Mac, what is not |
| [`docs/verification.md`](docs/verification.md) | Acceptance checklist, run on the server |
| [`docs/review-2026-08.md`](docs/review-2026-08.md) | Security and architecture review, and what it changed |
