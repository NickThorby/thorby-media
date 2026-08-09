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
```

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

## 5. Three names public, seven apps not — and the certificates issue

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

**No DNS for the six.** Each must return nothing at all:

```bash
for h in sonarr radarr prowlarr bazarr qbit sab; do
  printf '%-9s %s\n' "$h" "$(dig +short "$h.<domain>" | tr '\n' ' ')"
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
nmap -Pn -p 80,443,5055,6767,6881,8080,8085,8096,8989,7878,9696,51821 <wan-ip>
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
SABnzbd's login and `inet_exposure`, Bazarr's form auth, Jellyfin's setup wizard
and Jellyseerr's initialisation.

Two of those deserve a manual look because they are the ones a UI can undo:

- qBittorrent → Settings → Web UI: **Run external program on torrent completion
  is empty** (§5.3 — arbitrary command execution).
- Sonarr/Radarr/Prowlarr → Settings → General: authentication is **required for
  everyone**, not "disabled for local addresses". Caddy reaches these apps over
  the compose bridge, so the local-addresses exemption applies to every proxied
  request and leaves the admin UI open. The setting is pinned in
  `docker-compose.yml` and reverts on restart, but it can be wrong until then.

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
nmap -Pn -p 80,443,5055,6767,6881,8080,8085,8096,8989,7878,9696,51821 <public-ip>
```

All filtered or closed except 80 and 443. Item 5 tests the same thing but was
written assuming UFW was what enforced it.

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

A count of `{{` above zero means `templates` is missing from the site block, in
which case the conditional leaks as literal text **and** the admin section
renders publicly. `validate.sh` catches that statically; this catches it live.

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
