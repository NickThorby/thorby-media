# thorby-media

Docker configuration for a single-box home media server: Jellyfin plus the *arr
stack and qBittorrent. The household reaches it on a public domain; the admin
apps are reachable only on the LAN or through a self-hosted WireGuard tunnel.
Played on Apple TV via Infuse.

Full requirements are in [`docs/spec.md`](docs/spec.md). This README is the
operator's guide: how to bring it up, configure it in the right order, and grow
it later.

> **Status.** All deliverables are implemented. Hardware transcoding, Let's
> Encrypt issuance, the router port forwards, UFW and `DOCKER-USER`, the
> fail2ban web jails, smartd delivery, and unattended boot are **untested on
> this hardware** — work through
> [`docs/verification.md`](docs/verification.md) during bring-up.

---

## The design in one paragraph

An ext4 disk is mounted at `/mnt/disk1` and bind-mounted to `/data` — currently
a temporary 2 TB, see spec §3.2. Every
container mounts `/data:/data` — the same path on both sides, no exceptions —
so that downloads and the library sit on one filesystem and Sonarr/Radarr import
by hardlink instead of copying. Both download protocols land under that root
(`torrents/` and `usenet/`, siblings of `media/`), so imports hardlink whichever
one a release came from. Container config lives separately on the SSD
under `/opt/mediaserver`. Caddy is the sole entry point from the internet and
serves exactly three names — the landing page, Jellyfin and Jellyseerr; the
seven admin apps have no route through it and are reached at `<lan-ip>:<port>`,
on the LAN or over WireGuard (spec §5.1, decisions.md D25, D26). The `/data` bind
mount is deliberate indirection: adding disks later means swapping it for a
mergerfs pool with no container changes and no library rescan.

---

## Prerequisites

The target machine, per spec §1–§2:

- Debian 13 (Trixie), minimal install, SSH enabled, static IP or DHCP reservation
- BIOS: integrated graphics enabled and set as primary adapter, onboard WiFi
  disabled, **Restore on AC Power Loss: Power On**, Fast Boot disabled
- Docker from Docker's official repository — not Debian's `docker.io`
- No VPN client to install: remote administration is the `wg-easy` container in
  this stack, which comes up with everything else
### DNS

Four A records, all pointing at the WAN address. Three are the names Caddy
issues certificates for; the fourth is what WireGuard peers dial.

| Record | Purpose | Set in |
|---|---|---|
| `media.thorby.tech` | landing page | `PUBLIC_DOMAIN` |
| `jellyfin.media.thorby.tech` | Jellyfin | derived from `PUBLIC_DOMAIN` |
| `seerr.media.thorby.tech` | Jellyseerr | derived from `PUBLIC_DOMAIN` |
| `vpn.thorby.tech` | the tunnel endpoint | `WG_HOST` |

`WG_HOST` is a name rather than a bare IP so a changed WAN address is one DNS
edit instead of reissuing every peer config. No record exists for any admin app,
and that absence is one of the three mechanisms keeping them off the internet
(spec §5.3) — do not add one.

**Check NAT hairpin.** Inside the house those names resolve to the WAN address,
so reaching them requires the router to loop a LAN client back through its own
public IP. Plenty of consumer routers do not, which produces the most confusing
possible failure: the domain works from a phone on cellular and times out from
the sofa. Test it before the household does. If it fails, add a **local DNS
override** on the router mapping the three `media.thorby.tech` names to
`CADDY_BIND_ADDR`. The Let's Encrypt certificate still validates — the name is
what it is issued for, not the address behind it.

### Router

Forward to the box's LAN address, and nothing else:

- TCP **80 and 443** — both; Let's Encrypt validates over 80 and will not
  issue a certificate without it
- UDP **`WG_PORT`** (51820) — the WireGuard tunnel

Never forward `WG_UI_PORT`; the wg-easy admin UI is LAN and tunnel only. If the
router's own admin interface is on 80 or 443, move it first.

Confirm the iGPU is alive before going further — `vainfo` must list H.264 and
HEVC entrypoints. If `/dev/dri` does not exist, it is disabled in BIOS.

---

## Deployment

Clone the repo onto the target, then:

```bash
cp .env.example .env
```

Most of it gets filled in as you go — `setup.sh` prints the host-specific
values. There is one compose file, so nothing here needs flags or an override.

**Two values have to go in before `setup.sh` runs at all:**

| Variable | Why it cannot wait |
|---|---|
| `LAN_SUBNET` | With it blank, `setup.sh` **skips the entire `DOCKER-USER` block** — the rules that actually keep the service ports off the internet — and falls back to allowing SSH from any source |
| `PUBLIC_DOMAIN` | Decides whether the firewall opens 80/443 and whether the fail2ban web jails are written |

Both are re-read on every run and the firewall block is rewritten when they
change, so correcting them later and re-running does work. Getting them right
the first time avoids a window where the box is up and the rules are not.

**1. Dry run first.** `setup.sh` rewrites `/etc/fstab`, creates a system user,
enables a firewall and can format a disk, so start by looking at exactly what
it intends to do:

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
| `CADDY_BIND_ADDR` | the LAN address the router forwards 80/443 to |
| `PUBLIC_DOMAIN` | your domain, e.g. `media.example.com` |
| `ACME_EMAIL` | contact address for Let's Encrypt expiry warnings |
| `ADMIN_HOST` | same LAN address — where the Manage links point |
| `WG_UI_BIND` | same LAN address again — what the wg-easy UI binds to |
| `LAN_SUBNET` | your home network, e.g. `192.168.1.0/24` |
| `WG_HOST` | the name peers dial, e.g. `vpn.example.com` |
| `WG_USER`, `WG_PASS` | wg-easy admin login. **First start only** — after that, change it in the UI |
| `SMTP_*`, `ALERT_EMAIL` | your mail relay — without these SMART alerts go nowhere |
| `USENET_USER`, `USENET_PASS` | your news server (Eweka etc). Blank = no Usenet downloads |
| `NZBGEEK_API_KEY`, `NZBPLANET_API_KEY` | Usenet indexer keys, from each site's profile page |

`BIND_ADDR` has no default and the stack will not start without it. That is
deliberate: a default of `0.0.0.0` fails open, so deleting the line would
silently publish everything on every interface.

`LAN_SUBNET` matters more than it looks, in two directions. Leave it blank and
the firewall blocks LAN clients from reaching Jellyfin, so Infuse on the Apple TV
will not find it unless the Apple TV is a WireGuard peer. But leave it blank and
`setup.sh` also **skips the `DOCKER-USER` rules entirely** — and those are what
actually keep the service ports off the internet, because plain UFW does not
filter Docker-published ports. Re-run `sudo ./setup.sh --skip-packages` after
editing to apply the firewall change.

**Prove the certificates against staging first.** Uncomment `CADDY_ACME_CA` in
`.env` so the first issuance goes to Let's Encrypt's staging directory. Two
things are likely to be wrong on a first attempt — port 80 not actually
forwarded, and a DNS record that has not propagated — and neither can be found
except by trying. Production allows five failed validations per hostname per
hour; staging does not care. Staging issues from an untrusted root, so a browser
certificate warning is the expected result and means everything else worked.
Comment the variable out again and `docker compose restart caddy` to switch to
real certificates.

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
`docker compose up -d`.

Re-run `sudo ./setup.sh --skip-packages` after this, even if you set
`LAN_SUBNET` before the first run. `wg0` does not exist until wg-easy has
started once, so the first pass could not add `ufw allow in on wg0` and said so
— until it does, the tunnel reaches container ports but not the box's own
listeners, which means no SSH and no wg-easy UI over WireGuard. The firewall
block is re-rendered on every run and rewritten if anything changed, so this is
safe to repeat.

The hardlink test is not optional. It writes a file as qBittorrent and links it
as Sonarr, then compares device, inode and link count — the same thing step 6 of
the configuration sequence asks you to check by hand, done automatically. Run it
a second time for the Usenet tree, as
[`docs/verification.md`](docs/verification.md) shows.

Then work through [`docs/verification.md`](docs/verification.md).

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

Then Dashboard → Networking, **Known proxies**: add the compose bridge subnet
(`docker network inspect mediaserver_default -f '{{(index .IPAM.Config 0).Subnet}}'`).
Jellyfin is reached from the internet only through Caddy, and until it is told
that Caddy is a proxy it records Caddy's container address as the client for
every remote session. Three things depend on getting this right: the session
list in the dashboard means something, Jellyfin's own failed-login throttling
counts individual clients rather than lumping the household into one, and the
fail2ban `jellyfin` jail becomes safe to enable — `setup.sh` ships it
**disabled** precisely because a jail fed proxy addresses bans the proxy and
takes everyone offline at once.

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

### 9a. The front door

**`https://<your-domain>` is the one URL to give the household.** It serves the
landing page — Watch and Request — and those two are the only things anyone else
needs. No VPN, no app, no port to remember.

The *Manage* section, with the seven admin tools, renders **only for clients on
the LAN or the tunnel**. That is a courtesy, not a control: those apps are
unreachable from the internet because they have no route in `caddy/sites.caddy`
and no DNS record, not because a link is hidden.

The page is three static files in `caddy/site/`, served by the Caddy that is
already proxying the stack. Because it is a bind mount read per request, editing
it is live on save — there is no build step and no `docker compose restart`.

### 9b. Admin access from outside

Open the wg-easy UI at `http://<lan-ip>:<WG_UI_PORT>` (51821 by default), add a
peer, scan the QR code with the WireGuard app. Then browse to
`http://<lan-ip>:8989` for Sonarr and so on — **the same address you would use at
home**. Nothing proxies them, so there is no hostname to remember and no
certificate involved; the transport is encrypted by WireGuard.

Two things about that UI are worth knowing before you rely on it. It speaks
plain HTTP (`INSECURE=true` — v15 otherwise serves a self-signed certificate,
and a warning on every visit teaches the wrong reflex; the tunnel or the LAN is
the encryption). And `WG_USER`/`WG_PASS` apply on the **first container start
only** — after that the credentials live in wg-easy's own database, so change
the password in the UI and treat `.env` as the bootstrap, not the record. If
`${CONFIG_ROOT}/wg-easy` is ever lost, the container comes back with an **open
setup wizard** and the next visitor becomes the VPN administrator;
`./scripts/audit-auth.sh` checks for exactly that and is the compensating
control (decisions.md D26).

Peers get a split tunnel: only the LAN and the WireGuard subnet route through
it, so ordinary browsing is unaffected and the tunnel is cheap enough to leave
on permanently. That is what makes one address work in both places, which the
landing page relies on — it templates a single `ADMIN_HOST` and cannot render a
different link per network (decisions.md D26).

This is why the admin apps do not need a public name, and why adding one would
be a mistake: qBittorrent and SABnzbd both run arbitrary commands by design.

### 10. Infuse

Add Jellyfin as a source (not an SMB share — the Jellyfin source is what
preserves watch state, resume position, and library sync across devices). For
playback away from home, use the public `jellyfin.<domain>` name — the Apple TV
needs no VPN client of its own.

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

- Only 80 and 443 are forwarded, and Caddy answers on them for three names
- The seven admin apps have no route, no public DNS record, and no path through
  `DOCKER-USER` — three independent reasons the internet cannot reach them
- UDP `WG_PORT` is forwarded too, and answers nothing without a valid key. The
  wg-easy admin UI on `WG_UI_PORT` is never forwarded
- Admin access is WireGuard plus `<lan-ip>:<port>`
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
- That chain filters **outbound** container traffic as well as inbound, because
  Docker jumps to it from the top of `FORWARD`. If you ever hand-edit it, keep
  the `br+`/`docker0` RETURN rules: without them containers cannot resolve DNS
  and the whole stack stops working while the firewall listing looks correct
  (decisions.md D28)

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

**Those backups live on the media disk**, which is the same physical drive as
the library and currently the only one in the box. It protects against a bad
upgrade or a botched config change, not against the drive failing — and the
archive is the only copy of the wg-easy peer keys and every *arr database. Copy
one off the box periodically until the second drive lands (§3.6, decisions.md
D22, D27).

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

**The landing page shows no status dots, or a grey one.** The dots are probed by
the browser, so they report what *your device* can reach, not what the box
thinks. On the two Watch/Request tiles: all of them missing means nothing was
reachable — usually the client has dropped off the VPN; a single grey one means
that hostname is not answering, so check it is still routed in
`caddy/sites.caddy`. The dots cannot see a stopped container, because Caddy
answers 502 and the probe cannot read the status (decisions.md D24) — they mean
"answering", not "healthy".

**The Manage chips never show dots, and that is expected.** The page is served
over HTTPS while those links are `http://<lan-ip>:<port>`, and a browser blocks
a fetch from an HTTPS page to an HTTP address as mixed content. There is no way
to instrument them without either putting the admin apps behind the proxy — the
one thing this design refuses — or issuing certificates for private addresses.
The links themselves work; only the indicator is absent.

---

## Repo contents

| Path | What |
|---|---|
| `docker-compose.yml` | The whole stack. Complete on its own; no flags, no override |
| `.env.example` | Every host-specific value |
| `setup.sh` | Debian host provisioning — idempotent, `--dry-run`, opt-in disk format |
| `caddy/Caddyfile` | Certificate issuance — Let's Encrypt over HTTP-01 |
| `caddy/sites.caddy` | The reverse-proxy routes and the snippets they import |
| `caddy/site/` | The landing page — Watch / Request, admin tools collapsed, live reachability dots |
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
| [`docs/verification.md`](docs/verification.md) | Acceptance checklist, run on the server |
| [`docs/review-2026-08.md`](docs/review-2026-08.md) | Security and architecture review, and what it changed |
