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
   cross filesystems. If they are split, Sonarr/Radarr fall back to copying:
   double disk usage, slow imports, and seeding breaks. Nothing warns you.
   `scripts/test-hardlinks.sh` checks both download trees.
3. **`PUID=1000` / `PGID=1000`** everywhere, matching the `media` user that owns
   `/mnt/disk1/data`. Jellyfin additionally needs the host's `render` GID via
   `group_add` for `/dev/dri` access.
4. **Exactly three HTTP services are public: the landing page, Jellyfin and
   Jellyseerr.** They are served by Caddy at `{$PUBLIC_DOMAIN}` with ports 80
   and 443 forwarded from the router. The other seven apps are excluded
   *structurally*, not carefully: they have **no route** in `caddy/sites.caddy`,
   **no public DNS record**, and the `DOCKER-USER` chain returns only 80/443
   from off-box. Any one of those alone would do; the point is that adding a
   route is not enough to expose one by accident, and `validate.sh` fails if any
   of those names appears in the routes file at all.

   qBittorrent's "run external program on completion" and SABnzbd's
   post-processing scripts are both arbitrary command execution by design — a
   session on either is a shell on the box. That is why the exclusion is
   mechanical (decisions.md D25, spec §5.3).

   The router also forwards **UDP `WG_PORT`**, and that does not weaken the
   above: a WireGuard port does not answer an unauthenticated probe at all, so
   it adds no reachable surface. `WG_UI_PORT` is never forwarded.

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
   `scripts/audit-auth.sh` checks all nine apps against the running stack.
   Never set `AuthenticationRequired` to `DisabledForLocalAddresses`: Caddy
   reaches the backends over the compose bridge, so that exemption applies to
   every proxied request and leaves the admin UIs open (decisions.md D18).

   **wg-easy is the exception, and it is a real one.** v15 removed environment
   configuration, so `INIT_*` applies on *first start only* and the credentials
   then live in its database — asserted once, assumed thereafter. Never add
   `PASSWORD` or `PASSWORD_HASH` to fix that: those are v14 variables and v15
   refuses to start when it sees one. `audit-auth.sh` is the compensating
   control, and the check that matters most is that the setup wizard is closed
   (decisions.md D26).
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
  Caddyfile               certificate issuance only; imports sites.caddy
  sites.caddy             the routes, plus the `common` and `private_only` snippets
  site/                   the landing page, served by Caddy at the bare domain
                          — no framework, no build step, no external requests
    index.html            Watch / Request tiles, collapsed admin disclosure,
                          and the inline SVG sprite of the eight service marks
    style.css             design tokens; dark-first with a light override
    app.js                host-derived links, reachability probes, pointer FX
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
  `PUID`/`PGID`/`TZ` contract this design depends on), `caddy:alpine` for the
  proxy. Do not substitute other maintainers' images.
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
the backup set and must not be shared. The *arr API keys are pinned in `.env` rather than read out of each UI
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

It parses the compose config, asserts mechanically that exactly the six media
services mount `/data` and that they all resolve to **one** source (invariant 1
and 2, which no runtime error would catch), confirms Gluetun is still commented
out, checks the exposure invariants (every published port names an interface,
Caddy is not on a wildcard, the *arr auth env vars are present, `.env` is 0600),
validates the Caddyfile, checks the landing page (invariant 7 — no external
`src`/`href`, no CSS `url()` that is not a `data:` URI, and the tiles' `data-sub`
set still equals the `sites.caddy` route set), and shellchecks every script. Run
it before every commit.

It needs GNU `stat`, bash 5 and a Docker daemon, so it runs on the box rather
than on a workstation. `shellcheck` and `caddy` are not installed as packages;
`validate.sh` shells out to `koalaman/shellcheck` and `caddy:alpine`.

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

All spec §9 deliverables are implemented. Before the Debian box existed, the
stack was exercised on a macOS workstation with a compose override: all ten
containers started and reached healthy, every web UI responded directly and
through Caddy, the hardlink test passed, and `audit-auth.sh` passed on all eight
apps. **That override is gone**, and none of those results were obtained on this
hardware — treat them as prior evidence that the design works, not as
verification of this box.

A security and architecture review in August 2026 is written up in
[`docs/review-2026-08.md`](docs/review-2026-08.md), with what it changed and what
was accepted rather than fixed. Two findings are worth carrying in your head
because they invalidate reasonable-sounding assumptions:

- **UFW does not filter Docker-published ports.** Anything reasoning about "UFW
  denies inbound" is wrong unless the `DOCKER-USER` rules are in place (D19).
- **`config.xml` is not the *arrs' source of truth.** Environment configuration
  is applied at runtime without being written to disk, so the file disagrees
  with the running app. Ask the API (D18).

Untested on this hardware — do not report these as working: hardware
transcoding, Let's Encrypt issuance, the router port forwards, the UFW and
`DOCKER-USER` rules (including the 80/443 returns), the fail2ban web jails,
unattended-upgrades, smartd delivery, and unattended boot. They are tracked in
[`docs/verification.md`](docs/verification.md); open questions are in
[`docs/decisions.md`](docs/decisions.md).
