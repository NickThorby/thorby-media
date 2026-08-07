# Developing and testing on the macOS box

This repo is written on a Mac and runs on a Debian server. The gap matters:
hardware transcoding, Tailscale binding, UFW and smartd do not exist here and
cannot be faked convincingly.

The rule: **validate everything that can be validated, and be explicit about
what cannot.** A local pass on the things below is real; anything in the second
table is untested until the Debian box exists.

---

## Setup

```bash
cp .env.example .env
```

Then uncomment the **MAC DEV block** at the bottom of `.env`. Later assignments
win, so that block overrides the Debian values above it — porting to the target
is a matter of commenting it out again. It sets `COMPOSE_FILE` so the dev
override layers automatically, and `docker compose up -d` needs no flags on
either machine.

```bash
docker compose up -d
./scripts/init-tree.sh          # create the §3.1 tree inside the volume
./scripts/validate.sh
./scripts/test-hardlinks.sh
```

Services are on loopback only: Jellyfin `:8096`, Prowlarr `:9696`, Sonarr
`:8989`, Radarr `:7878`, Bazarr `:6767`, qBittorrent `:8081`, and Caddy on
`:8443` serving `https://<service>.localhost:8443`.

---

## What can be checked here

### Static validation

```bash
./scripts/validate.sh
```

Parses the compose config, asserts that exactly the five media services mount
`/data` and that all of those mounts resolve to **one** source, confirms no
service remaps media to a non-`/data` container path, checks Gluetun is still
commented out, validates both Caddyfiles, and shellchecks every script.

The `/data` assertions are the valuable part: spec §4.1 is otherwise enforced
only by reading carefully, and violating it produces no runtime error.

### Hardlinking — genuinely testable here

```bash
./scripts/test-hardlinks.sh
```

This works because the dev override puts `/data` on a **named Docker volume**
rather than a host bind mount. A named volume lives on real ext4 inside Docker's
Linux VM, so inodes, link counts and ownership behave exactly as they will on
the target.

A macOS bind mount would not do this. VirtioFS has documented permission-mapping
bugs and does not reproduce inode semantics faithfully, so a hardlink test
across one would prove nothing either way. That is the whole reason for the
named volume — see D9 in `decisions.md`.

The test spans two containers on purpose: qBittorrent writes the file as it
would a completed download, Sonarr links it as it would on import. That
exercises the identical-path rule as well as the same-filesystem rule.

### Reverse proxy routing

Caddy runs here with `local_certs`, issuing from its own internal CA, so the
full proxy path is exercised:

```bash
curl -kI https://sonarr.localhost:8443/
```

macOS resolves `*.localhost` to 127.0.0.1. The certificate will not be trusted
until you add Caddy's root CA to the keychain; `-k` or clicking through the
warning is fine, since this proves routing, not trust.

### setup.sh

Never execute it here — it creates system users, rewrites `/etc/fstab`,
configures a firewall and can format a disk. It refuses to run on non-Debian, so
an accidental invocation is an error rather than damage.

Its logic can still be exercised, in a real Debian container:

```bash
bash -n setup.sh                                    # syntax
docker run --rm -v "$PWD:/repo:ro" debian:trixie \
  bash -c 'cd /repo && bash setup.sh --dry-run --skip-packages --disk /dev/sdX'
```

`--dry-run` prints every mutation without applying any. This is also how the
first run on the real target should start.

---

## What cannot be checked here

| Requirement | Why not | Verified by |
|---|---|---|
| VAAPI / Quick Sync transcoding | No `/dev/dri`, no Intel iGPU | `vainfo`, `intel_gpu_top` on target |
| `*.ts.net` certificates | Requires a real tailnet and tailscaled | on target |
| Caddy bound to the tailnet interface | No Tailscale here | on target |
| UFW rules | Linux-only | on target |
| smartd tests and alert delivery | No SATA disk, no SMART, no relay | on target |
| Unattended boot after power loss | Physical | on target |
| ext4 `-m 0`, fstab, bind mount | No real disk | on target |

Anything in this table is reported as **untested**. Do not describe a local
approximation as a pass. The full list with commands is in `verification.md`.

---

## Architecture note

This Mac is arm64 and runs the LinuxServer images natively; the target is amd64.
Configuration is identical across both, but per-architecture image bugs are not
something local testing can rule out.

---

## Resetting

The dev stack keeps everything in named volumes, so a clean slate is:

```bash
docker compose down -v     # -v also drops mediadata and every config volume
docker compose up -d && ./scripts/init-tree.sh
```

Nothing dev-related is written into the working tree, and `docker compose down`
without `-v` preserves state across restarts.

---

## Before pushing config to the target

1. `./scripts/validate.sh` clean
2. `./scripts/test-hardlinks.sh` passes
3. `setup.sh` dry-run reviewed in the Debian container
4. Rendered prod config read through — check it renders under the production
   layering too, not just dev:
   ```bash
   COMPOSE_FILE=docker-compose.yml RENDER_GID=993 CADDY_BIND_ADDR=100.x.y.z \
     docker compose config | less
   ```
5. No secrets, tailnet IP, or real hostname in tracked files
