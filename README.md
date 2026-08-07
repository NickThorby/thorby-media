# thorby-media

Docker configuration for a single-box home media server: Jellyfin plus the *arr
stack and qBittorrent, reached over Tailscale, played on Apple TV via Infuse.

Full requirements are in [`docs/spec.md`](docs/spec.md). This README is the
operator's guide: how to bring it up, configure it in the right order, and grow
it later.

> **Status: documentation phase.** `docker-compose.yml`, `.env.example`,
> `Caddyfile`, and `setup.sh` are not written yet. The configuration sequence
> and migration path below are complete and final; the deployment section is
> marked where it depends on those files.

---

## The design in one paragraph

An 8 TB ext4 disk is mounted at `/mnt/disk1` and bind-mounted to `/data`. Every
container mounts `/data:/data` — the same path on both sides, no exceptions —
so that downloads and the library sit on one filesystem and Sonarr/Radarr import
by hardlink instead of copying. Container config lives separately on the SSD
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

> Pending `setup.sh` and `docker-compose.yml`. The intended shape:
>
> 1. Clone this repo to `/opt/mediaserver`
> 2. `cp .env.example .env` and fill in `PUID`, `PGID`, `TZ`, `RENDER_GID`
>    (`getent group render`), `TAILSCALE_IP`, and the tailnet hostname
> 3. Review, then run `sudo ./setup.sh` — packages, the `media` user, the
>    directory tree, fstab entries, smartd, UFW
> 4. `docker compose up -d`
>
> `setup.sh` formats and mounts a disk and rewrites `/etc/fstab`. Read it before
> running it, and confirm the target disk is the one you think it is.

---

## Configuration sequence

Order matters — each step depends on the one before it. (Spec §6.)

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

Enable authentication, then add indexers. Include the anime-specific ones —
**Nyaa.si, AnimeTosho, SubsPlease**. General trackers carry very little anime;
without these Sonarr will simply find nothing.

### 3. Prowlarr → apps

Settings → Apps, add Sonarr and Radarr with their API keys. From this point
indexers sync automatically and are never configured in the *arr apps directly.

### 4. Sonarr and Radarr → qBittorrent

Add qBittorrent as a download client in each, with the category names from
step 1 (`tv` and `anime` in Sonarr, `movies` in Radarr).

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

### 9. Infuse

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
- The *arr UIs and qBittorrent are not built for hostile exposure and must never
  reach the internet
- Authentication is enabled in every app

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
| [`CLAUDE.md`](CLAUDE.md) | Working guidance for Claude Code |
| [`docs/spec.md`](docs/spec.md) | The build specification — source of truth |
| [`docs/decisions.md`](docs/decisions.md) | Implementation choices and open questions |
| [`docs/dev-testing.md`](docs/dev-testing.md) | What is testable on the Mac, what is not |
| [`docs/verification.md`](docs/verification.md) | Acceptance checklist, run on the server |
