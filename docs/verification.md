# Verification checklist

The acceptance criteria from spec §9.1, turned into commands. **All of these run
on the box**, and most of them cannot be meaningfully approximated anywhere
else — that is why they are a separate checklist rather than part of
`validate.sh`.

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

The critical one. `scripts/test-hardlinks.sh` automates it — it writes a file as
qBittorrent and links it as Sonarr, then compares device, inode and link count,
which also proves the two containers agree about `/data`:

```bash
./scripts/test-hardlinks.sh
DOWNLOADER=sabnzbd SRC_DIR=/data/usenet/complete/tv LABEL=usenet \
  ./scripts/test-hardlinks.sh    # the Usenet tree must pass too
IMPORTER=lidarr SRC_DIR=/data/torrents/music DST_DIR=/data/media/music \
  LABEL=music ./scripts/test-hardlinks.sh    # and the music tree
```

The third run is the one that catches a Lidarr added without its `/data` mount,
or with a different one. It is a separate container pair from the first two, so
neither of them would notice.

Then confirm it holds for a *real* import too. Grab something small, let Sonarr
or Radarr import it, and check by hand:

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

## 5. Three names public, nine apps not — and the certificates issue

The single most important check in this file. Three separate mechanisms are
supposed to keep the admin apps off the internet (D25); verify each, because
any one of them silently doing nothing still leaves the other two working.

**Certificates.** Requires both 80 and 443 forwarded — Let's Encrypt validates
over 80, and if only 443 is forwarded issuance fails while everything looks
correct:

```bash
curl -sI https://<domain>            | head -1   # 200
curl -sI https://jellyfin.<domain>   | head -1   # 200 or a redirect to login
curl -sI https://seerr.<domain>      | head -1   # 200 or a redirect to login
docker compose logs caddy | grep -i 'certificate obtained'
```

**No DNS for the eight.** Each must return nothing at all:

```bash
for h in sonarr radarr lidarr prowlarr bazarr qbit sab cleanuparr; do
  printf '%-11s %s\n' "$h" "$(dig +short "$h.<domain>" | tr '\n' ' ')"
done
```

**No route even if DNS existed.** Force the Host header past DNS:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --resolve "sonarr.<domain>:443:<wan-ip>" \
  "https://sonarr.<domain>/"
```

Anything other than a proxied 200 is correct — Caddy has no site for that name.

**No packet.** From a host on neither the LAN nor the tunnel — a phone on
mobile data, with WireGuard OFF — will do:

```bash
nmap -Pn -p 80,443,5055,6767,6881,8080,8085,8096,8686,8989,7878,9696,11011,51821 <wan-ip>
nmap -Pn -sU -p 51820 <wan-ip>
```

Every published port is in that list on purpose, `8085` included — SABnzbd runs
post-processing scripts, so an open SABnzbd is the same class of risk as an open
qBittorrent (spec §5.3), and it is the one most easily left out of a scan
because it is the only host port that does not match its container port.

Only 80 and 443 open on TCP; everything else filtered or closed, `51821`
included. The UDP scan is expected to report `open|filtered` — WireGuard does
not answer a probe without a valid key, so nmap cannot tell the two apart. That
indistinguishability is the property you want.

**Admin access still works.** With the tunnel up on the client, using the *same*
address the LAN uses — that equivalence is the thing being tested:

```bash
curl -sI http://<lan-ip>:8989 | head -1
```

```bash
ufw status verbose        # SSH, wg0, LAN, 80/443 and 51820/udp allowed
```

- [ ] Passes

## 5a. WireGuard: the same address works from outside

The property the whole remote-access design turns on (D26). Test it from a phone
on mobile data, not from anything on the home network.

**On the box**, first — `wg0` must be a *host* interface, not just something
inside the container. If this fails, the container is on a bridge and the
firewall rules will never match:

```bash
ip link show wg0                       # exists, state UNKNOWN/UP
docker compose ps wg-easy              # healthy
```

**Add a peer** in the wg-easy UI at `http://<lan-ip>:<WG_UI_PORT>`, scan the QR
code with the WireGuard app.

**Tunnel up, from mobile data:**

```bash
curl -sI http://<lan-ip>:8989 | head -1      # Sonarr answers
curl -sI http://<lan-ip>:<WG_UI_PORT> | head -1   # login page, not a session
```

The address must be the *same* one that works on the LAN. If you find yourself
reaching for a `10.8.0.x` address instead, `INIT_ALLOWED_IPS` is not routing the
LAN and the landing page's Manage links will be broken from outside the house.

**Tunnel down, same device:** neither answers. If they do, the ports are exposed
some other way and item 5 needs re-reading.

**Split tunnel:** with the tunnel up, ordinary browsing still works and
`https://ifconfig.me` reports the *phone's* address, not the home WAN address.
Full-tunnel behaviour here means `INIT_ALLOWED_IPS` is wider than intended.

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

## 7. Every app enforces authentication

`provision.sh` now sets qBittorrent's password from `.env` rather than leaving it
to a first login, so this is no longer a manual step — but it is still worth
confirming, along with everything else that can be switched off in a UI.

```bash
./scripts/audit-auth.sh
```

All checks must pass. It covers the *arr authentication method and scope, the
API keys, qBittorrent's session enforcement and external-program setting,
SABnzbd's login and `inet_exposure`, Bazarr's form auth, Jellyfin's setup wizard,
Jellyseerr's initialisation, wg-easy's session, and Cleanuparr's setup state and
local-address bypass.

Three of those deserve a manual look because they are the ones a UI can undo:

- qBittorrent → Settings → Web UI: **Run external program on torrent completion
  is empty** (§5.3 — arbitrary command execution).
- Sonarr/Radarr/Lidarr/Prowlarr → Settings → General: authentication is
  **required for everyone**, not "disabled for local addresses". Caddy reaches
  these apps over the compose bridge, so the local-addresses exemption applies to
  every proxied request and leaves the admin UI open. The setting is pinned in
  `docker-compose.yml` and reverts on restart, but it can be wrong until then.
- Cleanuparr → Settings → General → Authentication: **Disable Auth for Local
  Addresses is off**. Unlike the *arrs nothing reverts this on restart, and its
  trusted ranges include `172.16.0.0/12` — the Docker bridge — so it exempts the
  whole stack rather than the LAN (D30).

- [ ] Passes

## 7a. UFW actually filters the container ports

The one that looks fine and is not. `ufw status` reporting default-deny says
nothing about Docker-published ports: they are DNAT'd and traverse `FORWARD`,
never `INPUT`. Confirm the `DOCKER-USER` rules are loaded (decisions.md D19):

```bash
sudo iptables -L DOCKER-USER -n -v
```

Expect RETURN rules for established traffic, `br+` and `docker0` from
`172.16.0.0/12`, `lo`, `wg0`, the LAN subnet and **tcp dports 80 and 443**, then
a final DROP. If the chain is empty, `setup.sh` skipped the step — almost
certainly because `LAN_SUBNET` is unset in `.env`.

The two port rules are what make the router forward work at all. Without them
the packet is DNAT'd, traverses `FORWARD`, and dies at the DROP while the router
configuration looks perfectly correct — so the symptom is "my domain times out"
with nothing in Caddy's log.

**Containers can still reach the internet.** `DOCKER-USER` is jumped from the top
of `FORWARD`, so it sees egress as well as inbound — the two `br+`/`docker0`
rules are what stop the final DROP killing every outbound connection a container
makes. Docker's embedded DNS resolver forwards its upstream queries from inside
the container's own namespace, so DNS is the first thing to go and everything
else follows it (decisions.md D28):

```bash
docker compose exec sonarr getent hosts github.com
docker compose exec caddy wget -q -O /dev/null https://acme-v02.api.letsencrypt.org/directory && echo ACME reachable
```

Both must succeed. If they do not, no indexer works, no Usenet article
downloads, and Caddy never obtains a certificate — while `iptables -L` looks
entirely reasonable and item 5's external scan passes.

Then prove the inbound side from off-box, on a host that is neither on the LAN
nor the tunnel (a phone on mobile data is enough):

```bash
nmap -Pn -p 80,443,5055,6767,6881,8080,8085,8096,8686,8989,7878,9696,11011,51821 <public-ip>
```

All filtered or closed except 80 and 443. Item 5 tests the same thing but was
written assuming UFW was what enforced it.

- [ ] Passes

## 8. Machine boots unattended and all containers start after a hard power cut

Not a graceful reboot — cut power at the wall, restore it, and touch nothing.

```bash
uptime
docker compose -f ~/thorby-media/docker-compose.yml ps
```

(`/opt/mediaserver` is `CONFIG_ROOT` — the app databases. The repo is a separate
checkout, and its path is baked into the backup unit, so do not move it.)

Every service `running`. This exercises BIOS `Restore on AC Power Loss: Power
On` (§1.1), `systemctl is-enabled docker`, the fstab mounts coming up in the
right order, and `restart: unless-stopped`.

```bash
findmnt /mnt/disk1 && findmnt /data
```

Both mounted. A missing bind mount here is how containers end up writing into an
empty `/data` on the SSD.

- [ ] Passes

## 9. Unattended security updates and SSH hardening are live

```bash
systemctl is-enabled unattended-upgrades
unattended-upgrade --dry-run --debug 2>&1 | tail -20
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'
systemctl status fail2ban --no-pager | head -5
sudo fail2ban-client status sshd
```

`PermitRootLogin no`. `PasswordAuthentication no` **only if** an
`authorized_keys` file existed when `setup.sh` ran — if it says `yes`, install a
key and re-run `setup.sh`, which deliberately refuses to lock out a box with no
key installed.

- [ ] Passes

## 10. A config backup restores

An untested backup is not a backup, and this is the only copy of every app
database (decisions.md D22).

```bash
systemctl list-timers mediaserver-backup.timer --no-pager
sudo systemctl start mediaserver-backup.service
./scripts/backup-config.sh --list
```

Then prove the archive is actually usable — restore into a scratch path and open
the database, rather than trusting that tar exited 0:

```bash
mkdir -p /tmp/restore-test
tar -xzf /mnt/disk1/backups/mediaserver-config-*.tar.gz -C /tmp/restore-test
ls /tmp/restore-test/mediaserver/
sqlite3 /tmp/restore-test/mediaserver/sonarr/sonarr.db 'PRAGMA integrity_check;'
rm -rf /tmp/restore-test
```

`integrity_check` must return `ok`. Anything else means the database was copied
mid-write and the backup is worthless.

- [ ] Passes

## 11. The landing page reaches the household, and the house reaches the domain

Hairpin NAT is the failure that only shows up indoors. From a LAN client that is
**not** the box and **not** on the tunnel:

```bash
curl -sI https://media.thorby.tech          | head -1
curl -sI https://jellyfin.media.thorby.tech | head -1
curl -sI https://seerr.media.thorby.tech    | head -1
```

All three answer, with a valid certificate. A timeout here while the same names
work from mobile data means the router will not loop a LAN client back through
its own WAN address. Fix it with a local DNS override on the router pointing
those three names at `CADDY_BIND_ADDR` — the certificate still validates, since
it is issued for the name and not the address.

```bash
dig +short media.thorby.tech
```

Run from a LAN client, this shows which answer that client is getting.

- [ ] Passes

## 12. The landing page hides Manage from the internet

Presentation, not a control — but if it is wrong, the page is advertising
hostnames it should not. Check both sides.

From a LAN or tunnel client:

```bash
curl -s https://<domain>/ | grep -c 'class="manage"'      # 1
curl -s https://<domain>/ | grep -c '{{'                  # 0 — templates ran
curl -s https://<domain>/ | grep -o 'http://[^"]*'        # <lan-ip>:<port> links
```

From off-network (phone on mobile data, or any host outside RFC1918):

```bash
curl -s https://<domain>/ | grep -c 'class="manage"'      # 0
```

Then the same request again, **sending the header yourself**. `templates` reads
`X-Local-Client` off the request as it arrived, so until `sites.caddy` strips it
for public clients, one header renders the whole Manage block to the internet.
The plain check above cannot see that, because the tester never sends it:

```bash
curl -s -H 'X-Local-Client: 1' https://<domain>/ | grep -c 'class="manage"'   # 0
curl -s -H 'X-Local-Client: 1' https://<domain>/ | grep -c 'data-lan'         # 0
```

A count above zero here is a disclosure, not a way in — the nine apps still have
no route, no DNS record and a `DOCKER-USER` drop — but it hands out `ADMIN_HOST`
and the port map, which is exactly what gating the sprite is for. `validate.sh`
asserts the strip statically; this is the live proof.

A count of `{{` above zero means `templates` is missing from the site block, in
which case the conditional leaks as literal text **and** the admin section
renders publicly. `validate.sh` catches that statically; this catches it live.

Nine chips, not seven, since D29 and D30 — and the sprite is gated on the same
header, so an off-network client must not receive the marks either:

```bash
# LAN or tunnel
curl -s https://<domain>/ | grep -c 'class="chip"'        # 9
curl -s https://<domain>/ | grep -c 'i-lidarr\|i-cleanuparr'   # 2
# off-network
curl -s https://<domain>/ | grep -c 'i-lidarr\|i-cleanuparr'   # 0
```

- [ ] Passes

## 12a. The hero tiles resolve locally on the LAN and publicly off it

D31. The two tiles the household uses now navigate to `<lan-ip>:<port>` for a
client inside and to the public names for everyone else, from the same file — so
both sides have to be checked or the failure is invisible from whichever one you
happen to be on.

From a LAN or tunnel client:

```bash
curl -s https://<domain>/ | grep -o 'data-lan="[^"]*"'
# data-lan="http://<lan-ip>:8096"
# data-lan="http://<lan-ip>:5055"
```

A trailing colon with no port — `http://10.0.0.5:` — means `JELLYFIN_PORT` or
`SEERR_PORT` is missing from the `caddy` service's `environment:` block in
`docker-compose.yml`. Caddy expands an unset `{{env}}` to the empty string, so
this renders a live link to nowhere rather than failing.

From off-network:

```bash
curl -s https://<domain>/ | grep -c 'data-lan'            # 0
```

Then in a LAN browser, which is the only place the last two can be checked:

- both tiles navigate to `http://<lan-ip>:<port>` and the app loads
- both tiles still show a **green dot**

The dots are the subtle one. They are probing the *public* name while the link
points at the LAN — deliberately, because an https page cannot fetch an http URL
(D31). If they are grey or absent, the public path is broken even though the
tiles work, which is exactly the split this arrangement exists to keep visible.

- [ ] Passes

## 13. fail2ban bans a real client address

```bash
sudo fail2ban-client status                # caddy-auth listed and enabled
sudo fail2ban-client status caddy-auth
```

Fail a Jellyfin login ten times from a device off the LAN, then re-check — the
banned IP must be **that device's address**, not Caddy's container IP. If it is
the container IP, the jail is reading the wrong log or Jellyfin's `KnownProxies`
is unset, and leaving it enabled would lock the household out.

The `jellyfin` jail ships **disabled** for exactly that reason. Enable it only
after setting `KnownProxies` to the compose bridge subnet in Jellyfin's network
settings, and re-run this check.

- [ ] Passes

## 14. Cleanuparr does not delete anything you wanted

The reason this is a checklist item and not a settings screenshot: Cleanuparr has
**write access to `/data`**, the media library is not in the backup set — the
backup covers `${CONFIG_ROOT}` only — and its whole purpose is removing things.
A misconfigured cleaner is unrecoverable in a way nothing else in this stack is.

Two things about the container itself first, both assumed rather than proven
because this image has never been started anywhere (D30).

**The healthcheck assumes `curl` is in the image.** Cleanuparr is not a
LinuxServer build, and Jellyseerr's healthcheck deliberately uses `wget` because
its image has no `curl` — so the binary is not a free choice here. Nothing
`depends_on` cleanuparr, so a wrong one does not cascade; it just leaves the
container permanently `unhealthy` and that status line stops meaning anything.

```bash
docker compose ps cleanuparr                                  # healthy
# if not:
docker compose exec cleanuparr sh -c 'command -v curl wget'   # swap the test
```

**`PUID`/`PGID` are honoured.** D30 records that Cleanuparr implements them
itself rather than through s6. If it does not, the process holding read-write
`/data` is root:

```bash
docker compose exec cleanuparr id                             # uid=1001 gid=1001
stat -c '%u %g %n' /mnt/disk1/data/torrents                   # 1001 1001
```

Then the cleaners. Ship them off (spec §6 step 8) and turn them on one at a
time, watching each. Before enabling any of them:

```bash
# what it thinks it is talking to
curl -s http://127.0.0.1:11011/api/auth/status | jq
# {"setupCompleted": true, "authBypassActive": false, ...}
```

Then, with the **Queue Cleaner** on but the **Download Cleaner** and
**Unlinked Download** handling still off, leave it for a day and read the log:

```bash
docker compose logs --since 24h cleanuparr | grep -iE 'remov|delet|clean'
```

Every removal it reports must correspond to a download that was genuinely
stalled, blocked or malware. Take a `find /data/media -type f | wc -l` count
before and after and confirm it has not moved — the Queue Cleaner should touch
the queue, never the library.

Only then enable unlinked-download handling, and re-run item 3 afterwards: it
decides what to delete by counting hardlinks, so if hardlinking has silently
degraded to copying, every imported file looks unlinked to it.

- [ ] Passes

## 15. Lidarr imports music, over the v1 API

Lidarr is the only app here reached on `/api/v1/` through helpers that were
`v3`-only before D29, and its root folder needs two profile ids that Sonarr and
Radarr do not. Both failure modes are quiet — `provision.sh` warns and carries
on rather than dying — so read the output rather than the exit code:

```bash
./scripts/provision.sh 2>&1 | grep -iA2 lidarr
```

Expect a root folder, two download clients and a Prowlarr link, with no
"skipping root folder" warning. That warning means Lidarr had no quality or
metadata profile yet when the provisioner ran; re-running after the app has
finished its first start usually clears it.

Then confirm the wiring took, from the API rather than the UI (D18 — the file
disagrees with the running app):

```bash
curl -s -H "X-Api-Key: $LIDARR_API_KEY" \
  http://127.0.0.1:8686/api/v1/rootfolder | jq '.[].path'          # /data/media/music
curl -s -H "X-Api-Key: $LIDARR_API_KEY" \
  http://127.0.0.1:8686/api/v1/downloadclient | jq '.[].name'      # SABnzbd, qBittorrent
curl -s -H "X-Api-Key: $LIDARR_API_KEY" \
  http://127.0.0.1:8686/api/v1/config/mediamanagement | jq '.copyUsingHardlinks'   # true
```

Finally add one small album and let it import. Item 3's music run proves the
filesystem can hardlink; this proves Lidarr actually does.

- [ ] Passes
