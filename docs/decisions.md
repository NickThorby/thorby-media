# Implementation decisions

The spec (`spec.md`) settles *what* gets built. This file records the choices
made while implementing it that the spec leaves open, and the questions still
outstanding. Add to it rather than relitigating a decision in a code comment.

---

## Decided

### D1. Service ports stay published on the LAN; the boundary is the router

§5.1 wants direct LAN access by IP and port, while §5.3 says the *arr UIs and
qBittorrent must never reach the public internet. These are not in conflict, and
resolving the second by unpublishing every port would break the first.

**Superseded in part by D25 and D26.** Ports 80, 443 and the WireGuard port
are now forwarded, and the interface is `wg0` rather than `tailscale0`.

The security boundary is: **no router port forwarding**, plus UFW denying
inbound except SSH and the Tailscale interface. Service ports bind normally so
the LAN can reach them. Only Caddy is restricted to the Tailscale interface,
because Caddy is the remote-access path.

Consequence: if this box is ever moved to an untrusted network, the model breaks.
The assumption is a trusted home LAN behind NAT.

### D2. Caddy binds one address via the port publish

`ports: - "${CADDY_BIND_ADDR}:443:443"` rather than host networking or a bind
directive inside the Caddyfile. Docker's publish address is the simplest
enforcement point, it fails closed if the address is wrong (Caddy won't start),
and it keeps Caddy on the compose bridge network so it can reach the other
services by container name.

The address itself is host-specific and lives in `.env`.

**Superseded in part by D25.** `CADDY_BIND_ADDR` was the tailnet IP; it is now
the LAN address the router forwards 80 and 443 to. The mechanism and its
rationale are unchanged — a specific address, never a wildcard, enforced by
Docker rather than by Caddy config. A `bind` directive would not have worked
anyway: Caddy binds inside its own network namespace, where the tailnet address
does not exist.

### D3. `restart: unless-stopped` on every service

§9.1 requires the machine to boot unattended and bring the stack up after a hard
power cut. Combined with `Restore on AC Power Loss: Power On` in BIOS (§1.1) and
a `docker` service enabled at boot, this is what satisfies that checklist item.
Not `always` — that fights manual `docker compose stop` during maintenance.

### D4. Container names are pinned and match the Caddyfile upstreams

The Caddyfile proxies to `sonarr:8989` etc. by name, so each service gets an
explicit `container_name` on the shared compose bridge network. Renaming a
service means editing both files.

### D5. `.env` is gitignored; `.env.example` is tracked

Compose auto-loads `.env` from the project directory. The template ships as
`.env.example` with placeholder values and gets copied on the target. Every
host-specific value — `PUID`, `PGID`, `TZ`, `RENDER_GID`, `LAN_SUBNET`, the
`WG_*` block, `DATA_ROOT`, `CONFIG_ROOT` — comes from there.

### D6. Config root is `${CONFIG_ROOT}`, defaulting to `/opt/mediaserver`

Per §4, container configs live on the SSD, separate from the media disk. Kept as
a variable rather than a literal so a rebuild can stage it elsewhere without
editing the compose file.

### D7. Image tags: `:latest`

LinuxServer images are rolling releases and the *arr ecosystem assumes reasonably
current versions; pinning digests here would mean hand-bumping seven images.
Updates are a deliberate `docker compose pull && docker compose up -d`, not
automatic — no Watchtower. Back up `${CONFIG_ROOT}` before pulling.

Revisit if an unattended update ever breaks the stack.

### D8. Two compose files, with production as the default

**Retired.** The macOS dev box is no longer part of the deployment, and
`docker-compose.dev.yml` was deleted with it. There is one compose file and
`docker compose up -d` takes no flags. The reasoning below is kept because the
asymmetry argument is worth re-reading if an override is ever proposed again.

`docker-compose.yml` is the complete Debian stack. `docker-compose.dev.yml`
strips what macOS cannot provide and is layered on only by setting
`COMPOSE_FILE` in `.env`. Both machines then run a bare `docker compose up -d`.

The direction is the point. If the portable config were the base and production
the override, forgetting `COMPOSE_FILE` on Debian would silently produce a
Jellyfin with no hardware transcoding — a quiet degradation. This way the
failure lands on the Mac, where a missing `/dev/dri` stops the container loudly.

Depends on Compose's `!reset` and `!override` merge tags, verified working on
Compose v5.1.3. Note that **interpolation happens before merging**: a `${VAR:?}`
in the base errors even when the override resets that field, which is why the
Mac block in `.env` still sets a dummy `RENDER_GID`.

### D9. The dev stack puts `/data` on a named Docker volume

**Retired with D8.** `/data` is a bind mount onto the real disk on the only
machine that now exists, so the hardlink test measures the real filesystem
rather than a stand-in for it.

Not a host bind mount. A named volume lives on ext4 inside Docker's Linux VM, so
inodes, link counts and PUID/PGID behave as they will on the target. macOS
VirtioFS has documented permission-mapping bugs and does not reproduce inode
semantics faithfully, which would make a local hardlink test result worthless —
and hardlinking is the invariant most likely to be silently wrong.

The cost is that `/data` is not browsable from Finder; use
`docker compose exec`. `scripts/init-tree.sh` creates the §3.1 tree inside it.

### D10. `LAN_SUBNET` reconciles §5.1 with §5.3

**Extended by D26.** `LAN_SUBNET` is no longer optional: it is half of
wg-easy's `INIT_ALLOWED_IPS`, so leaving it blank now also means peers get no
route to the LAN and admin addresses stop resolving from outside the house.

Spec §5.3 says "allow SSH and the Tailscale interface; deny inbound otherwise",
but applied literally that also blocks §5.1's direct LAN access — including
Infuse on the Apple TV reaching Jellyfin, which is the primary playback path.
The two sections conflict.

`setup.sh` resolves it with an explicit `LAN_SUBNET` in `.env`. Set it and the
home network is allowed in while the internet still is not; leave it blank and
the box is strictly tailnet-only and the script warns clearly about what that
costs. No subnet is ever guessed.

### D11. Caddy's certificate storage is relocated off `/data`

The `caddy` image stores certificates in `/data` by default. In this stack
`/data` means the media root in *every* container, and having exactly one where
it means something else is the kind of ambiguity that causes a mistake later.
`XDG_DATA_HOME=/caddydata` moves it. The image's own empty `/data` directory
remains in the container layer but is inert — not a volume, and never written.

### D12. API keys are pinned in `.env`, not read out of each UI

Sonarr, Radarr and Prowlarr accept their API key as a runtime environment
variable (`SONARR__AUTH__APIKEY` and friends). Setting it there means the key is
known before the container has ever started, which removes the chicken-and-egg
that otherwise blocks automated configuration: you cannot call the API until the
app has generated a key, and it only generates one on first run.

Verified: the key is enforced (401 on a wrong or missing key, 200 on the pinned
one) and is applied at runtime — it is never written into `config.xml`.

This is what makes `scripts/provision.sh` possible, and it also removes the
"copy the key out of the UI after first start" step that Recyclarr needed.

Treat these keys as passwords; a valid *arr API key is full control of that app.
They live only in `.env`, which is gitignored.

### D13. qBittorrent host-header validation is disabled; CSRF protection is not

qBittorrent 5.x validates the `Host` header on every request and rejects
anything unexpected with a bare `401` — including requests arriving through
Caddy, and requests to a remapped host port. Left on, any port other than 8080
is unusable — which is exactly how it is reached now that D25 stopped proxying
it and the only path is `<lan-ip>:<port>`.

`provision.sh` therefore sets `web_ui_host_header_validation_enabled=false`.

It deliberately leaves `web_ui_csrf_protection_enabled=true`. Testing confirmed
only the host-header check was blocking access, so CSRF protection costs nothing
to keep — and it is much the more valuable of the two here, since a valid
qBittorrent session is effectively a shell (spec §5.3).

The residual risk of disabling host-header validation is DNS rebinding.

That was originally mitigated by "the box is LAN- and tailnet-only with no port
forwarding", which **stopped being true in D25** — the router now forwards 80
and 443. The conclusion survives, but for a different reason, and it is worth
being explicit rather than leaving a stale justification in place: qBittorrent
has no public route, no public DNS record and no path through `DOCKER-USER`, so
there is no name an attacker can rebind that reaches it. A rebinding attack now
needs a browser already inside the LAN or the tunnel — the same position it
needed before.

### D14. SABnzbd runs alongside qBittorrent, not instead of it

The *arrs speak both protocols and choose per release. SABnzbd is given download
client priority 1 and qBittorrent 2, so Usenet wins where both have something —
it is faster, has better retention, and carries no seeding obligation.

qBittorrent is not redundant. **Usenet covers anime poorly**; Nyaa, SubsPlease
and AnimeTosho have vastly more, particularly for fansubbed and older
material. In practice Usenet carries TV and film while torrents carry anime,
which is precisely the library this build exists for.

Those public torrent indexers need no account, so `provision.sh` adds them by
default from `TORRENT_INDEXERS` and Prowlarr syncs them straight through to
Sonarr and Radarr. Use the `AnimeTosho` definition, not `Anime Tosho` —
Prowlarr ships both, and despite its private label the former needs no
credentials and validates, while the semiprivate one fails to connect.

Usenet downloads land in `/data/usenet/{incomplete,complete}`, a sibling of
`torrents/` and `media/` on the same filesystem, so imports from either
protocol hardlink identically. `scripts/test-hardlinks.sh` checks both trees.

Note the distinction that trips people up: an **indexer** (NZBgeek, NzbPlanet)
is a catalogue that hands over an `.nzb`, while a **provider** (Eweka) is the
news server holding the actual articles. They are separate subscriptions from
separate companies, and indexers alone download nothing. `provision.sh` warns
loudly when `USENET_USER` is blank rather than letting downloads fail silently.

### D15. SABnzbd's host whitelist has to be set, like qBittorrent's host header

SABnzbd rejects any request whose `Host` header is not in `host_whitelist` with
a bare `403`. The default contains only the container's own ID, so
`http://sabnzbd:8080` from Sonarr is refused and so is anything through Caddy —
the same class of failure as D13, and just as opaque.

`provision.sh` sets it to `sabnzbd,localhost,${ADMIN_HOST}`. This is a whitelist
rather than a blanket disable, so it is a tighter fix than the one qBittorrent
needed.

Updated by D25: the entry used to be `sab.${CADDY_DOMAIN}`, the proxy hostname.
SABnzbd is no longer proxied, so what has to be accepted is the bare LAN address
it is now reached at. Verified that SABnzbd accepts an IP in the `Host` header
without it being listed — a direct hit returns the login redirect, not a 403 —
but it is listed anyway rather than relying on that.

Unlike the *arrs, SABnzbd has no environment variable to pin its API key, so
`provision.sh` reads it back out of `sabnzbd.ini` instead of asking you to copy
it from the UI.

### D16. Jellyseerr is the household front door, not the *arr UIs

The request was a tiered navigation page so a non-technical household member
could find her way around. Interrogating it changed the answer.

Actual viewing happens through **Infuse on the Apple TV**, not a browser, so a
menu whose top entry is "Library → Jellyfin" signposts a door she will rarely
open. The only real browser journey is *"I want something we do not have"* —
which is exactly what Jellyseerr is for. She searches, clicks Request, and it
flows into Radarr and Sonarr with the profiles already configured, authenticated
with her existing Jellyfin account.

That means nobody but the administrator ever needs to see Sonarr or Radarr, and
the thing to teach collapses to two words: **Watch** and **Request**.

Jellyseerr touches no media files, only APIs, so it gets no `/data` mount and is
not counted in `validate.sh`'s media-service assertion.

### D17. The landing page is deliberately small, and has no container

Two tiles and a collapsed disclosure, not the three-tier drill-down originally
sketched. A nested menu would be more surface for a non-technical user to get
lost in, serving a journey she will not take. The six admin tools are present
behind `<details>` for the administrator and invisible by default.

It is static files mounted into the **Caddy container already running**
(`./caddy/site:/srv/site:ro`) and served at the bare `{$CADDY_DOMAIN}`, which
previously 404'd. No extra service, no image to keep patched, no API keys in the
browser, and it is versioned like everything else.

No framework: for eight links and some CSS transitions, a build step earns
nothing and costs a Node toolchain plus a question about whether `dist/` belongs
in git. There are also **no external requests at all** — icons are inline SVG and
fonts are system — so the page works over the tunnel with no internet.

Links are derived at runtime from `location.host`:

```js
el.href = `${location.protocol}//${el.dataset.sub}.${location.host}`;
```

One file therefore works at both the real domain and a dev hostname, port
included. A server-side template on the domain variable would lose the dev port,
since that variable carries no port.

Two later amendments: the variable is now `{$PUBLIC_DOMAIN}` (D25), and this
derivation applies to the **two public tiles only** — the admin chips point at
`<lan-ip>:<port>` and are rendered server-side, because nothing proxies them.

All of the above still holds. Two of its literal claims no longer do: there is
now a third file, `app.js`, and the page makes same-origin requests of its own
volition. Both are covered in **D24**, which supersedes the details without
disturbing the reasoning.

### D18. *arr authentication is pinned in the environment, credentials by API

The three *arrs previously relied on their first-run wizard, which meant a fresh
box served an account-creation screen on the LAN until a human got to it, and
nothing re-asserted the setting afterwards.

`AuthenticationMethod` and `AuthenticationRequired` are config-file elements, so
they map onto the same `SONARR__AUTH__*` mechanism already used for the API key:
`ARR_AUTH_METHOD` and `ARR_AUTH_REQUIRED` in `docker-compose.yml`. Environment
config is re-applied on **every container start**, which is the property that
matters — a UI flip to `DisabledForLocalAddresses` reverts on the next restart
instead of persisting silently.

Credentials cannot be pinned the same way; the *arrs keep them in their database
rather than `config.xml`. `provision.sh` sets them over
`PUT /api/vN/config/host`, which works before anyone has logged in only because
the API key is pinned ahead of first start (D12). That is the payoff D12 was
buying and had not been used for until now.

Verified on a fresh container with the env vars pinned and no credentials set:
`GET /` redirects to `/login`, empty credentials are rejected, `/loginsetup` is
unreachable, and `PUT /api/v3/config/host` returns 202 and the credentials take.
Also verified in the failure direction: with `DisabledForLocalAddresses`, `GET /`
returns 200 with no login. Note that the setting is applied at runtime and is
*not* written to `config.xml`, so `config.xml` disagrees with the running app —
`scripts/audit-auth.sh` reads the API, never the file.

### D19. UFW does not filter the container ports, so setup.sh writes DOCKER-USER rules

**Amended by D26.** The interface rule is now `-i wg0`. No rule is needed for
the WireGuard port itself: wg-easy uses host networking, so the tunnel is a host
listener that INPUT genuinely filters and it never reaches this chain — the one
place in this design where a port is *not* subject to the caveat below.

The stated boundary was "no router port forwarding, plus UFW denying inbound"
(D1, spec §5.3). The second half was not true. Docker publishes ports by DNAT in
`nat/PREROUTING`; the traffic then traverses `FORWARD`, never `INPUT`, which is
the chain UFW filters. Every service in this stack was therefore reachable from
any attached network while `ufw status` reported a default-deny firewall.

`setup.sh` now appends a guarded block to `/etc/ufw/after.rules` populating the
`DOCKER-USER` chain — which Docker leaves empty and evaluates first, precisely
for this — returning established traffic, loopback, `tailscale0` and
`$LAN_SUBNET`, and dropping everything else.

It is skipped with a warning when `LAN_SUBNET` is unset, because applying it
without one would cut the LAN off from Jellyfin and break Infuse on the Apple
TV, which is the primary playback path (D10).

This does not change the threat model, it makes the existing one true. The
absence of a port forward becomes the second line of defence rather than the
only one.

### D20. BIND_ADDR is required, not defaulted

It was `${BIND_ADDR:-0.0.0.0}`, which fails open: deleting the variable from
`.env` published the whole stack on every interface. It is now `${BIND_ADDR:?}`,
matching `CADDY_BIND_ADDR`, so the decision has to be made explicitly. The
recommended first-boot value is `127.0.0.1` until the Jellyfin and Jellyseerr
wizards are done — those two are the only first-run surfaces left that cannot be
closed from configuration.

### D21. Caddy keeps the tailscaled socket, for now

**Closed twice.** Resolved by D25, and moot again under D26 — there is no
tailscaled to hold a socket for. `validate.sh`'s assertion against it was
removed as unfalsifiable.

`/var/run/tailscale/tailscaled.sock` is mounted into Caddy so it can fetch
`*.ts.net` certificates (Q2). That socket is the tailnet control API, not a
cert-issuing endpoint, and Caddy in `caddy:alpine` runs as root — so a Caddy
compromise reaches the tailnet, not just the proxy. `:ro` on a socket restricts
nothing.

Accepted rather than fixed, because both alternatives needed a real tailnet to
validate and there wasn't one:

1. Run Caddy as a non-root user and set `TS_PERMIT_CERT_UID` on tailscaled.
2. Issue with `tailscale cert` on the host, mount the cert and key read-only,
   and add an explicit `tls` directive — no socket in the container at all.

**Resolved by D25 — a third way neither option anticipated.** The socket existed
only to fetch `*.ts.net` certificates. D25 stops using `.ts.net` names entirely,
so the mount is gone and the risk with it. Review finding S7 is closed.

Worth noting the timing: this became urgent rather than merely accepted the
moment Caddy started facing the internet. An accepted risk is a judgement about
a threat model, and the threat model changed. `validate.sh` now fails if any
service mounts that socket, so it cannot drift back in.

### D22. Config backups exist, and go on the media disk

`${CONFIG_ROOT}` holds every app database — watch history, requests, quality
profiles, indexer setup, user accounts. The media on `/mnt/disk1` is
re-acquirable; that state is not, and it sat on the same SSD as the OS with no
copy anywhere. D7 already said to back it up before pulling images and nothing
implemented it, which combined badly with `:latest` tags.

`scripts/backup-config.sh` triggers each *arr's own backup command first — they
checkpoint SQLite properly, and copying a database mid-write yields a file that
restores cleanly and is subtly corrupt — then tars `${CONFIG_ROOT}` to
`/mnt/disk1/backups` with retention. `setup.sh` installs a daily systemd timer
with `RequiresMountsFor`, so a missing mount stops the unit rather than quietly
filling the SSD with what is meant to be the off-SSD copy.

One disk is not an offsite backup. This protects against the SSD dying and
against a bad image pull, which are the two failures that actually happen.

### D23. Public torrent indexers cover more than anime

The defaults were `Nyaa.si, SubsPlease, AnimeTosho, Tokyo Toshokan` — all four
anime. That left every TV and film torrent search with no indexer at all, so the
entire non-anime library depended on the Eweka and NZBgeek subscriptions both
staying live, with no fallback for a lapsed subscription or for titles aged out
of Usenet retention.

Added `The Pirate Bay` and `YTS`. Dropped `Tokyo Toshokan`, which indexes
substantially the same sources as Nyaa.

`1337x` is the best general-purpose public tracker and is deliberately not in
the default set: it is behind CloudFlare, and Prowlarr rejects it on save with
"blocked by CloudFlare Protection". Verified — it fails at provisioning time,
which is the indexer validation working as intended rather than a silent
no-results indexer later. Using it needs a FlareSolverr container and a matching
Prowlarr indexer proxy, i.e. an always-on headless Chrome, so it is opt-in and
documented in `.env.example` rather than shipped.

### D24. The landing page gets the real service marks, design tokens, and reachability probes

A visual rebuild, retitled **The Thorby Media Server**. The information
architecture of D16 and D17 is untouched — two hero tiles, six tools collapsed
behind `<details>`. SvelteKit was raised and rejected: an icon library compiles
down to inlined SVG paths anyway, so a Node toolchain would have bought nothing
that the constraint in D17 does not already permit.

**A third file.** `app.js` does three things — build the links, probe what is
reachable, light the tile under the pointer. Past twenty lines an inline
`<script>` starts hiding behind markup. It is loaded as a plain synchronous
`<script>` at the end of `<body>`, not `defer`: the link derivation must run
before a tile is clickable, and `defer` would leave them at `href="#"` for a few
milliseconds after they are visible. Same timing as the inline block it replaces.

**The marks are the projects' own.** Sourced from `selfhst/icons`, which matters
for two reasons no other source offered: every icon is already
`viewBox="0 0 512 512"`, and every id and CSS class is already namespaced per
icon, so eight can share one document without collisions. Colours were
cross-checked against the logos read out of the running containers and match.
The apps themselves are a poor source — everything except qBittorrent is behind
the D18 auth wall over HTTP, and `docker exec` yields only five of eight, at five
different viewBoxes.

Two hand edits. Radarr's body is recoloured `#24292e` → `#fff`, reproducing
Radarr's own dark variant, because the plate behind it is dark in both themes.
Bazarr and SABnzbd each have paths that carried no `fill` and leaned on the SVG
default of black; that is now explicit, so a future `fill: currentColor` cannot
hijack them. The `<style>` blocks that two icons shipped with were inlined as
presentation attributes — document CSS does not reliably reach into a `<use>`
shadow tree, and a class-based fill would have silently dropped. Everything else
is byte-identical to upstream, verified by rendering both and comparing pixels.

The sprite has to be inline in `index.html` rather than a separate `icons.svg`:
Safari does not support `<use href="external.svg#id">`.

**One token the light theme does not remap.** `--plate`, the near-black square
behind every mark, stays dark in light mode. Sonarr's outer ring is `#eee` and
Radarr's body is white — on a light surface they would simply disappear. Holding
it constant also turns eight unrelated silhouettes into eight identical rounded
squares, which is most of what makes the set read as one page.

**The dots mean "answering", not "healthy".** A `no-cors` probe yields an opaque
response: the status code is unreadable, so resolution alone is the signal. A 401
login page, a 404, and Caddy's own 502 for a stopped container all resolve — so a
dead backend still shows green. What the probe does catch is a route that has
drifted out of `sites.caddy`, a client that has dropped off the VPN, and a
stale DNS answer. Reading the real status would need
`Access-Control-Allow-Origin` on all eight proxied admin UIs; adding a CORS
header to eight admin surfaces to improve a decorative dot is a bad trade, so it
was considered and rejected.

Three states, two appearances. "Up" is the only one with colour; "down" is drawn
exactly like "unknown", and the distinction lives in visually-hidden text. The
probe cannot tell a broken service from an untrusted certificate from a client
that is off the VPN, and a red dot on the household's home page would
generate a support call for a problem that does not exist. If every probe in a
group fails the dots are hidden outright — an instrument that is not working
should not report. (This bit hard on the old dev stack, where every probe failed
against the internal CA; on the target the certificates are real and the only
group that can legitimately go dark is Manage.)

**`validate.sh` now asserts D17 mechanically.** Four checks: no external `src`
or `href`, no CSS `url()` that is not a `data:` URI or a fragment, the
`data-sub` set equals the `sites.caddy` route set (spec §5.2 — a stale link
fails at TLS, not with a 404), and nothing but html/css/js under `caddy/site`.
The first is the one that matters, and it is why zero external requests is now
invariant 7 in `CLAUDE.md`: a CDN link renders perfectly for a client with
internet and breaks for one without, and a remote-access client is not
guaranteed a route out.

### D25. Two doors: a public one for the household, a VPN for the administrator

**The VPN is wg-easy, not Tailscale, as of D26.** The argument below is
unaffected — it turns on "a VPN puts you on the LAN", which is a property of any
VPN, and reads correctly with the names swapped.

The household needs to watch and request without installing anything, so
Jellyfin and Jellyseerr go on a real domain with the router forwarding 80 and
443. The six admin apps must not follow them there — spec §5.3 is right that
qBittorrent's completion program and SABnzbd's post-processing are arbitrary
command execution, and a session on either is a shell on a box holding 8 TB.

This reverses the "nothing is exposed" half of D1 and invariant 4. It does not
reverse §5.3, and the work here is making that difference mechanical.

**The simplification that made it small.** A VPN puts you on the LAN, and
`BIND_ADDR` already publishes every admin app there by IP and port. So remote
administration needs no proxy, no certificates and no hostnames — it needs
`http://<lan-ip>:8989` and a tailnet. Once that is accepted, the second Caddy
container this change originally called for disappears, and so does most of the
rest. The version with pretty admin hostnames was the complicated one.

**Three mechanisms, not one promise.** The six are excluded by having no route
in `sites.caddy`, no public DNS record, and no path through `DOCKER-USER`, which
returns only 80 and 443 from off-box. Any one would do. Having three means
adding a route by mistake does not expose anything, and `validate.sh` fails if
one of those six names appears in the routes file at all — including in a
comment, because a commented-out block is one keystroke from live.

**What `*.ts.net` never was.** The old design routed all nine apps at
`<sub>.<host>.ts.net`. MagicDNS gives a node exactly one name and does not
resolve subdomains of it, and `tailscale cert` only issues for a node's own
FQDN — so those eight names would very likely have resolved to nothing and
obtained no certificate. Never verified either way, because there was never a
tailnet; now moot, since nothing depends on them. Q1 and Q2 close with it.

**Certificates.** Let's Encrypt over HTTP-01, three names. That needs port 80
forwarded as well as 443, which is easy to forget and fails at issuance rather
than at request time. Not DNS-01 with a wildcard: that needs a provider plugin,
which means building a custom Caddy image, and nothing else here has a build
step.

**Hiding Manage is presentation, not access control.** Caddy tags requests from
RFC1918 and the Tailscale CGNAT range with a header, and the landing page
template renders the admin section only when it is present. Say it plainly
wherever it comes up: the boundary is the absent route, not the absent link.
The snippet originally lived in each Caddyfile rather than the shared routes
file because the dev box needed a wider range; with one environment it has moved
into `sites.caddy` alongside the routes that import it.

Admin links are `<lan-ip>:<port>`, templated from the environment rather than
written into the page, so `.env` stays the only place a host port is recorded.
`app.js` therefore derives hrefs for the two public tiles only, and guards its
`.manage` listener — that element is absent entirely for public clients, and an
unguarded `querySelector` would throw on the one page that must never look
broken.

**Admin UIs are plain HTTP.** Encrypted in transit by WireGuard; plaintext on
the LAN, which was already true under §5.1. TLS for names that
resolve only privately is exactly the complexity this decision removes.

**fail2ban watches Caddy, not Jellyfin.** Caddy's JSON access log is the only
one that records the true client address, so a jail on it can ban an attacker;
a jail on Jellyfin's log would ban Caddy's container IP and take the household
offline, unless Jellyfin's `KnownProxies` is set to the compose bridge first.
The Jellyfin jail is written but ships **disabled** for that reason.

### D26. wg-easy replaces Tailscale as the administrator's door

Self-hosted WireGuard, as a container in the stack, instead of a third-party
mesh with a hosted control plane. **D25's argument survives this unchanged** —
it says "a VPN puts you on the LAN, and `BIND_ADDR` already publishes every
admin app there", never "Tailscale specifically". Only the implementation moves.

**Host networking, and this is the load-bearing choice.** `wg-easy` runs with
`network_mode: host`, against upstream's reference compose, which puts it on a
bridge. Two things follow, and both are the reason:

1. *One address works everywhere.* `wg0` is a real host interface, so a packet
   from a peer arrives at the box's LAN address the same way a packet from the
   living room does. `http://<lan-ip>:8989` is one URL, at home and away.
2. *The firewall stays a rename.* `setup.sh` matched `-i tailscale0`; it now
   matches `-i wg0`. On a bridge there is no `wg0` on the host to match — peer
   traffic is masqueraded to the container's own bridge address — and D19's
   interface-scoped `DOCKER-USER` rule would have needed rethinking rather than
   editing.

The first point is not cosmetic. The landing page templates a single
`ADMIN_HOST` into every Manage link (`docker-compose.yml`, `index.html`), and
`validate.sh` forbids hardcoding a host in the page, so there is no clean way to
render one link for the LAN and another for the tunnel. One address has to work
from both, or the Manage section is wrong half the time.

**This was arguably broken under Tailscale.** For `<lan-ip>:<port>` to resolve
from the tailnet, the box needed `tailscale up --advertise-routes=<lan>` and
every client `--accept-routes`. Neither appears in `setup.sh`, spec §2.2, or the
README — so the Manage links would very likely have failed from outside the
house. Never observed either way, because there was never a tailnet. wg-easy
makes the equivalent explicit and server-side: `INIT_ALLOWED_IPS` is set once
and baked into every peer config it generates.

**Split tunnel.** `AllowedIPs` is the LAN subnet plus the WireGuard subnet, not
`0.0.0.0/0`. Ordinary browsing stays off the tunnel, which keeps it cheap enough
to leave always-on — and an always-on tunnel is what makes "the same address
works" true in practice rather than in principle. The cost is no exit-node
behaviour; that was never the requirement.

**Costs accepted.** Peer keys are now ours to manage, and there is no ACL layer
— `ufw allow in on wg0` is allow-all, exactly as the `tailscale0` rule was. A
peer is on the LAN. Against that: no third-party control plane, no dependency on
an account, and the box is no longer one vendor outage from being unreachable.

**`INSECURE=true`, deliberately.** v15 serves HTTPS with a self-signed
certificate and refuses plain HTTP without this. Plain HTTP matches the other
admin UIs and the reasoning is unchanged from D25: encrypted in transit by
WireGuard, plaintext on the LAN, which was already true under §5.1. A
certificate warning on every visit teaches the wrong reflex.

**No `SYS_MODULE`.** Upstream adds it so the container can `modprobe wireguard`.
It also lets a container load arbitrary kernel modules, which is a host
compromise primitive, and the module is in-tree on Debian 13. `setup.sh` loads
it at boot instead. `NET_ADMIN` is still required and is not negotiable.

**The one real regression against invariant 5.** v15 removed environment
configuration; `PASSWORD_HASH` is not merely ignored but *refuses to start the
container*, deliberately, so a v14 config cannot be silently carried across the
major version. Its replacement, `INIT_*`, applies **on first start only** and
then the credentials live in wg-easy's own database.

So unlike the *arrs — whose auth is re-applied from the environment on every
start, which is the whole point of D18 — wg-easy's authentication is *asserted
once and assumed thereafter*. That is a genuine weakening and is why
`audit-auth.sh` grew a wg-easy section: it probes the session endpoint for a
401 and, more importantly, checks the setup wizard is not open. An open wizard
means `/etc/wireguard` was lost and the next visitor becomes the VPN
administrator. `validate.sh` separately asserts no `PASSWORD`/`PASSWORD_HASH`
has been added, since every v14-era tutorial tells you to add one.

**Supersedes, in part:** D1 (the boundary is now no-port-forward *except* 80,
443 and the WireGuard port), D10, D13, D19 (`-i wg0`), D21 and Q1/Q2 (moot for a
second time — there is no hosted control plane left to hold a socket for), and
the Tailscale half of D25.

---

## Open

Each of these blocks or shapes a deliverable. Answers go here once settled.

### Q5. Anime: dual-audio or subtitle-only

§8 says to decide up front because it drives release-group preferences
significantly. The Recyclarr anime templates in
`config/recyclarr/recyclarr.yml` currently default to subtitle-preferred; going
dual-audio means adding the "Dual Audio" custom format with a positive score.

Not blocking — it can be set when the library is first populated.

---

## Closed

### Q2 → moot: no `.ts.net` names remain *(D25)*

Caddy 2.5+ recognises a `*.ts.net` site address and obtains the certificate from
the local Tailscale daemon with **no Caddyfile configuration at all**. The
production Caddyfile is therefore just `import sites.caddy`.

What it needs: `/var/run/tailscale/tailscaled.sock` mounted into the container
(done in `docker-compose.yml`), and **HTTPS Certificates plus MagicDNS enabled
for the tailnet in the Tailscale admin console** — without those no certificate
can be issued at all. If Caddy runs as non-root, tailscaled additionally needs
`TS_PERMIT_CERT_UID` set.

Fallback if the socket route misbehaves: `tailscale cert` on the host writing
key files, mounted read-only, with an explicit `tls <cert> <key>` per site.

**Still unverified** — there is no tailnet yet. Do not report certificates as
working until one has actually been served.

### Q3 → msmtp relaying to an SMTP server *(chosen)*

`setup.sh` installs `msmtp-mta` as the `sendmail` provider and writes
`/etc/msmtprc` (mode 0600) from the `SMTP_*` values in `.env`, so smartd's
native `-m` works. If `SMTP_HOST`/`ALERT_EMAIL` are unset the script skips the
step and warns loudly that alerts will not be delivered, rather than writing a
config that fails silently.

`ufw` was likewise absent from §2.1 but required by §5.3; both are now in
`setup.sh`'s package list.

### Q4 → Recyclarr ships in v1 *(chosen)*

Added as an eighth service with its config version-controlled at
`config/recyclarr/recyclarr.yml` and mounted read-only. API keys come from
`SONARR_API_KEY`/`RADARR_API_KEY` in `.env` via Recyclarr's `!env_var`, so the
config file stays committable.

### Q6 → `setup.sh` cannot format a non-blank disk *(resolved by design)*

The question is moot: formatting is opt-in via an explicit `--format-disk`, and
the script refuses any device carrying a filesystem or partition table, telling
the operator to run `wipefs` manually if they really mean it. Verified against
real loopback devices — it refuses a populated one and proceeds on a blank one.
Combined with `--dry-run`, the script cannot be the thing that destroys data.

### Q1 → moot: the tailnet hostname is never used *(D25)*

The Caddyfile needed the real `<host>` for `sonarr.<host>.ts.net`. Those routes
no longer exist — admin apps are reached at `<lan-ip>:<port>` over the tailnet,
which needs no hostname at all. Nothing in the repo now references a `.ts.net`
name, so there is nothing left to fill in.
