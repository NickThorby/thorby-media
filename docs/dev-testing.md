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
./scripts/provision.sh --init-keys   # generate API keys into .env, chmod it 0600
docker compose up -d
./scripts/init-tree.sh               # create the §3.1 tree inside the volume
./scripts/provision.sh               # wire the download clients, *arrs and Prowlarr
./scripts/validate.sh
./scripts/audit-auth.sh
./scripts/test-hardlinks.sh
```

`provision.sh` is fully exercisable here — it talks to the same APIs it will on
the target, so a pass locally means the wiring logic is correct. Log in to the
*arrs with `ARR_USER`/`ARR_PASS` and to qBittorrent with `QBIT_USER`/`QBIT_PASS`,
all from `.env`.

`audit-auth.sh` is exercisable here too, and is worth running in both directions
— an assertion that has never been seen to fail is not evidence of anything:

```bash
# Should fail on two Sonarr checks, then pass again.
ARR_AUTH_REQUIRED=DisabledForLocalAddresses docker compose up -d sonarr
./scripts/audit-auth.sh ; docker compose up -d sonarr
```

Note that bash here is **3.2** (macOS ships no newer one), while the target has
bash 5. `mapfile`, `declare -A` and safe empty-array expansion under `set -u` are
all unavailable — use the read-loop idiom `validate.sh` and `backup-config.sh`
already use, or a script that works on the target will fail here.

Services are on loopback only: Jellyfin `:8096`, Prowlarr `:9696`, Sonarr
`:8989`, Radarr `:7878`, Bazarr `:6767`, qBittorrent `:8081`, SABnzbd `:8085`,
Jellyseerr `:5055`, and Caddy on `:8443`.

Set `PUBLIC_DOMAIN` to an sslip.io name — it answers any subdomain with the IP
embedded in it, so `192.168.0.198.sslip.io` gives working `jellyfin.` and
`seerr.` hostnames with no hosts file and no real domain. The landing page is at
**`https://<PUBLIC_DOMAIN>:8443`**; the two tile links are built from
`location.host` at runtime, so one file works here and on the target.

Only three names are routed — landing, `jellyfin.` and `seerr.`. The six admin
apps are reached at `<ADMIN_HOST>:<port>` and are not proxied, here or on the
target. A request to `sonarr.<PUBLIC_DOMAIN>` should fail to match any site,
and that is the behaviour to preserve.

`./caddy/site` is a bind mount and `file_server` reads from disk per request, so
editing the page takes effect on the next reload — no `docker compose restart`.

**The status dots will not appear here by default, and that is correct.** Each
one is a `no-cors` probe, and each target is a separate origin with its own
certificate from Caddy's internal CA. You accepted the warning for the bare
domain; you never accepted one for `jellyfin.<PUBLIC_DOMAIN>`, so the probes
fail on TLS and the page hides the dots rather than showing a wall of grey. To
see the real thing, trust the CA — note this changes your login keychain:

```bash
docker compose cp caddy:/caddydata/caddy/pki/authorities/local/root.crt /tmp/caddy-root.crt
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db /tmp/caddy-root.crt
```

Stopping a container will *not* turn its dot grey — Caddy answers 502 and an
opaque response cannot see the status (decisions.md D24).

**The Manage section is visible here, and that depends on one dev-only line.**
Caddy shows it to clients in RFC1918 or the Tailscale range, but Docker Desktop
rewrites every client address to a synthetic `172.67.x` — which is *not* private,
since the /12 stops at 172.31. `Caddyfile.dev`'s `(private_only)` snippet adds
`172.67.0.0/16` for exactly that reason. Production must never carry that line.
It is the same rewrite that made SABnzbd refuse every caller (D25).

To check the Usenet hardlink tree as well as the torrent one:

```bash
DOWNLOADER=sabnzbd SRC_DIR=/data/usenet/complete/tv LABEL=usenet \
  ./scripts/test-hardlinks.sh
```

---

## What can be checked here

### Static validation

```bash
./scripts/validate.sh
```

Parses the compose config, asserts that exactly the six media services mount
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

A macOS bind mount was assumed not to do this — VirtioFS has documented
permission-mapping bugs, so a hardlink test across one was expected to prove
nothing either way. That is the reason for the named volume; see D9 in
`decisions.md`.

Measured, on Docker Desktop with VirtioFS, that assumption no longer holds: a
cross-directory hardlink over a bind mount to an APFS volume reports one device,
one inode and a link count of two, and a UID-1000 process writes files that come
back owned by 1000. Both download trees pass `test-hardlinks.sh` that way. Treat
that as a property of the current Docker Desktop rather than a guarantee — it is
worth re-running the test after a Docker upgrade.

### Putting `/data` on an external disk

The named volume is the right default, but it lives inside Docker's VM disk
image on the **boot drive**, so it is the wrong place to test real downloads —
a couple of films will fill it. Set `DEV_DATA_ROOT` in `.env` to a directory on
an external disk and every media service binds there instead:

```bash
DEV_DATA_ROOT=/Volumes/YourDisk/data
```

Compose reads a value starting with `/` as a bind mount and anything else as a
named volume, so leaving it unset restores the default with no other change.

The disk must be **APFS or HFS+**. exFAT and FAT32 have no hardlinks at all, so
every import would silently fall back to copying — double disk usage, slow
imports, broken seeding, and no error anywhere. Create the §3.1 tree under that
directory, then prove the invariant before trusting it:

```bash
mkdir -p /Volumes/YourDisk/data/{torrents/{movies,tv,anime},\
usenet/{incomplete,complete/{movies,tv,anime}},media/{movies,tv,anime}}
docker compose up -d
./scripts/test-hardlinks.sh
DOWNLOADER=sabnzbd SRC_DIR=/data/usenet/complete/tv LABEL=usenet ./scripts/test-hardlinks.sh
```

Note that `docker compose down -v` does **not** clear a bind-mounted `/data` —
only the named volume. Delete the directory yourself if you want a clean slate.

The test spans two containers on purpose: qBittorrent writes the file as it
would a completed download, Sonarr links it as it would on import. That
exercises the identical-path rule as well as the same-filesystem rule.

### Reverse proxy routing

Caddy runs here with `local_certs`, issuing from its own internal CA, so the
full proxy path is exercised:

```bash
curl -kI "https://jellyfin.${PUBLIC_DOMAIN}:8443/"     # proxied, expect 200/302
curl -kI "https://sonarr.${PUBLIC_DOMAIN}:8443/"       # must NOT proxy
```

sslip.io resolves both, so the second one proves the route is genuinely absent
rather than merely unresolvable. The certificate will not be trusted until you
add Caddy's root CA to the keychain; `-k` is fine, since this proves routing,
not trust.

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

**A dry run is not full coverage, and relying on it hid a real bug.** Steps that
append to a file — the `DOCKER-USER` rules — are skipped under `--dry-run`, and
until August 2026 the non-dry-run path exited silently right after preflight
because a trailing `$DRY_RUN && warn ...` returned 1 under `set -e`. The script
had therefore never actually run to completion anywhere. To exercise the real
path, stub what a container cannot provide and run it **twice**, since
idempotency is the property most likely to be wrong:

```bash
docker run --rm -v "$PWD:/repo:ro" debian:trixie bash -c '
  apt-get update -qq && apt-get install -y -qq ufw openssh-server
  printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/systemctl
  printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/sshd
  chmod +x /usr/local/bin/systemctl /usr/local/bin/sshd
  cp -r /repo /work && cd /work
  echo "LAN_SUBNET=192.168.1.0/24" >> .env
  mkdir -p /root/.ssh && echo "ssh-ed25519 AAAAfake t@k" > /root/.ssh/authorized_keys
  bash setup.sh --skip-packages && bash setup.sh --skip-packages
  grep -c "BEGIN MEDIASERVER DOCKER-USER" /etc/ufw/after.rules   # must be 1
'
```

---

## What cannot be checked here

| Requirement | Why not | Verified by |
|---|---|---|
| VAAPI / Quick Sync transcoding | No `/dev/dri`, no Intel iGPU | `vainfo`, `intel_gpu_top` on target |
| Let's Encrypt issuance | Needs a real domain and inbound 80 | on target |
| The router port forward | No router in the loop | external port scan |
| Admin apps over Tailscale | No tailnet here | on target, from mobile data |
| UFW rules | Linux-only | on target |
| `DOCKER-USER` rules taking effect | Rules are written here, never loaded | `iptables -L DOCKER-USER`, external port scan |
| fail2ban, unattended-upgrades | No systemd in the container | on target |
| smartd tests and alert delivery | No SATA disk, no SMART, no relay | on target |
| The backup systemd timer firing | No systemd | on target |
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
