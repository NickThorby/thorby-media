# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

Infrastructure-as-config for a single-box home media server: Jellyfin + the *arr
stack + qBittorrent, orchestrated by one `docker-compose.yml`, reached over
Tailscale, played back on Apple TV via Infuse.

The authoritative requirements live in **[`docs/spec.md`](docs/spec.md)**. If
anything here disagrees with the spec, the spec wins — fix this file.

This repo holds **configuration and scripts only**. No media, no container
state, no secrets.

## Two machines — read this before running anything

Development happens on a macOS workstation. The stack runs on a completely
different machine. These are never the same host.

| | Dev box (where you are now) | Target box |
|---|---|---|
| OS | macOS | Debian 13 (Trixie), minimal server |
| Docker | Docker Desktop | docker-ce from Docker's official repo |
| CPU | Apple Silicon / Intel Mac | Intel i7-8700K, Quick Sync iGPU |
| Media disk | none | 8 TB ext4 at `/mnt/disk1`, bind-mounted to `/data` |
| Access | local | Tailscale only |

**Do not, on the dev box:**

- Run `setup.sh`. It creates system users, writes `/etc/fstab`, configures
  `smartd`, and sets UFW rules. It is written for Debian and will either fail or
  do damage here.
- Assume `/dev/dri`, `/mnt/disk1`, `/data`, the `media` user, or the `render`
  group exist. None of them do.
- Claim hardware transcoding, hardlinking, SMART, or Tailscale binding has been
  verified. Those are target-box checks — see
  [`docs/verification.md`](docs/verification.md).

When something can only be checked on the target, say so plainly rather than
approximating it locally. See [`docs/dev-testing.md`](docs/dev-testing.md) for
what *is* testable here.

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
4. **Nothing is exposed to the public internet.** No router port forwarding, no
   public DNS record. Caddy — the remote-access path — binds only to the
   tailnet IP (`CADDY_BIND_ADDR`). Service ports do publish on the LAN via
   `BIND_ADDR`, which is intended: spec §5.1 wants direct LAN access and Infuse
   reaches Jellyfin that way. The boundary is the router, plus the `DOCKER-USER`
   rules `setup.sh` installs — **not** plain UFW, which does not filter
   Docker-published ports at all (decisions.md D1, D19). qBittorrent's "run
   external program on completion" and SABnzbd's post-processing scripts are
   both arbitrary command execution by design. Neither tolerates hostile
   exposure.

5. **Every app enforces authentication, and it is asserted, not assumed.** The
   *arr auth method and scope are pinned as environment variables so they are
   re-applied on every container start; credentials come from `provision.sh`.
   `scripts/audit-auth.sh` checks all eight apps against the running stack.
   Never set `AuthenticationRequired` to `DisabledForLocalAddresses`: Caddy
   reaches the backends over the compose bridge, so that exemption applies to
   every proxied request and leaves the admin UIs open (decisions.md D18).
6. **Gluetun stays commented out** until a VPN provider with working port
   forwarding is chosen (§7). Do not uncomment it speculatively.

## Repo layout

```
CLAUDE.md                 this file
README.md                 operator-facing: build, configure, migrate
.env.example              template; the real .env is gitignored
docker-compose.yml        the production stack (deliverable §9.1)
docker-compose.dev.yml    macOS-only override, layered via COMPOSE_FILE
setup.sh                  host provisioning for Debian (deliverable §9.4)
caddy/
  sites.caddy             the routes — shared by both environments
  Caddyfile               production: ts.net certs from tailscaled
  Caddyfile.dev           dev: internal CA via local_certs
  site/                   the landing page, served by Caddy at the bare domain
    index.html            Watch / Request tiles + collapsed admin disclosure
    style.css             no framework, no build step, no external requests
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
  dev-testing.md          what can and cannot be validated on macOS
  verification.md         the acceptance checklist, run on the target
  review-2026-08.md       security and architecture review + what it changed
```

## Conventions

- **Compose:** no top-level `version:` key — it is obsolete. Two files:
  `docker-compose.yml` is the production stack and the default, and
  `docker-compose.dev.yml` is layered on top only on macOS, via `COMPOSE_FILE`
  in `.env`. **Production is deliberately the default** — forgetting the
  override on Debian yields a correct stack, while forgetting it on the Mac
  fails loudly on the missing `/dev/dri`. Never invert that. New services go in
  the production file first; add a dev override only if macOS cannot run it.
- **Compose interpolates before it merges override files.** A `${VAR:?}` in the
  base file errors even when the dev override `!reset`s the field that used it —
  which is why `.env`'s Mac block still sets a dummy `RENDER_GID`.
- **Images:** `lscr.io/linuxserver/*` for the app stack (they provide the
  `PUID`/`PGID`/`TZ` contract this design depends on), `caddy:alpine` for the
  proxy. Do not substitute other maintainers' images.
- **Everything host-specific comes from `.env`** — UID/GID, timezone, paths,
  tailnet hostname, render GID. No values hardcoded in `docker-compose.yml` that
  differ between the dev and target boxes.
- **`setup.sh` must be idempotent** and safe to re-run. Guard every mutation
  (user creation, fstab lines, UFW rules) with an existence check. It edits
  `/etc/fstab`, so it must never blindly append a duplicate.
- **Shell:** `#!/usr/bin/env bash`, `set -euo pipefail`, quoted expansions.
- **Comments explain *why*.** The tricky parts of this build (the `/data` bind
  mount indirection, `-m 0` on mkfs, `epmfs` on mergerfs) are non-obvious and
  each has a reason recorded in the spec — reference it rather than restating it.

## Secrets

Nothing sensitive gets committed. `.env`, API keys, VPN credentials, the real
tailnet hostname, and the tailnet IP all stay out of git — `.gitignore` covers
them. The *arr API keys are pinned in `.env` rather than read out of each UI
(decisions.md D12); treat them as passwords, since a valid key is full control
of that app. Placeholders in tracked files use the spec's own notation:
`<host>.ts.net`, `<render-gid>`, `<disk1-uuid>`.

If you need a real value to make progress, ask for it — don't invent one that
looks plausible and gets copy-pasted into production.

## Validating changes here

One command, works on macOS and Debian, needs nothing running:

```bash
./scripts/validate.sh
```

It parses the compose config, asserts mechanically that exactly the six media
services mount `/data` and that they all resolve to **one** source (invariant 1
and 2, which no runtime error would catch), confirms Gluetun is still commented
out, checks the exposure invariants (every published port names an interface,
Caddy is not on a wildcard, the *arr auth env vars are present, `.env` is 0600),
validates both Caddyfiles, and shellchecks every script. Run it before every
commit.

With the stack up, two more:

```bash
./scripts/audit-auth.sh        # invariant 5 — every app enforces auth
./scripts/test-hardlinks.sh    # invariant 2 — one inode, two names
```

`test-hardlinks.sh` writes a file as qBittorrent and links it as Sonarr, then
compares device, inode and link count.

`setup.sh` cannot run here, but its logic can be exercised in a container:

```bash
docker run --rm -v "$PWD:/repo:ro" debian:trixie \
  bash -c 'cd /repo && bash setup.sh --dry-run --skip-packages --disk /dev/sdX'
```

Note that `--dry-run` skips the steps that append to files (`DOCKER-USER` rules),
so it does not exercise everything. To reach those, install `ufw` and
`openssh-server` in the container, stub `systemctl`, set `LAN_SUBNET`, and run
without `--dry-run` — and run it **twice**, since idempotency is the property
most likely to be wrong.

`shellcheck` and `yamllint` are not installed natively; `validate.sh` uses the
container forms.

## Current state

All spec §9 deliverables are implemented. Verified on the Mac: both compose
layerings render correctly, all ten containers start and reach healthy, every
web UI responds directly and through Caddy, the hardlink test passes on the
named volume, and `audit-auth.sh` passes on all eight apps.

A security and architecture review in August 2026 is written up in
[`docs/review-2026-08.md`](docs/review-2026-08.md), with what it changed and what
was accepted rather than fixed. Two findings are worth carrying in your head
because they invalidate reasonable-sounding assumptions:

- **UFW does not filter Docker-published ports.** Anything reasoning about "UFW
  denies inbound" is wrong unless the `DOCKER-USER` rules are in place (D19).
- **`config.xml` is not the *arrs' source of truth.** Environment configuration
  is applied at runtime without being written to disk, so the file disagrees
  with the running app. Ask the API (D18).

Untested until the Debian box exists — do not report these as working: hardware
transcoding, `*.ts.net` certificates, tailnet-only binding, the UFW and
`DOCKER-USER` rules, fail2ban, unattended-upgrades, smartd delivery, and
unattended boot. They are tracked in
[`docs/verification.md`](docs/verification.md); open questions are in
[`docs/decisions.md`](docs/decisions.md).
