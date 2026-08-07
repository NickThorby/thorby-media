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
2. **One filesystem for `torrents/` and `media/`.** Hardlinks cannot cross
   filesystems. If they are split, Sonarr/Radarr fall back to copying: double
   disk usage, slow imports, and seeding breaks. Nothing warns you.
3. **`PUID=1000` / `PGID=1000`** everywhere, matching the `media` user that owns
   `/mnt/disk1/data`. Jellyfin additionally needs the host's `render` GID via
   `group_add` for `/dev/dri` access.
4. **Nothing is exposed to the public internet.** No router port forwarding, no
   public DNS record. Caddy — the remote-access path — binds only to the
   tailnet IP (`CADDY_BIND_ADDR`). Service ports do publish on the LAN via
   `BIND_ADDR`, which is intended: spec §5.1 wants direct LAN access and Infuse
   reaches Jellyfin that way. The boundary is the router plus UFW, not the bind
   address (decisions.md D1). qBittorrent's "run external program on completion"
   is arbitrary command execution by design; the *arr apps authenticate with a
   key printed in their own UI. Neither tolerates hostile exposure.
5. **Gluetun stays commented out** until a VPN provider with working port
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
config/
  recyclarr/recyclarr.yml quality profile templates (tracked, not ignored)
scripts/
  validate.sh             static checks; run before every commit
  init-tree.sh            create the §3.1 /data tree in a running stack
  test-hardlinks.sh       prove the hardlink invariant
docs/
  spec.md                 source of truth — the build specification
  decisions.md            implementation decisions + open questions
  dev-testing.md          what can and cannot be validated on macOS
  verification.md         the acceptance checklist, run on the target
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
them. Placeholders in tracked files use the spec's own notation:
`<host>.ts.net`, `<render-gid>`, `<disk1-uuid>`.

If you need a real value to make progress, ask for it — don't invent one that
looks plausible and gets copy-pasted into production.

## Validating changes here

One command, works on macOS and Debian, needs nothing running:

```bash
./scripts/validate.sh
```

It parses the compose config, asserts mechanically that exactly the five media
services mount `/data` and that they all resolve to **one** source (invariant 1
and 2, which no runtime error would catch), confirms Gluetun is still commented
out, validates both Caddyfiles, and shellchecks every script. Run it before
every commit.

With the stack up, `./scripts/test-hardlinks.sh` proves invariant 2 for real —
it writes a file as qBittorrent and links it as Sonarr, then compares device,
inode, and link count.

`setup.sh` cannot run here, but its logic can be exercised in a container:

```bash
docker run --rm -v "$PWD:/repo:ro" debian:trixie \
  bash -c 'cd /repo && bash setup.sh --dry-run --skip-packages --disk /dev/sdX'
```

`shellcheck` and `yamllint` are not installed natively; `validate.sh` uses the
container forms.

## Current state

All spec §9 deliverables are implemented. Verified on the Mac: both compose
layerings render correctly, all eight containers start, every web UI responds
directly and through Caddy, and the hardlink test passes on the named volume.

Untested until the Debian box exists — do not report these as working: hardware
transcoding, `*.ts.net` certificates, tailnet-only binding, UFW, smartd
delivery, and unattended boot. They are tracked in
[`docs/verification.md`](docs/verification.md); open questions are in
[`docs/decisions.md`](docs/decisions.md).
