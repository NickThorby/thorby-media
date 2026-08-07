# Verification checklist

The acceptance criteria from spec §9.1, turned into commands. **All of these run
on the Debian target**, not on the dev workstation — none of them can be
meaningfully approximated on macOS (see `dev-testing.md`).

Work through them in order. Items 1–2 should pass before the stack is
configured; 3–4 are the ones people skip and regret.

---

## 1. `vainfo` reports HEVC and H.264 encode/decode entrypoints

```bash
vainfo 2>&1 | grep -Ei 'h264|hevc'
```

Expect both `VAEntrypointVLD` (decode) and `VAEntrypointEncSlice` or
`VAEntrypointEncSliceLP` (encode) against H264 and HEVC profiles.

If `vainfo` reports no driver or `/dev/dri` is missing entirely, the iGPU is
disabled in BIOS — revisit §1.1 (Integrated Graphics Enabled, IGD Multi-Monitor
Enabled, Initiate Graphic Adapter set to IGD). Nothing downstream will work
until this passes.

- [ ] Passes

## 2. `/dev/dri/renderD128` is visible inside the Jellyfin container

```bash
getent group render                       # note the GID; it must match RENDER_GID in .env
docker compose exec jellyfin ls -l /dev/dri
```

Expect `renderD128` present, and the container's user able to reach it. Then
confirm Jellyfin itself sees it: Dashboard → Playback → hardware acceleration
VAAPI, device `/dev/dri/renderD128`.

A functional test beats a settings screenshot — play a file that forces a
transcode (browser client, cap the quality) and watch:

```bash
intel_gpu_top
```

The Video engine should show activity. If the CPU pegs and the GPU stays idle,
it is falling back to software.

- [ ] Passes

## 3. A test import produces a shared inode, not a copy

The critical one. Grab something small, let Sonarr or Radarr import it, then:

```bash
ls -li /data/torrents/movies/<release>/<file>.mkv \
       /data/media/movies/<Title>/<file>.mkv
```

Expect the **first column (inode number) to be identical** on both lines, and
the link count (second column) to be `2` or higher.

Different inodes mean it copied. Fix before importing anything else — causes are
almost always: `torrents/` and `media/` on different filesystems, mismatched
container volume paths (§4.1), or "Use Hardlinks instead of Copy" turned off in
the *arr's Media Management settings.

- [ ] Passes

## 4. Disk usage does not double after import

```bash
df -h /data          # before the import
df -h /data          # after
```

Used space should be effectively unchanged. A second corroborating check:

```bash
du -sh /data/torrents /data/media    # sum of these...
df -h /data                          # ...will exceed actual used space if hardlinked
```

- [ ] Passes

## 5. All services reachable over Tailscale, none over the public IP

```bash
tailscale ip -4                                  # the tailnet address
curl -sI https://jellyfin.<host>.ts.net | head -1
ss -tlnp | grep -E '443|8096|8989|7878|9696|6767|8080'
```

Caddy's 80/443 must be bound to the tailnet IP only, not `0.0.0.0`. Service
ports bound on the LAN are expected and intended (see D1 in `decisions.md`).

Then confirm the outside is closed: from a network off the tailnet and off the
LAN, attempt to reach the WAN IP on 80, 443, 8096, and 8080. All must fail.
Confirm the router has **no port forwarding rules** pointing at this box.

```bash
ufw status verbose        # SSH + tailscale0 allowed, default deny incoming
```

- [ ] Passes

## 6. `smartd` sends a test alert successfully

Depends on Q3 in `decisions.md` — a mail transport must exist first, or this
fails silently and the drive has no early warning at all.

Add `-M test` to the device line in `/etc/smartd.conf`, then:

```bash
systemctl restart smartd
journalctl -u smartd -n 50
```

An email should arrive on restart. **Remove `-M test` afterwards** or every
restart mails you. Baseline the drive while you are here:

```bash
smartctl -a /dev/disk/by-uuid/<disk1-uuid> | grep -E 'Reallocated|Pending|Uncorrect|Power_On'
```

- [ ] Passes

## 7. qBittorrent default credentials changed

Default is `admin` with a temporary password printed to the container log on
first start. Change it in Settings → Web UI, and confirm the old one no longer
works.

While there, confirm **Run external program on torrent completion is empty**
(§5.3 — it is arbitrary command execution).

- [ ] Passes

## 8. Machine boots unattended and all containers start after a hard power cut

Not a graceful reboot — cut power at the wall, restore it, and touch nothing.

```bash
uptime
docker compose -f /opt/mediaserver/docker-compose.yml ps
```

Every service `running`. This exercises BIOS `Restore on AC Power Loss: Power
On` (§1.1), `systemctl is-enabled docker`, the fstab mounts coming up in the
right order, and `restart: unless-stopped`.

```bash
findmnt /mnt/disk1 && findmnt /data
```

Both mounted. A missing bind mount here is how containers end up writing into an
empty `/data` on the SSD.

- [ ] Passes
