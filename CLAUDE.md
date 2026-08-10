# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

Infrastructure-as-config for a single-box home media server: Jellyfin + the *arr
stack + qBittorrent, orchestrated by one `docker-compose.yml`, reached over a
self-hosted WireGuard tunnel, played back on Apple TV via Infuse.

The authoritative requirements live in **[`docs/spec.md`](docs/spec.md)**. If
anything here disagrees with the spec, the spec wins — fix this file.

This repo holds **configuration and scripts only**. No media, no container
state, no secrets.

## One machine

There is a single target box and everything here is written for it. There is no
dev stack, no compose override and no second Caddyfile — a macOS split existed
until the box was built and was removed with it.

| | Target box |
|---|---|
| OS | Debian 13 (Trixie), minimal server |
| Docker | docker-ce from Docker's official repo |
| CPU | Intel i7-8700K, Quick Sync iGPU |
| Media disk | 2 TB ext4 at `/mnt/disk1`, bind-mounted to `/data` — temporary, 10 TB planned |
| Access | public 80/443 for three names; WireGuard (`wg-easy`) for admin |

The scripts assume Debian: bash 5, GNU coreutils, `systemd`, `ufw`, and a Docker
daemon. `setup.sh` refuses to run anywhere else, and `validate.sh` needs GNU
`stat` and a working `docker`, so neither is portable to a macOS workstation.
Run them on the box.

Some properties can only be established there at all — hardware transcoding,
hardlinking across the real filesystem, SMART, the firewall rules. Never claim
one of those has been verified from a file; the checklist for them is
[`docs/verification.md`](docs/verification.md).

## Invariants

Each of these fails **silently** — the stack keeps running and appears healthy
while quietly doing the wrong thing. Treat a change that touches one of them as
requiring explicit justification.

1. **Identical volume paths.** Every container that touches media mounts
   `- /data:/data`. Not `/data/media:/media`, not `/data/tv:/tv`. Mismatched
   paths between the download client and the *arr apps are the single most
   common cause of "why won't it import", and of hardlinking degrading to a copy.
2. **One filesystem for `torrents/`, `usenet/` and `media/`.** Hardlinks cannot
   cross filesystems. If they are split, Sonarr and Radarr fall back to
   copying: double disk usage, slow imports, and seeding breaks. Nothing warns
   you. `scripts/test-hardlinks.sh` checks both download trees; `SRC_DIR` and
   `DST_DIR` override the pair it tests.
3. **`PUID=1001` / `PGID=1001`** everywhere, matching the `media` user that owns
   `/mnt/disk1/data`. Jellyfin additionally needs the host's `render` GID via
   `group_add` for `/dev/dri` access. The number is 1001 because Debian already
   gave 1000 to `nick`; the compose fallbacks still read `${PUID:-1000}`, which
   is the usual case and not this box's — `.env` is what supplies the real value
   (decisions.md D32).
4. **Nothing is reachable from the internet except the WireGuard port
   (decisions.md D33).** The stack is VPN-only. Three names are *served* — the
   landing page, Jellyfin and Seerr, at `{$PUBLIC_DOMAIN}` — but all three
   resolve to the box's LAN address, so reaching them from outside the house
   means bringing up the tunnel first. `PUBLIC_HTTP` in `.env` is the switch;
   at `false`, `setup.sh` opens no HTTP port and actively closes 80/443 if a
   previous run opened them.

   Certificates therefore come from **DNS-01**, not HTTP-01 — there is no
   inbound path for a challenge. That needs the Cloudflare provider module
   compiled in, which is why `caddy/Dockerfile` exists and Caddy is the one
   built image in the stack.

   The other eight apps are kept out of `sites.caddy` entirely. Since D34 they
   do have names, in `caddy/admin.caddy`, where every block imports the
   `admin_only` guard that 403s any client outside RFC1918 — so "there is no
   route" became "the route refuses", one mechanism where there were three.
   `validate.sh` fails if a block in that file omits the guard, and still fails
   if one of those names appears in `sites.caddy` at all. **That split stays
   even though nothing is public** — it is what keeps the model true if
   `PUBLIC_HTTP` is ever flipped back.

   qBittorrent's "run external program on completion" and SABnzbd's
   post-processing scripts are both arbitrary command execution by design — a
   session on either is a shell on the box. Cleanuparr holds credentials for
   both plus every *arr API key, so it reaches the same place one step removed.
   That is why the exclusion is mechanical (decisions.md D25, D30, spec §5.3).

   The landing page renders LAN addresses for the two *public* tiles when the
   client is local (decisions.md D31). That changes which URL a household
   browser navigates to; it changes nothing about what is routed or resolvable.

   The router forwards **UDP `WG_PORT`** and nothing else, and that does not
   weaken the above: a WireGuard port does not answer an unauthenticated probe
   at all, so it adds no reachable surface. `WG_UI_PORT` is never forwarded.

   Admin access is WireGuard plus `<lan-ip>:<port>`, with nothing proxying it.
   Service ports publish on the LAN via `BIND_ADDR`, which is intended and is
   what both the tunnel path and Infuse rely on. Note that plain UFW does not
   filter Docker-published ports at all — the `DOCKER-USER` rules are what make
   that true (decisions.md D1, D19, D26).

   **`DOCKER-USER` is not a boundary control alone.** It is jumped from the top
   of `FORWARD`, so it filters container **egress** and container-to-container
   traffic as well as inbound. A rule set that only enumerates who may come in
   drops everything the containers try to reach — DNS first, which takes the
   whole stack with it and stops Caddy ever reaching Let's Encrypt. The two
   `br+`/`docker0` RETURNs exist for that and are not optional (decisions.md
   D28). Reason about any change to that chain in both directions.

5. **Every app enforces authentication, and it is asserted, not assumed.** The
   *arr auth method and scope are pinned as environment variables so they are
   re-applied on every container start; credentials come from `provision.sh`.
   `scripts/audit-auth.sh` checks all ten apps against the running stack.
   Never set `AuthenticationRequired` to `DisabledForLocalAddresses`: Caddy
   reaches the backends over the compose bridge, so that exemption applies to
   every proxied request and leaves the admin UIs open (decisions.md D18).

   **Two apps are exceptions, and both are real ones.**

   *wg-easy:* v15 removed environment configuration, so `INIT_*` applies on
   *first start only* and the credentials then live in its database — asserted
   once, assumed thereafter. Never add `PASSWORD` or `PASSWORD_HASH` to fix
   that: those are v14 variables and v15 refuses to start when it sees one.
   `audit-auth.sh` is the compensating control, and the check that matters most
   is that the setup wizard is closed (decisions.md D26).

   *Cleanuparr:* worse, because it has no `INIT_*` equivalent at all. Both its
   credentials and its API key are generated into its own database on first
   start, so a wiped `/config` comes back with an open setup wizard and the
   first visitor becomes the administrator. `audit-auth.sh` asserts
   `setupCompleted` via its anonymous `/api/auth/status` endpoint. It also ships
   D18's trap under the name **"Disable Auth for Local Addresses"**, whose
   built-in trusted ranges include `172.16.0.0/12` — Docker's default pool — so
   enabling it exempts the whole compose bridge, not just the LAN. It is off by
   default; `audit-auth.sh` fails on `authBypassActive` (decisions.md D30).
6. **Gluetun stays commented out** until a VPN provider with working port
   forwarding is chosen (§7). Do not uncomment it speculatively.

   Two unrelated things in this repo are called "VPN". **Gluetun** is an
   *outbound* client that would carry qBittorrent's traffic and is deferred.
   **wg-easy** is the *inbound* remote-access server and is expected to be
   running. wg-easy is not a violation of this invariant.

7. **The landing page makes zero external requests.** Icons are inline SVG, the
   type is a system stack. A CDN link or a webfont renders perfectly for a
   client with internet and breaks for one without — a remote-access client is
   not guaranteed a route out — so the failure surfaces in front of the
   household. `validate.sh` asserts it (decisions.md D17, D24).

## Repo layout

```
CLAUDE.md                 this file
README.md                 operator-facing: build, configure, migrate
.env.example              template; the real .env is gitignored
docker-compose.yml        the stack (deliverable §9.1)
setup.sh                  host provisioning for Debian (deliverable §9.4)
caddy/
  Dockerfile              Caddy + the Cloudflare DNS module, for DNS-01
  Caddyfile               certificate issuance only; imports the two route files
  sites.caddy             the three public-capable routes, plus the `common` and
                          `private_only` snippets
  admin.caddy             the eight admin routes, each behind `admin_only` (D34)
  site/                   the landing page, served by Caddy at the bare domain
                          — no framework, no build step, no external requests
    index.html            Watch / Request tiles, collapsed admin disclosure,
                          and the inline SVG sprite of the ten service marks
    style.css             design tokens; dark-first with a light override
    app.js                link building, reachability probes, pointer FX
config/
  recyclarr/recyclarr.yml quality profile templates (tracked, not ignored)
scripts/
  provision.sh            wire the stack over the apps' REST APIs (idempotent)
  validate.sh             static checks; run before every commit
  audit-auth.sh           runtime checks; asserts every app enforces auth
  backup-config.sh        back up ${CONFIG_ROOT} to the media disk, with retention
  init-tree.sh            create the §3.1 /data tree in a running stack
  test-hardlinks.sh       prove the hardlink invariant
docs/
  spec.md                 source of truth — the build specification
  decisions.md            implementation decisions + open questions
  verification.md         the acceptance checklist, run on the target
  review-2026-08.md       security and architecture review + what it changed
```

## Conventions

- **Compose:** no top-level `version:` key — it is obsolete. **One file.**
  `docker-compose.yml` is the whole stack and `docker compose up -d` needs no
  flags. Do not reintroduce an override file; if something needs to vary, it
  varies through `.env`.
- **Images:** `lscr.io/linuxserver/*` for the app stack (they provide the
  `PUID`/`PGID`/`TZ` contract this design depends on). Do not substitute other
  maintainers' images. **Caddy is the one exception and is built, not pulled**
  — `caddy/Dockerfile` compiles the Cloudflare DNS module into upstream's own
  builder image, which is Caddy's documented way to add a module and not a
  third party's rebuild. It is the only `build:` in the stack; keep it that way.
- **Everything host-specific comes from `.env`** — UID/GID, timezone, paths,
  render GID, LAN subnet, remote-access settings. No host-specific value is
  hardcoded in `docker-compose.yml`.
- **`setup.sh` must be idempotent** and safe to re-run. Guard every mutation
  (user creation, fstab lines, UFW rules) with an existence check. It edits
  `/etc/fstab`, so it must never blindly append a duplicate.
- **Shell:** `#!/usr/bin/env bash`, `set -euo pipefail`, quoted expansions.
- **Comments explain *why*.** The tricky parts of this build (the `/data` bind
  mount indirection, `-m 0` on mkfs, `epmfs` on mergerfs) are non-obvious and
  each has a reason recorded in the spec — reference it rather than restating it.

## Secrets

Nothing sensitive gets committed. `.env`, API keys, the wg-easy admin password,
WireGuard peer keys, and the real remote-access hostname all stay out of git —
`.gitignore` covers them. Peer keys never enter the repo at all: wg-easy keeps
them in `${CONFIG_ROOT}/wg-easy`, which is also why that directory is part of
the backup set and must not be shared. **`${CONFIG_ROOT}/cleanuparr` is the same
class** — Cleanuparr is configured by hand rather than by `provision.sh`, so its
database ends up holding the qBittorrent password and every *arr API key.
Both directories are in the backup archive, which is therefore as sensitive as
`.env`. The *arr API keys are pinned in `.env` rather than read out of each UI
(decisions.md D12); treat them as passwords, since a valid key is full control
of that app. Placeholders in tracked files use the spec's own notation:
`media.example.com`, `<lan-ip>`, `<render-gid>`, `<disk1-uuid>`.

If you need a real value to make progress, ask for it — don't invent one that
looks plausible and gets copy-pasted into production.

## Validating changes

One command, needs nothing running:

```bash
./scripts/validate.sh
```

It parses the compose config, asserts mechanically that exactly the seven media
services mount `/data` and that they all resolve to **one** source (invariant 1
and 2, which no runtime error would catch), confirms Gluetun is still commented
out, checks the exposure invariants (every published port names an interface,
Caddy is not on a wildcard, the *arr auth env vars are present, `.env` is 0600),
validates the Caddyfile, checks the landing page (invariant 7 — no external
`src`/`href`, no CSS `url()` that is not a `data:` URI, no hardcoded host in an
`href` or a `data-lan`, every `{{env}}` the page reads is set on the caddy
service, and the tiles' `data-sub` set still equals the `sites.caddy` route
set), and shellchecks every script. Run it before every commit.

Not everything it prints is a pass or a fail. A yellow `–` is a warning it
cannot resolve on its own — a `WG_SUBNET` outside the ranges `private_only`
matches, or a `BIND_ADDR` that is neither `ADMIN_HOST` nor a wildcard, which
means every unproxied link on the landing page points at an address nothing is
listening on. That second one is expected while `BIND_ADDR` is still at
loopback and is a real fault afterwards, so it warns rather than failing.

It needs GNU `stat`, bash 5 and a Docker daemon, so it runs on the box rather
than on a workstation. `shellcheck` and `caddy` are not installed as packages;
`validate.sh` shells out to `koalaman/shellcheck`, and builds `caddy/Dockerfile`
to validate the Caddyfile against a binary that actually has the `acme_dns`
directive — stock `caddy:alpine` reports a syntax error on a correct file.

With the stack up, two more:

```bash
./scripts/audit-auth.sh        # invariant 5 — every app enforces auth
./scripts/test-hardlinks.sh    # invariant 2 — one inode, two names
```

`test-hardlinks.sh` writes a file as qBittorrent and links it as Sonarr, then
compares device, inode and link count.

`setup.sh` mutates the host, so rehearse it in a throwaway container rather than
on the live box:

```bash
docker run --rm -v "$PWD:/repo:ro" debian:trixie \
  bash -c 'cd /repo && bash setup.sh --dry-run --skip-packages --disk /dev/sdX'
```

Note that `--dry-run` skips the steps that append to files (`DOCKER-USER` rules,
`sysctl.d`, `modules-load.d`), so it does not exercise everything. To reach
those, install `ufw` and `openssh-server` in the container, stub `systemctl`,
set `LAN_SUBNET`, and run without `--dry-run` — **twice**, since idempotency is
the property most likely to be wrong:

```bash
docker run --rm -v "$PWD:/repo:ro" debian:trixie bash -c '
  apt-get update -qq && apt-get install -y -qq ufw openssh-server >/dev/null
  printf "#!/bin/sh\nexit 0\n" > /usr/bin/systemctl && chmod +x /usr/bin/systemctl
  cd /repo && cp -r . /work && cd /work
  echo "LAN_SUBNET=192.168.1.0/24" >> .env
  bash setup.sh --skip-packages; bash setup.sh --skip-packages
  grep -c "BEGIN MEDIASERVER DOCKER-USER" /etc/ufw/after.rules'
```

That last `grep` must print `1`, not `2`.

## Current state

**Deployed and running on the Debian box since 9 August 2026.** Twelve services;
both hardlink runs — torrent and usenet — report one inode and two names, and
production Let's Encrypt certificates are issued over DNS-01 for every name.
`validate.sh` and `audit-auth.sh` print their own totals; read those rather than
a number written here, because every count in this file that was load-bearing
has gone stale at least once. The stack is provisioned end to end: root folders,
both download clients on every *arr, Prowlarr's app links and indexers,
Recyclarr's profiles, Seerr wired to Radarr and Sonarr, and a verified Eweka
connection.

**Two changes are staged and not yet on the box (D37, D38).** Jellyseerr is
migrated to seerr — abandoned image, patched RCE — and Lidarr is removed with
music leaving the scope again. The seerr container runs as UID 1000 where the
old one ran as root, so `${CONFIG_ROOT}/jellyseerr` needs `chown -R 1000:1000`
before it will start, and the in-place database migration is one-way: rehearse
it against a copy first (verification.md item 15). Two `.env` variables come out
on the box: `LIDARR_PORT` and `LIDARR_API_KEY`.

The first deployment found nine defects, all in `setup.sh`, `provision.sh` or
`audit-auth.sh`, and all of one shape: **the script reported success for
something that had not happened.** Worth knowing about as a class, because the
next one will look the same. `systemctl enable smartd` fails on Debian's aliased
unit and killed `setup.sh` before the firewall; Recyclarr publishes no `:latest`
tag so `compose pull` aborted; em dashes in the `DOCKER-USER` block made every
ufw re-run crash, because ufw writes its rules files as ASCII; `ufw --force
enable` does not re-read `after.rules` when already active; the 80/443 close
matched `ALLOW IN`, which only `ufw status verbose` prints; `provision.sh` set
qBittorrent's password but never its username; it reconciled download client
priority but not credentials, so a rotation left three apps stale; `audit-auth.sh`
probed wg-easy on loopback when it binds `WG_UI_BIND`; and its Cleanuparr bypass
check could never pass, because `jq`'s `//` substitutes on `false`.

Still true and still worth carrying: a security and architecture review in
August 2026 is written up in
[`docs/review-2026-08.md`](docs/review-2026-08.md), with what it changed and what
was accepted rather than fixed. Two findings are worth carrying in your head
because they invalidate reasonable-sounding assumptions:

- **UFW does not filter Docker-published ports.** Anything reasoning about "UFW
  denies inbound" is wrong unless the `DOCKER-USER` rules are in place (D19).
- **`config.xml` is not the *arrs' source of truth.** Environment configuration
  is applied at runtime without being written to disk, so the file disagrees
  with the running app. Ask the API (D18).

**Still not verified — do not report these as working.** Tracked in
[`docs/verification.md`](docs/verification.md), open questions in
[`docs/decisions.md`](docs/decisions.md).

- **Hardware transcoding is impossible on this board**, not merely untested. No
  display outputs means no IGD menu in the firmware, so Quick Sync cannot be
  enabled; an Arc A310 is the plan (D35). Items 1 and 2 are marked N/A, and
  item 2 checks the PCI vendor because `/dev/dri/renderD128` exists today, is
  passed into Jellyfin, and is the nouveau node.
- **Unattended boot after a power cut** (item 8) — needs the plug pulled. The
  boot ordering of Docker against ufw has never been exercised here, and
  `DOCKER-USER` is the whole of D19: check the chain is populated after a
  reboot, not just that the file is right.
- **smartd alert delivery** (item 6) — no `SMTP_HOST`, so nothing is sent.
- **Everything off-network.** Under D33 nothing is forwarded but `WG_PORT`, so
  there is no vantage point outside RFC1918 from which to reach Caddy. The
  `@public` branch of `private_only` and the `admin_only` 403 are asserted
  structurally — by `validate.sh` and by reading `caddy adapt` handler order —
  and cannot be observed. If `PUBLIC_HTTP` is ever set true, item 12 becomes
  testable and must be run *before* the forward is opened.
- **fail2ban's web jails**, and the `jellyfin` jail stays disabled until
  Jellyfin's Known Proxies is set to the compose bridge subnet.
- **Cleanuparr's deletion behaviour** (D30) — it has read-write `/data` and the
  library is not in the backup set. Enable one cleaner at a time.
- **Usenet end to end.** The Eweka connection is verified, but nothing has been
  imported through it yet.
