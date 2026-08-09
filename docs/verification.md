# Verification checklist

The acceptance criteria from spec §9.1, turned into commands. **All of these run
on the box**, and most of them cannot be meaningfully approximated anywhere
else — that is why they are a separate checklist rather than part of
`validate.sh`.

Work through them in order. Items 1–2 do not apply to this box and say why;
3–4 are the ones people skip and regret.

---

## 1. `vainfo` reports HEVC and H.264 encode/decode entrypoints

**Not applicable on this hardware, and not merely pending (decisions.md D35).**

The MSI Z370 GODLIKE GAMING has no display outputs, and MSI ships no
Integrated Graphics Configuration menu on such boards — there is no
`IGD Multi-Monitor` setting anywhere in the firmware, so the i7-8700K's UHD 630
cannot be enabled. Confirmed on the box: nothing at PCI `00:02.0`, and the only
DRM device is the GTX 980 Ti under `nouveau`, which VAAPI cannot transcode with.

This is left as a check that cannot pass rather than deleted, because it becomes
live the moment a VAAPI-capable card is fitted — an Intel Arc A310 is the
intended one, and it needs no repo change at all: `RENDER_GID` stays 992,
`docker-compose.yml` already passes `/dev/dri`, and `setup.sh` already puts the
media user in the `render` group.

When that card is in:

```bash
vainfo 2>&1 | grep -Ei 'h264|hevc'
```

Expect both `VAEntrypointVLD` (decode) and `VAEntrypointEncSlice` or
`VAEntrypointEncSliceLP` (encode) against H264 and HEVC profiles.

- [ ] N/A — no VAAPI-capable GPU fitted

## 2. `/dev/dri/renderD128` is visible inside the Jellyfin container

**Also gated on D35.** `/dev/dri/renderD128` exists today and is passed into the
container, so a naive check here *passes* — it is the nouveau render node for
the 980 Ti, and it transcodes nothing. That is precisely the silent success this
file exists to catch, so identify the device by vendor rather than by name:

```bash
for d in /sys/class/drm/card*/device; do
  echo "$(basename "$(dirname "$d")") vendor=$(cat "$d/vendor")"
done                                      # 0x8086 is Intel; 0x10de is NVIDIA
getent group render                       # must match RENDER_GID in .env
docker compose exec jellyfin ls -l /dev/dri
```

With two cards fitted, enumeration order is not guaranteed, so set Jellyfin's
VAAPI device explicitly to whichever node is Intel rather than trusting the
`renderD128` default: Dashboard → Playback → hardware acceleration VAAPI.

A functional test beats a settings screenshot — play a file that forces a
transcode (browser client, cap the quality) and watch `intel_gpu_top`. The Video
engine should show activity; if the CPU pegs and the GPU stays idle, it is
falling back to software.

- [ ] N/A — no VAAPI-capable GPU fitted

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

## 5. Nothing is reachable from the internet but the WireGuard port

The single most important check in this file. **Rewritten for D33/D34** — this
used to verify that three names were public and nine apps were not. Nothing is
public now: the router forwards `WG_PORT` and nothing else, and all twelve names
resolve to the box's LAN address.

**Certificates, from DNS-01.** No inbound path is needed for issuance, so a
failure here is the Cloudflare token, not the router:

```bash
curl -sI https://<domain>          | head -1   # 200
curl -sI https://jellyfin.<domain> | head -1   # 302 to login
curl -sI https://sonarr.<domain>   | head -1   # 302 to login
docker compose logs caddy | grep -c 'certificate obtained'   # 12
docker compose logs caddy | grep -o '"issuer":"[^"]*"' | sort -u
```

The issuer must be `acme-v02` and not `acme-staging-v02`. A staging certificate
works perfectly for `curl -k` and fails in every browser in the house.

**Every name resolves to a private address.** This is what makes the records
harmless in a public zone:

```bash
for h in "" jellyfin. seerr. sonarr. radarr. lidarr. prowlarr. bazarr. qbit. sab. cleanuparr. wg.; do
  printf '%-12s %s\n' "$h" "$(dig +short "${h}<domain>" @1.1.1.1 | tr '\n' ' ')"
done
dig +short <wg-host> @1.1.1.1     # the ONLY name pointing at the WAN address
```

**The admin routes refuse anyone off-net.** `admin_only` is now the control that
the absence of a route used to be, so it is the thing to test. From a client
outside RFC1918 — which, with nothing forwarded, means from the box itself
against a source it does not trust, or after temporarily forwarding 443:

```bash
docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile \
  | jq -r '[.. | objects | select(.match? and ((.match[]?.host[]?) == "sonarr.<domain>"))] | .[0]
           | .handle[0].routes[] | "\(.handle[0].handler)  \(.match // "none")"'
```

`static_response` with a `not remote_ip` matcher must appear **before**
`reverse_proxy`. Handler order is the whole guarantee; if the 403 sorts after
the proxy it never runs.

**No packet.** From a host on neither the LAN nor the tunnel — a phone on mobile
data with WireGuard OFF:

```bash
nmap -Pn -p 80,443,5055,6767,6881,8080,8085,8096,8686,8989,7878,9696,11011,51821 <wan-ip>
nmap -Pn -sU -p 51820 <wan-ip>
```

**Every TCP port filtered or closed, 80 and 443 included** — that is the change
from D25. The UDP scan is expected to report `open|filtered`: WireGuard does not
answer a probe without a valid key, so nmap cannot tell the two apart, and that
indistinguishability is the property you want.

```bash
ufw status verbose        # SSH from the LAN, wg0, the LAN, 51820/udp, and
                          # 51821/tcp from 172.16.0.0/12 only. NOT 80 or 443.
```

That last rule is the one to read carefully: it exists solely so Caddy can proxy
the wg-easy UI, which host networking puts out of reach of a container name
(D34). It is the one place a container can reach a host listener.

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

## 11. Every name answers from the LAN and from the tunnel

**Rewritten for D33.** This used to test hairpin NAT — whether the router would
loop a LAN client back through its own WAN address to reach the public names.
That failure mode is gone: the names resolve straight to `192.168.0.10`, so no
packet leaves the house and there is nothing to hairpin.

From a LAN client that is **not** the box:

```bash
for h in "" jellyfin. seerr. sonarr. qbit. wg.; do
  printf '%-10s %s\n' "$h" "$(curl -sI "https://${h}<domain>/" | head -1)"
done
```

All answer, with a certificate the browser accepts and no `-k`. Then the check
that matters more, from a phone on mobile data **with the tunnel up**: the same
commands, the same results. That equivalence is the whole remote-access design
(D26) — one address that works in both places.

With the tunnel **down**, all of them must fail to resolve or time out. If any
name answers from mobile data without the tunnel, something is forwarded that
should not be; go back to item 5.

- [ ] Passes

## 12. The landing page hides Manage from clients it should not trust

Presentation, not a control — but if it is wrong, the page advertises hostnames
it should not.

From a LAN or tunnel client:

```bash
curl -s https://<domain>/ | grep -c 'class="manage"'           # 1
curl -s https://<domain>/ | grep -c '{{'                       # 0 — templates ran
curl -s https://<domain>/ | grep -c 'class="chip"'             # 9
curl -s https://<domain>/ | grep -c 'i-lidarr\|i-cleanuparr'   # 2
```

A count of `{{` above zero means `templates` is missing from the site block, in
which case the conditional leaks as literal text **and** the admin section
renders to everyone. `validate.sh` catches that statically; this catches it live.

**The other half of this check can no longer be run, and that is worth stating
rather than leaving as an unticked box.** It used to be done from a phone on
mobile data, including the `X-Local-Client` spoof that D31 closed. Under D33
nothing is forwarded, so there is no vantage point outside RFC1918 from which to
reach Caddy at all — every request that can arrive is one `private_only` treats
as private, and the `@public` branch is unreachable by construction.

So the public-side behaviour of both `private_only` and `admin_only` is now
asserted **structurally** rather than observed:

- `validate.sh` asserts `sites.caddy` strips a client-supplied `X-Local-Client`
- `validate.sh` asserts every block in `admin.caddy` imports `admin_only`, and
  that its ranges match `private_only`'s
- item 5's `caddy adapt` check asserts the 403 handler sorts before the proxy

If `PUBLIC_HTTP` is ever set true, this item becomes testable again and **must
be run before the forward is opened**, not after.

- [ ] Passes (LAN/tunnel half)
- [ ] N/A — no off-network vantage point exists while PUBLIC_HTTP is false

## 12a. Every link on the page is built client-side and resolves

**Rewritten for D34.** The tiles used to carry a server-rendered `data-lan`
override so a local client went to `<lan-ip>:<port>` instead of hairpinning; the
Manage chips carried server-rendered `ADMIN_HOST:<port>` hrefs. Both are gone.
Every link is now `https://<data-sub>.<host-the-page-was-served-from>`, built by
`app.js`, and the page reads no environment at all.

```bash
curl -s https://<domain>/ | grep -c 'data-lan'                 # 0 — removed
curl -s https://<domain>/ | grep -oE '\{\{env "[A-Z_]+"\}\}'   # nothing
curl -s https://<domain>/ | grep -c 'href="#"'                 # 11 — JS fills these
```

The `href="#"` count is the tell: eleven links (two tiles, nine chips) ship with
a placeholder and are rewritten on load. `app.js` is a plain synchronous script
at the end of `<body>`, not `defer`, precisely so they are never visible and
clickable while still pointing at `#`.

Then in a LAN browser, which is the only place the rest can be checked:

- every tile and chip navigates to `https://<name>.<domain>` and the app loads
- **every dot is green**

The dots are no longer the subtle case they were under D31. Because every link
is https on a real certificate, `href` and the probe URL are the same again — so
a green dot now attests to the link beneath it, rather than to a public path the
link did not take. A grey dot means that specific name is not answering.

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
