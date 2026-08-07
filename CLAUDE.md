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
4. **Nothing is exposed to the public internet.** No router port forwarding.
   Caddy binds only to the Tailscale interface. qBittorrent's
   "run external program on completion" is arbitrary command execution by
   design; the *arr apps authenticate with a key printed in their own UI.
   Neither tolerates hostile exposure. Never add a `0.0.0.0` publish or a
   public DNS record.
5. **Gluetun stays commented out** until a VPN provider with working port
   forwarding is chosen (§7). Do not uncomment it speculatively.

## Repo layout

```
CLAUDE.md              this file
README.md              operator-facing: build, configure, migrate
.env.example           template; the real .env is gitignored
docker-compose.yml     the stack (deliverable §9.1)
Caddyfile              reverse proxy, Tailscale-bound (deliverable §9.3)
setup.sh               host provisioning for Debian (deliverable §9.4)
docs/
  spec.md              source of truth — the build specification
  decisions.md         implementation decisions + open questions
  dev-testing.md       what can and cannot be validated on macOS
  verification.md      the acceptance checklist, run on the target
```

## Conventions

- **Compose:** no top-level `version:` key — it is obsolete and Compose v2+
  warns about it. One file, no overrides, no profiles unless a deliverable needs
  them.
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

These work on macOS and are cheap. Run them before claiming a config change is
good:

```bash
docker compose config -q                       # compose syntax + env interpolation
docker run --rm -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:alpine caddy validate --config /etc/caddy/Caddyfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable setup.sh
```

`shellcheck` and `yamllint` are not installed natively on this box; use the
container forms above.

## Current state

Documentation phase. `docker-compose.yml`, `.env.example`, `Caddyfile`,
`setup.sh`, and the operator sections of `README.md` are **not written yet** —
see the deliverables list in §9 of the spec and the open questions in
[`docs/decisions.md`](docs/decisions.md).
