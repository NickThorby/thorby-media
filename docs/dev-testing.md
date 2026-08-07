# Developing and testing on the macOS box

This repo is written on a Mac and runs on a Debian server. The gap matters: most
of what makes this build correct — hardlinks across a real ext4 filesystem, VAAPI
on Intel Quick Sync, Tailscale interface binding, UFW, smartd — does not exist
here and cannot be faked convincingly.

The rule: **validate syntax and structure locally, verify behaviour on the
target.** A local pass means the config is well-formed, not that the system
works.

---

## What can be checked here

### Compose file

```bash
docker compose config -q          # parse + env interpolation, no output = good
docker compose config             # render the fully resolved file and read it
```

Requires a `.env` present (copy `.env.example`). The rendered output is the best
way to confirm every media-touching service really does get an identical
`/data:/data` mount — read it, don't assume.

### Caddyfile

```bash
docker run --rm -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:alpine caddy validate --config /etc/caddy/Caddyfile
```

Prints `Valid configuration` on success. This checks grammar and directive
usage. It cannot check that the tailnet hostnames resolve or that certs will
issue — see Q2 in `decisions.md`.

Formatting: `caddy fmt --overwrite` via the same container form.

### setup.sh

```bash
bash -n setup.sh                  # syntax only
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable setup.sh
```

`shellcheck` is not installed natively on this box; use the container.

**Never execute `setup.sh` here.** It creates system users, rewrites
`/etc/fstab`, formats a disk, and installs firewall rules. It is Debian-only and
destructive by design.

### Bringing containers up locally

Possible, with caveats, and only as a smoke test that images pull and web UIs
respond:

- Point `DATA_ROOT` and `CONFIG_ROOT` at throwaway directories under your home,
  not `/data` and `/opt/mediaserver`.
- Comment out Jellyfin's `devices:` and `group_add:` blocks — `/dev/dri` does
  not exist and the container will fail to start.
- `PUID`/`PGID` are meaningless under Docker Desktop's file sharing; ownership
  will not behave as it does on the target.
- Do not carry any config generated here over to the server. Start clean.

---

## What cannot be checked here — at all

| Requirement | Why not | Verified by |
|---|---|---|
| Hardlink imports share an inode | Needs one real ext4 filesystem holding both `torrents/` and `media/`; Docker Desktop's virtiofs sharing does not reproduce it | §9.1, on target |
| VAAPI / Quick Sync transcoding | No `/dev/dri`, no Intel iGPU | `vainfo` on target |
| Caddy bound to the tailnet interface | No Tailscale, no tailnet IP | on target |
| TLS certs for `*.ts.net` | Requires the real tailnet | on target |
| UFW rules | Linux-only | on target |
| smartd tests and alerting | No SATA disk, no SMART | on target |
| Unattended boot after power loss | Physical | on target |

Anything in this table is reported as **untested** until it has run on the
Debian box. Do not describe a local approximation as a pass.

---

## Architecture note

The target is `linux/amd64`. On Apple Silicon, Docker Desktop will emulate that
and some LinuxServer images may run slowly or not at all. Emulation performance
here says nothing about performance on the i7-8700K.

---

## Before pushing config to the target

1. `docker compose config -q` clean
2. `caddy validate` clean
3. `shellcheck setup.sh` clean
4. Rendered compose read through: every media service mounts `/data:/data`
   identically, configs are per-service, Gluetun still commented out
5. No secrets, tailnet IP, or real hostname in tracked files
