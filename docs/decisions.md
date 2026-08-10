# Implementation decisions

The spec (`spec.md`) settles *what* gets built. This file records the choices
made while implementing it that the spec leaves open, and the questions still
outstanding. Add to it rather than relitigating a decision in a code comment.

**Numbering, before the next merge.** `main` is at D39. The
`books-audiobooks-and-music` branch independently claims **D37–D45**, and its
D44 is the seerr migration that landed here as D37. That branch's nine decisions
and their internal cross-references need renumbering before it merges — git will
not flag it, because both files only ever append.

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
current versions; pinning digests here would mean hand-bumping a dozen images.
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

**Still true; the product is now called Seerr (D37).** The decision below is
left in its original words — every entry before D37 predates the rename, and
rewriting them would hide when the change actually happened.

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

Four later amendments: the variable is now `{$PUBLIC_DOMAIN}` (D25); since
**D31** even the two public tiles use `<lan-ip>:<port>` when the client is
local, so the derivation above is the fallback rather than the whole rule; the
admin chips were server-rendered `<lan-ip>:<port>` links until **D34** gave them
names, and now derive their href the same way the tiles do; and there are
**eight** admin tools behind the disclosure, not six — D26 added wg-easy and D30
added Cleanuparr, D29 added Lidarr and D38 took it away again.

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

**Amended by D26 and D28.** The interface rule is now `-i wg0`, and the chain
carries two further RETURNs for container-originated traffic. No rule is needed
for the WireGuard port itself: wg-easy uses host networking, so the tunnel is a
host listener that INPUT genuinely filters and it never reaches this chain — the
one place in this design where a port is *not* subject to the caveat below.

The stated boundary was "no router port forwarding, plus UFW denying inbound"
(D1, spec §5.3). The second half was not true. Docker publishes ports by DNAT in
`nat/PREROUTING`; the traffic then traverses `FORWARD`, never `INPUT`, which is
the chain UFW filters. Every service in this stack was therefore reachable from
any attached network while `ufw status` reported a default-deny firewall.

`setup.sh` now writes a guarded block into `/etc/ufw/after.rules` populating the
`DOCKER-USER` chain — which Docker leaves empty and evaluates first, precisely
for this — returning established traffic, loopback, the remote-access interface
(`tailscale0` when this was written, `wg0` since D26) and `$LAN_SUBNET`, and
dropping everything else. D28 adds the container bridges to that list and
explains why leaving them out was a defect rather than a tightening.

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

**Amended by D26, and by what shipping on a real domain turned out to mean.**
Four literal claims above have moved:

- There are **eight** admin chips and **ten** marks, not six and eight — D26
  added the wg-easy chip and D30 Cleanuparr; D29 added Lidarr and D38 removed
  it. Do not trust this sentence over the page: `validate.sh` asserts the chip
  set against `admin.caddy` precisely because a number in prose goes stale
  without anything failing. Two of the marks are now
  exceptions to "the marks are the projects' own": WireGuard's logo is a wordmark
  that does not survive being put on a 512-square plate, and Cleanuparr ships its
  only vector as a 71 KB traced bitmap. Both are hand-drawn, and both say so in
  a comment beside them.
- The `validate.sh` check compares the **tiles'** `data-sub` set against the
  routes in `sites.caddy`, not the whole page's. The admin chips carry a
  `data-sub` too; they are checked separately, against `admin.caddy` (D34).
- The CORS paragraph is moot twice over. Under D25 **no admin UI is proxied at
  all**, so there is nothing to put a header on, and the count was never eight.
- **The Manage dots cannot fire on the deployed page, and the reason is
  structural.** The landing page is served only at `PUBLIC_DOMAIN`, over HTTPS,
  while the chips point at `http://<lan-ip>:<port>` — nothing proxies them and no
  certificate exists for a private address. A `fetch` from an `https:` origin to
  an `http:` URL is blocked as active mixed content regardless of
  `mode: 'no-cors'`, so every probe rejects. The visible outcome was already
  right, by accident: the group reported unreliable and the dots hid themselves,
  which is what "an instrument that is not working should not report" asks for.
  `app.js` now skips the probe outright over HTTPS and hides the dots directly,
  so the console stays clean and the behaviour is chosen rather than emergent.
  The chips remain clickable — that is a navigation, not a subresource.

  Making them work would mean serving the page over plain HTTP somewhere, or
  issuing certificates for private addresses, or proxying the admin apps. The
  third is the one thing this design exists to refuse. The dots stay off.

  **D31 found a fourth way, and it only works for the hero tiles.** Those have a
  public HTTPS name as well as a LAN address, so when the tile's href moved to
  the LAN the probe could stay on the public name — navigation and probing became
  two URLs. The chips never had a second address, which is why this paragraph
  still describes them exactly. Read D31 for what the split costs.

### D25. Two doors: a public one for the household, a VPN for the administrator

**The VPN is wg-easy, not Tailscale, as of D26.** The argument below is
unaffected — it turns on "a VPN puts you on the LAN", which is a property of any
VPN, and reads correctly with the names swapped.

The household needs to watch and request without installing anything, so
Jellyfin and Jellyseerr go on a real domain with the router forwarding 80 and
443. The six admin apps must not follow them there — spec §5.3 is right that
qBittorrent's completion program and SABnzbd's post-processing are arbitrary
command execution, and a session on either is a shell on the box.

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

**What `*.ts.net` never was.** The old design routed every admin app at
`<sub>.<host>.ts.net`. MagicDNS gives a node exactly one name and does not
resolve subdomains of it, and `tailscale cert` only issues for a node's own
FQDN — so those names would very likely have resolved to nothing and obtained
no certificate. Never verified either way, because there was never a
tailnet; now moot, since nothing depends on them. Q1 and Q2 close with it.

**Certificates.** Let's Encrypt over HTTP-01, three names. That needs port 80
forwarded as well as 443, which is easy to forget and fails at issuance rather
than at request time. Not DNS-01 with a wildcard: that needs a provider plugin,
which means building a custom Caddy image, and nothing else here has a build
step.

**Hiding Manage is presentation, not access control.** Caddy tags requests from
the private ranges with a header, and the landing page template renders the
admin section only when it is present. Say it plainly wherever it comes up: the
boundary is the absent route, not the absent link.

Under D26 those ranges are the three RFC1918 blocks and nothing else — the
Tailscale CGNAT range this originally also matched is gone with Tailscale, and
`WG_SUBNET` defaults to `10.8.0.0/24` precisely so tunnel clients land inside
`10.0.0.0/8`. Choose a WireGuard subnet outside RFC1918 and the Manage section
silently stops rendering for exactly the clients that need it most; `validate.sh`
now cross-checks the two rather than leaving it to the comment in `sites.caddy`.
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

### D27. The media disk is a temporary 2 TB; rebuild on the swap

The 8 TB in §1's original hardware table was never bought. The build starts on a
2 TB drive while a 10 TB is saved for, and the plan when it arrives is to
**replace and rebuild from this repo**, not migrate in place.

That is the right trade only because of the §3.1 bind mount. `/data` is an
indirection over `/mnt/disk1`, so no container, no *arr root folder and no
Jellyfin library path contains a capacity assumption or a device name — the disk
is a mount, and swapping it is a mount-point change. Rebuilding is then cheaper
than a careful migration while the library is small enough to re-acquire, and it
also exercises `setup.sh` end to end a second time, which is worth having.

Documentation was updated to say 2 TB; **behaviour was deliberately not
changed.** In particular the Radarr profile stays on `UHD-2160p` at 15–30 GB a
film, which is roughly 65–130 films before the disk is full.

**What that leaves unguarded, stated plainly so it is not mistaken for an
oversight:** there is no SABnzbd `download_free`/`complete_free` floor, no
qBittorrent seed-ratio or seed-time limit, `preallocate_all` is on
(`provision.sh`), and there is no free-space alerting anywhere — `smartd` covers
drive health, not capacity. The disk can therefore fill silently, and the first
symptom will be imports failing. `df -h /data` is the manual control until the
10 TB lands.

Revisit if the 2 TB turns out to be in use for longer than a few months: a
free-space floor in SABnzbd and a seed-ratio limit in qBittorrent are the two
cheapest fixes and would both survive the swap.

### D28. The DOCKER-USER chain must let containers out, and the block is rewritten rather than skipped

Two defects in D19's implementation, found in review before the box was ever
brought up. Neither changes the design; both would have stopped it working.

**The DROP was not scoped to inbound.** The chain read: return established, `-i
wg0`, `-i lo`, `-s $LAN_SUBNET`, dports 80 and 443, then `-j DROP`. Its own
comment said "anything else reaching a container **from off-box**" — but
`DOCKER-USER` is jumped from the *top of `FORWARD`*, so it sees every forwarded
packet, and a container's own outbound SYN matches none of those RETURNs. Not
established (it is NEW), not `wg0` or `lo`, and not `$LAN_SUBNET` — the compose
bridge is `172.x`, the LAN is not. So it fell to the DROP.

The first casualty is DNS, which makes it total. Docker's embedded resolver
forwards upstream queries from inside the container's network namespace, so
those packets are forwarded traffic with a bridge source address on UDP/53.
Nothing resolves anything: no indexers, no Usenet provider, no metadata, and no
ACME — meaning **Caddy could never have obtained a certificate**, on a change
whose entire purpose was to put the box on a public domain.

The fix is two RETURNs above the DROP:

```
-A DOCKER-USER -i br+ -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -i docker0 -s 172.16.0.0/12 -j RETURN
```

Scoped by interface *and* source, because either alone is wrong in a different
direction: matching only the interface trusts a host bridge named `br0`, which
this box would have the day it ran a VM; matching only the source trusts a WAN
packet forging a bridge address. `172.16.0.0/12` is Docker's default address
pool — change `default-address-pools` in `/etc/docker/daemon.json` and these
must follow it.

Worth noting what this does *not* weaken. Inbound is untouched: a WAN packet
aimed at 8096 arrives on the external interface, matches neither new rule, and
still dies at the DROP. The three mechanisms of D25 are all intact.

**The block was write-once.** `setup.sh` returned early if the BEGIN marker was
already in `/etc/ufw/after.rules`, so once written it could never be corrected.
That is worse than it sounds given the documented order of operations: the
README had `setup.sh` running *before* `.env` was filled in, and `report()` ends
by telling you to re-run the script once `wg0` exists. A re-run added the `ufw
allow in on wg0` rule and silently left the firewall block stale — with the
wrong `LAN_SUBNET`, or without the 80/443 returns, while every message on screen
said the script had succeeded.

It now renders the block, compares it against what is between the markers, and
rewrites in place when they differ. Unchanged input is still a no-op, so the
marker appears exactly once however many times it runs — which is the property
`CLAUDE.md`'s rehearsal test asserts. The `--dry-run` path also prints the block
in full now, instead of a one-line summary: these are the highest-consequence
lines the script writes and a dry run is where they are supposed to be read.

**Two smaller things went in alongside.** `sysctl --system` moved outside the
`[[ -f $sysconf ]]` guard, since a first run that warned "written but not yet
active" was asking for a re-run that would then skip the retry. And the fail2ban
`caddy-auth` jail gained an `ignoreip` for loopback, `$LAN_SUBNET` and
`$WG_SUBNET`, plus `maxretry = 20`: it bans on any 401 or 403, Jellyfin and
Jellyseerr both emit those routinely on session expiry, and ten in ten minutes
is an ordinary evening on a flaky phone connection. Unfixed, the jail's first
victim would have been the household.

---

## D29. Lidarr, and music as a change of scope — **superseded by D38**

**Reversed in full.** Lidarr was removed and music left the scope again; this
entry stays because it is the record of what has to come back if the
books-and-music branch ships. Everything below still describes what Lidarr
needed — the v1 API, the root folder that wants two profile ids, the category
that has to exist on both download clients — and all of it will be true again.

The spec's first sentence said "TV, film, and anime". Adding Lidarr moves it, so
this is a scope change rather than another service — recorded here rather than
slipped in, because review finding A2 was precisely about a spec that had stopped
describing the build.

Mechanically it is the least interesting addition in the stack: another
LinuxServer *arr, `/data:/data` like the rest, auth pinned through
`LIDARR__AUTH__{APIKEY,METHOD,REQUIRED}` exactly as D12 and D18 describe, and
three new leaves on the §3.1 tree. Two details are not interchangeable with
Sonarr and Radarr and will waste an afternoon if assumed:

- **Its API is `v1`, not `v3`.** `provision.sh`'s `add_root_folder`,
  `upsert_download_client` and `ensure_hardlinks` all had `/api/v3/` written into
  them. They now take a version as a trailing argument defaulting to `v3`, so
  every existing call site is untouched and only Lidarr passes `v1`. A wrong
  version 404s loudly, which is why a default is acceptable here.
- **Its root folder needs more than a path.** `POST /api/v1/rootfolder` validates
  `name`, `defaultQualityProfileId` and `defaultMetadataProfileId`, and the two
  ids must reference rows that exist. Sonarr and Radarr accept `{"path": …}`
  alone. Neither id is stable — they depend on creation order — so the helper
  looks them up rather than assuming `1`.

Its download-client category field is `musicCategory` for both clients, which the
existing `qbit_fields`/`sab_fields` helpers already handle since they take the
field name as an argument. **The category itself has to exist on both clients**,
and that half was missed on the first pass: `provision.sh` still created only
`movies`, `tv` and `anime`. Neither client errors on a name it does not know —
qBittorrent creates the category implicitly with no save path and drops the
download in the default `/data/torrents`, SABnzbd falls back to the default
complete directory — so music would have landed outside its own subdirectory
while `torrents/music` and `usenet/complete/music` sat empty, with imports still
hardlinking correctly and nothing reporting a thing. Both loops now include
`music`.

**What music does not get, and why that is not a gap to fix.** Jellyseerr is a
film and TV product with no Lidarr support, so there is no household-facing
request path — D16's "the thing to teach collapses to two words" is unaffected,
because nobody but the administrator was ever going to add an artist. Recyclarr
has no Lidarr support either, so `config/recyclarr/recyclarr.yml` is unchanged
and Lidarr's quality profiles are whatever its defaults are until someone cares.
Bazarr has nothing to say about music.

**Capacity.** D27 has the library on a temporary 2 TB disk with the Radarr
profile at `UHD-2160p`, roughly 65–130 films before it is full. Music is small by
comparison — a large FLAC library is a few hundred gigabytes against a single
4K remux at 60 — so this is not what fills the disk. It does add one more thing
competing for it, and D27's "no free-space alerting anywhere" still stands.

---

## D30. Cleanuparr for download hygiene, and a second exception to invariant 5

D27 lists what the temporary disk leaves unguarded: no seed-ratio limit, no
free-space floor, no stalled-download handling, and nothing watching for
downloads that will never finish. Cleanuparr closes part of that — stalled and
blocked removal, failed-import handling, unlinked-download cleanup, and a malware
blocker that has no equivalent anywhere else in this stack.

**Over Declutterarr** because it is more actively maintained (v2.10.3 shipped a
week before this was written), supports more download clients, has a real
authentication system rather than none, and documents its API well enough to be
audited — which is what made the `audit-auth.sh` section below possible.

**It cleans qBittorrent only, and that matters more than it sounds.** There is no
SABnzbd support. D14 gives SABnzbd download-client priority 1 precisely because
Usenet is faster and carries no seeding obligation, so in practice it carries TV
and film while torrents carry anime and now music. Cleanuparr therefore covers
the *secondary* client and the larger half of the queue stays uncovered. That is
accepted rather than solved: SABnzbd manages its own queue and retries, and the
failure modes Cleanuparr exists for — a torrent seeding forever, a download
stalled at 99%, a file nothing links to — are torrent-shaped to begin with.

**Three deviations from house convention, each forced:**

1. **Not a LinuxServer image.** `CLAUDE.md` says not to substitute other
   maintainers' images. There is no LinuxServer build of Cleanuparr, so the
   choice is this image or not having it. Seerr and Recyclarr are the
   existing precedents. It implements `PUID`/`PGID`/`TZ`/`UMASK` itself, so the
   contract the convention exists to protect is intact.
2. **No pinnable API key or credentials.** Both are generated into its own SQLite
   database on first start. D12's mechanism — pin the key in `.env` so the
   provisioner can configure the app before anyone has logged in — simply does
   not apply, so `provision.sh` cannot touch it and Cleanuparr is configured by
   hand like Jellyfin's libraries.
3. **It mounts `/data` read-write.** Its unlinked-download cleaner counts
   hardlinks on the files themselves, which no API can do for it, so it needs the
   identical `/data:/data` mount invariant 1 requires. `validate.sh`'s
   `MEDIA_SERVICES` goes from six to seven — it was eight while Lidarr was in
   the stack (D38). Read-only was considered
   and rejected: the orphan-file cleaner deletes, and shipping a half-working
   configuration to buy a safety property is worse than shipping the destructive
   features switched off, which is what the setup step in spec §6 says to do.

**The authentication exception, which is the part worth carrying in your head.**
Invariant 5 says every app's auth is asserted, not assumed. Cleanuparr is the
second app that cannot honour that, for the same reason as wg-easy under D26:
there is no environment variable, so the account is created through a setup flow
and then lives in a database. Worse than wg-easy, in fact — wg-easy at least has
`INIT_*` on first start, and Cleanuparr has no equivalent at all. A wiped
`/config` comes back with an open setup wizard, and whoever reaches port 11011
first becomes the administrator. That is the same failure D12 and D18 protect the
*arrs from.

Two things make it tolerable. It is unreachable from the internet by the three
mechanisms in spec §5.3, like every other admin app. And its compensating control
is better than wg-easy's: `GET /api/auth/status` is deliberately anonymous — the
login page reads it to decide what to draw — and reports both `setupCompleted`
and `authBypassActive`, so `audit-auth.sh` can assert the two things that matter
without holding a credential.

**And it ships D18's trap under a new name.** The setting is "Disable Auth for
Local Addresses", and its built-in trusted ranges include `172.16.0.0/12` —
Docker's default address pool. Turning it on does not trust the LAN, it exempts
every container on the compose bridge. Verified from the source:
`TrustedNetworkAuthenticationHandler` returns `NoResult()` unless the setting is
on, so the default is safe; it is the helpful-looking toggle that is not. Never
enable it, for the same reason `DisabledForLocalAddresses` is never set on the
*arrs.

**On VPN day** Cleanuparr does not follow `QBIT_HOST`. It stores the download
client's host in its own database, so when qBittorrent moves onto Gluetun (§7)
its client entry has to be edited to `gluetun:8080` by hand. Nothing will report
that it has gone deaf. That step is now written into spec §7.

---

## D31. The landing page sends local clients to LAN addresses

The two public tiles derived their href from `location.host` (D17), so a client
sitting in the living room loaded `https://jellyfin.media.thorby.tech`, went out
to the router, and came back in through the WAN address. That depends on the
router hairpinning, and it routes LAN playback through the public path for no
benefit. Caddy already knows which clients are local — the `private_only` snippet
tags them for the Manage section — so the tiles now use the same tag and render
`http://<lan-ip>:<port>` for anyone inside.

**The header was renamed `X-Admin-Visible` -> `X-Local-Client`.** It now decides
two unrelated things, and a name describing only one of them is a name the next
person reasons wrongly from.

**Amendment: the header is stripped from public requests, not merely set for
private ones.** As first written — and as `X-Admin-Visible` was written before
it — `private_only` set the header for `@private` and did nothing otherwise, so
a client-supplied `X-Local-Client: 1` from the internet survived to `templates`
and rendered both branches: the Manage block, the admin marks, and
`data-lan` on the hero tiles.

That is a disclosure and not a way in. The admin apps still have no route in
this file, no public DNS record, and a `DOCKER-USER` drop; all three mechanisms
D25 relies on are untouched, and the sentence above about presentation-versus-control
remains exactly true. What a spoofed header hands out is `ADMIN_HOST`, the port
map and the service names — which is precisely what `index.html` gates the
sprite to withhold, so the intent was already there and the mechanism did not
match it. Off-network verification could never catch it either, because the
tester does not send the header.

The fix is a second, disjoint matcher:

```
@public not remote_ip 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
request_header @public -X-Local-Client
```

Disjoint rather than an unmatched `request_header -X-Local-Client` ahead of the
set, which would depend on how Caddy orders delete against set inside one header
handler. `remote_ip` needs no equivalent hardening: it reads the peer address
and ignores `X-Forwarded-For` unless told otherwise.

`validate.sh` asserts the strip is present and `verification.md` item 12 sends
the header deliberately.

**What was rejected.** `verification.md` item 11 already proposes the better fix
for the same problem: a DNS override on the router pointing the three public
names at `CADDY_BIND_ADDR`. It keeps TLS, keeps one set of bookmarks working at
home and away, needs no change to this repo at all, and the certificate still
validates because it is issued for the name and not the address. It was passed
over deliberately in favour of going direct to the container — one less hop, no
dependence on the router supporting DNS overrides — and the LAN-address version
is what is built. If the router does support overrides, doing both is coherent:
the tiles go direct and the domain still resolves indoors for anything that types
it.

**What it costs, stated plainly because nothing else will say it.**

- *No TLS on the LAN path.* Encrypted in transit over WireGuard, plaintext on the
  LAN — which D25 already accepted for the admin apps, now extended to the
  two the household uses.
- *The dot no longer attests to the link under it.* This is the real cost. A
  `fetch` from this `https:` page to an `http:` LAN address is blocked as active
  mixed content whatever `mode: 'no-cors'` says — the wall D24's amendment
  documents for the Manage chips, which is why those dots are hidden outright in
  production. Rather than let the hero dots go dark indoors, `app.js` carries
  navigation and probing as two separate URLs: `data-lan` for the href,
  `data-probe` for the fetch, the latter always the public name. So a wrong
  `ADMIN_HOST` or an unpublished port shows green.

  That is a genuine narrowing of the honesty D24 spent a page defending, taken
  with open eyes: the dot still means what it always meant — "this hostname is
  answering" — it just answers about the public route while the link takes the
  private one. What it still catches is unchanged: a route drifted out of
  `sites.caddy`, a client off the VPN, a stale DNS answer.

**Supersedes, in part:** D17's `location.host` derivation, which now describes
the fallback rather than the whole rule; D24's amendment on why the hero probes
work and the chip probes do not; and spec §2.2's claim that the page "has no way
to render a different link per network" — it does now, for private-versus-public,
though still not for LAN-versus-tunnel, which is why one `ADMIN_HOST` still has
to work from both.

---

## D32. The box as built departs from the spec in four places

Everything before this entry was written against a machine that did not exist
yet. Surveying the real one turned up four differences. None of them was a
mistake in the spec so much as an assumption the hardware declined to honour,
and each is recorded here because the spec still reads as though it were true.

**The uid is 1001, not 1000.** Debian gave 1000 to `nick` at install time.
`create_media_user` deliberately dies rather than bind the media tree to an
account it did not create, so the choice was to reuse `nick` or to move the
service user up. Moving it up is the better answer and not merely the compliant
one: PUID is what the containers run as, so with `PUID=1000` a container escape
would land *on the administrator's login*, sudo and all. At 1001 it lands on a
nologin account with no sudo, which is what a service user is for. The tree was
empty, so the re-chown cost nothing. `nick` joins the `media` group instead, and
`setup.sh` now does that automatically for `$SUDO_USER`.

The `${PUID:-1000}` fallbacks in `docker-compose.yml` and `init-tree.sh` were
left alone. They describe the ordinary case; `.env` supplies this box's.

**There is no Intel iGPU, and the GPU that is present cannot transcode.** The
i7-8700K has UHD 630, but nothing appears at PCI `00:02.0` — it is switched off
in the Z370's firmware. The only display adapter is a GTX 980 Ti, and `nouveau`
is what currently backs `/dev/dri/renderD128`. VAAPI against that device does
not transcode, so passing `/dev/dri` and setting `RENDER_GID` succeeds
completely and achieves nothing, which is exactly the kind of silent success
this repo tries to avoid.

The board has no display output of its own, so the 980 Ti has to stay. It does
not have to be the only one: `IGD Multi-Monitor` brings UHD 630 up headlessly as
a second render node while the discrete card keeps driving the screen. VAAPI
never needed a monitor. That is the fix, and it needs someone standing at the
machine, so the stack was deployed without it. **Until that BIOS change lands,
hardware transcoding is not working — `vainfo` is the only thing that settles
it, and it must be run against the Intel node specifically, identified by
`/sys/class/drm/*/device/vendor` reading `0x8086`.**

**Networking is WiFi.** `wlp10s0` holds 192.168.0.10; all three onboard Killer
E2500 ports are down for want of a cable, which arrives with the 10 TB disk.
Nothing in `.env` names an interface so nothing needed changing, but two
consequences are worth stating. The address is a DHCP lease, and a lease that
moves takes the port-forwards, `CADDY_BIND_ADDR`, `ADMIN_HOST` and `WG_UI_BIND`
with it — a router reservation is load-bearing, not tidiness. And every 4K remux
and every WireGuard byte crosses the wireless link until the cable is in.

**`/etc/fstab` carries `nofail` on both lines.** The spec's exact options are
`defaults,noatime` and `bind`; the box was mounted by hand before this repo
arrived and has `nofail` on each. It was kept. On a headless box in another
room, a disk that fails to mount should not also mean a machine that will not
boot — item 8 is about coming back up unattended.

The cost is real and unguarded: with `nofail`, a failed mount leaves `/data` as
an empty directory on the SSD and the containers cheerfully populate it, filling
the root filesystem instead of failing. What limits the damage is that the
underlying `/data` mountpoint is root-owned, so containers running as 1001
cannot write to it and error instead. That is a property of the directory, not a
check anything enforces — if someone ever `chown`s it while unmounted, the
protection disappears silently. `RequiresMountsFor=` on the backup unit covers
the backup path only.

---

## D33. One door, not two: the stack is VPN-only

D25 built two doors — a public one at `media.thorby.tech` for the household and
WireGuard for the administrator. The public one is closed. Nothing is forwarded
from the router except `WG_PORT`, and all three served names resolve to the
box's LAN address, so reaching Jellyfin from outside the house means bringing up
the tunnel first.

**What forced the question.** The domain turned out to be proxied through
Cloudflare rather than pointing at the WAN address, and unpicking that surfaced
four separate problems with the public door as designed. Universal SSL covers
one subdomain level, so `jellyfin.media.thorby.tech` — a third-level name — would
have thrown certificate errors. Every request would have arrived from a
Cloudflare address, so the `caddy-auth` jail would have banned Cloudflare rather
than an attacker, and Jellyfin would have seen one client. Proxying video is
against Cloudflare's terms in the first place. And HTTP-01 still needed port 80
open to the origin, so the proxy bought nothing it was being kept for.

Grey-clouding all four records would have fixed all four. The reason not to is
that it was never the requirement: the household watches at home, over the LAN,
through Infuse — a path that touches neither Caddy nor the internet. The public
door existed for watching *away* from home, and a tunnel does that too.

**What it costs.** Every household member needs a WireGuard peer on every device
they watch away from home on, and someone has to generate those. Jellyseerr
requests need the tunnel up. An Apple TV taken to another house needs the
WireGuard tvOS app. Against that: the attack surface reachable from the internet
is one UDP port that does not answer an unauthenticated probe.

**Why not Tailscale, again.** Reopening D26 was the obvious move, since MagicDNS
and automatic `*.ts.net` certificates would have solved naming and TLS for free
with no port forward at all. Two of D26's arguments got *stronger* under
VPN-only rather than weaker:

- *Relay fallback.* Tailscale hole-punches and falls back to DERP relays when it
  cannot. That is fine for the admin traffic D26 was sizing for and unusable for
  a 4K remux. A forwarded UDP port makes wg-easy always-direct. The port can be
  forwarded, so the guaranteed path is free.
- *Third party in the critical path.* Under two doors, a Tailscale outage cost
  the administrator their tools while the household kept watching. Under one
  door it costs everyone everything, including the television.

D26's LAN-routing objection also scales badly here: Tailscale only puts a peer
on the LAN if the box advertises routes *and* every client accepts them, and
under VPN-only that would have to be true on every household device rather than
just the administrator's.

**Certificates move to DNS-01.** With no inbound path, HTTP-01 cannot complete —
Let's Encrypt would knock on a port the router does not answer. DNS-01 needs no
inbound path, only a token that can write a TXT record. That requires the
Cloudflare provider module, and Caddy's modules are compiled in rather than
loaded at runtime, so `caddy/Dockerfile` now exists and Caddy is the one built
image in the stack. The Caddyfile's old comment cited "nothing else in this repo
has a build step" as the reason for choosing HTTP-01; that reasoning held while
port 80 was open and stopped holding when it closed.

Plain HTTP was the alternative, and defensible — D26 already accepted exactly
that for the admin UIs, reasoning that WireGuard encrypts the transit and the
LAN was plaintext anyway. Real certificates won because Jellyseerr has a login
form, browsers are getting steadily less tolerant of password fields on `http:`,
and the cost turned out to be one Dockerfile and one scoped token.

**Private addresses in public DNS.** The three names have real records in a
public zone pointing at `192.168.0.10`. That is deliberate: it needs no
split-horizon resolver, no `WG_DNS` pointing at something we run, and it
resolves identically on the LAN and over the tunnel. The address is useless to
anyone who resolves it from the internet. The one failure mode to know about is
resolvers that strip RFC1918 answers as DNS-rebinding protection — some home
routers do. If that ever bites, the fix is a resolver on the box pushed to peers
via `WG_DNS`, not a change to this decision.

**`PUBLIC_HTTP` is the switch, and it fails closed.** `setup.sh` opens 80/443
only when it is `true`, and when it is not, *deletes* those rules rather than
merely not adding them — the script is how the model gets changed, and a rule
surviving from a previous run is an opening that `ufw status` displays and
nobody reads. The `DOCKER-USER` port-80/443 RETURNs are gated on the same
variable.

**The structural exclusion of the admin apps from `sites.caddy` stays.** No route, no record,
no path through `DOCKER-USER`, and `validate.sh` still fails if one of those
names appears in `sites.caddy` at all. It protects nothing extra today, when
nothing is public. It is what keeps the model honest if `PUBLIC_HTTP` is ever
flipped back, which is exactly the moment nobody will re-derive it.

**Supersedes, in part:** D25's public half; D1's "except 80, 443 and the
WireGuard port", which is now just the WireGuard port; the Caddyfile's rejection
of DNS-01; and spec §5.3's exposure model. D26 is reaffirmed, not superseded.

---

## D34. The admin apps get names, behind a private-only guard

All of them are routed through Caddy now — `sonarr.media.thorby.tech` and the
rest,
on real certificates, in `caddy/conf/admin.caddy`. They were deliberately unrouted
for the whole life of this repo, so this is the entry to read before changing
anything about exposure.

**Why it became defensible.** D25's exclusion was three mechanisms deep: no
route, no DNS record, no path through `DOCKER-USER`. All three were defending
against a Caddy that answered the internet. D33 closed that door, so a route
here is unreachable from outside for as long as it stays closed.

**Why "for as long as it stays closed" is the whole risk.** Set `PUBLIC_HTTP` to
true, forward 80/443, and every one of those blocks would answer the internet —
including qBittorrent and SABnzbd, which are arbitrary command execution by
design, and Cleanuparr, which holds credentials for both. Pointing the records
at a private address does not help: that stops discovery, not a deliberate
request carrying a forged `Host`.

So the control moved into Caddy. Every block imports `admin_only`, which 403s
any client outside RFC1918 before the proxy runs. **One snippet now carries what
three independent mechanisms carried before.** That is a real downgrade, taken
knowingly, and it is mechanical rather than careful only because `validate.sh`
asserts three things: that no block in `admin.caddy` can exist without importing
the guard, that the guard's ranges equal `private_only`'s, and that the Manage
chips match the routes. `sites.caddy` is still forbidden from mentioning any of
those names, so which file a block lives in answers whether the internet could
ever reach it.

**Handler order is load-bearing.** `respond` sorts before `reverse_proxy` in
Caddy's directive order, so the 403 runs first. Verified on the target by
reading `caddy adapt` output rather than trusting the documentation, because if
that order ever inverted the guard would still be present, still be asserted by
`validate.sh`, and do nothing.

**What it bought, beyond names.** Three things fell out that were not the
motivation:

- *`BIND_ADDR` stays on loopback.* Caddy reaches every app over the compose
  bridge by container name, so no admin port is published on the LAN at all.
  D20's staged widening is not a stage any more, it is the destination, and
  `validate.sh`'s check was inverted to match. `DOCKER-USER` now defends an
  empty room, which is the right shape for it to be in.
- *The landing page reads no environment.* Ten port variables came off the caddy
  service; every link is built client-side from `data-sub` and the host that
  served the page.
- *D24's broken dots work.* D24 recorded that the Manage probes could never
  fire, because an https page cannot fetch `http://<lan-ip>:<port>` — blocked as
  active mixed content. With every link https on a real certificate, `href` and
  probe are the same URL again, and a dot attests to the link beneath it. D31's
  `data-lan` mechanism was removed for the same reason.

  **Amendment.** This was claimed here before it was true. Making the URLs match
  was necessary and not sufficient: `app.js` also carried an explicit guard that
  set `data-probes="unreliable"` on the admin group whenever the page was served
  over https, which hides the dots via CSS rather than merely skipping the
  fetch. That guard was correct under D31 and obsolete under D34, and removing
  it is what actually restored the dots. Noticed only because the dots were
  visibly missing on the deployed page — nothing in `validate.sh` covers
  behaviour that only exists at runtime, and the entry above asserted a result
  that had never been looked at.

**Two things it broke, both found by requesting all eleven names on the target
rather than by reading.** SABnzbd 403s any `Host` it has not been told about —
even `Host: sabnzbd` — so the proxy name went into `host_whitelist`. And wg-easy
runs with host networking, making it the one upstream Caddy cannot name by
container: its packet leaves the bridge with a 172.x source, hits the host's
INPUT chain, and default-deny drops it. `setup.sh` now permits Docker's pool to
`WG_UI_PORT` specifically.

That last rule narrows a claim spec §5.3 made. It said `ufw default deny
incoming` genuinely filters that port. It now filters it for everything except
containers on this box, so a compromised container can reach the wg-easy login
page it previously could not. It still has to get past a login `audit-auth.sh`
asserts is enforced, and a container that can already reach the *arr APIs is
past caring about this one.

**Supersedes, in part:** invariant 4's "no route" as the operative mechanism;
D20's staged `BIND_ADDR` widening; D31's `data-lan` override; and D24's
amendment that the Manage dots cannot fire.

---

## D35. Quick Sync is impossible on this board; an Arc A310 is the plan

The i7-8700K has UHD 630 and the spec is built around it — `/dev/dri`,
`RENDER_GID`, `group_add`, VAAPI in Jellyfin. None of it can be used here.

**The finding.** The MSI Z370 GODLIKE GAMING (MS-7A98) has **no display outputs
on the rear panel at all**, and MSI ships no Integrated Graphics Configuration
menu on such boards — there is no `IGD Multi-Monitor` setting anywhere in the
firmware. Walked the entire Advanced tree: PCI, ACPI, Integrated Peripherals,
USB, Power Management, Windows OS Configuration, Wake Up Events, Secure Erase+.
Corroborated from the box: nothing at PCI `00:02.0`, and the sole DRM device is
the GTX 980 Ti under `nouveau`.

So this is not a BIOS visit that was never made. It is a capability the board
does not expose.

**Why the 980 Ti is not the answer.** GM200 is Maxwell 2nd-gen: NVENC does
H.264 only, with **no HEVC encode and no HEVC hardware decode** — those arrived
on GM206, a smaller chip of the same generation. On a mostly-HEVC library it
would decode in software and encode to H.264, in exchange for taking on the
proprietary driver, `nvidia-container-toolkit`, and compose changes that
contradict the LinuxServer VAAPI design used everywhere else here.

**The plan is an Intel Arc A310**, and the reason it is the right answer is that
it changes nothing: it speaks VAAPI through `/dev/dri`, `RENDER_GID` stays 992,
`docker-compose.yml` already passes the device, and `setup.sh` already puts the
media user in `render`. It also has display outputs, so it replaces the 980 Ti
rather than joining it — dropping a 250 W card for roughly 75 W and unloading
nouveau.

**Deferred, not urgent, and the reason is in spec §4.2.** Infuse direct-plays
nearly everything, so at home the CPU is idle and transcoding is rarely invoked.
What changed is remote: under D33 everyone arrives over WireGuard, so remote
playback pulls the original bitrate unless Jellyfin transcodes down — and a 4K
remux is 60–80 Mbps against a residential uplink. Software transcoding a 4K HEVC
on six cores is roughly one stream. That is the pressure that will eventually
buy the card.

**Verification items 1 and 2 are marked N/A rather than pending**, and item 2
gained a check by PCI vendor. `/dev/dri/renderD128` exists today and is passed
into Jellyfin, so the obvious check *passes* while transcoding is impossible —
exactly the silent success that file exists to catch.

---

## D36. Docker must wait for an address, because network-online.target lies

The first real reboot took the stack down and nothing said so. Worth reading in
full, because every symptom pointed somewhere other than the cause.

**What happened.** `networking.service` finished 0.2 seconds into boot having
raised nothing — `/etc/network/interfaces` configures no interface on this box;
the WiFi is associated later by `wpa_supplicant` and addressed later still by
`dhcpcd`. `network-online.target` is satisfied by `networking.service` alone, so
it was reached almost immediately, and `docker.service`'s `After=` on it meant
nothing. From the journal:

```
12:12:48  networking.service Finished
12:12:50  dockerd starts wg-easy
12:12:53  wlp10s0 associated          <- three seconds too late
```

**Three failures, none of them loud:**

- **wg-easy** binds the single address in `WG_UI_BIND` and threw
  `EADDRNOTAVAIL`. Its web server died; `wg-quick` carried on and brought the
  tunnel up. The healthcheck was `wg show wg0`, which passed. So the container
  reported **healthy** for twenty-five minutes with no admin interface at all —
  and on a VPN-only box that is the remote front door.
- **Caddy** publishes `CADDY_BIND_ADDR:80` and `:443`. Docker could not create
  the bindings and left the container running without them: `docker compose ps`
  said `Up`, `docker port caddy` was empty, and every name in the house was
  dead. It never recovered, because `restart: unless-stopped` does not retry a
  container that is already running.
- **Container DNS** was broken until the daemon was restarted. Containers could
  reach `1.1.1.1` and the router directly, but the embedded resolver at
  `127.0.0.11` would not forward, so Caddy could not resolve `bazarr` and
  Jellyseerr's healthcheck spent its whole 5-second budget on a DNS timeout —
  which then made Jellyseerr *unhealthy*, which blocked Caddy's `depends_on`,
  which is why bringing it back by hand also failed at first.

That last chain is the thing to remember: one root cause produced a symptom
three services away, and the obvious reading of each symptom was wrong.

**The fix is to make the ordering true rather than to work around it.**
`setup.sh` writes a `docker.service` drop-in that waits for the address Caddy
and wg-easy bind, up to 60 seconds. It is deliberately non-fatal — if the
address never appears the daemon starts anyway, because a box that will not boot
is worse than one with a broken front door, and SSH is what you need then.

Enabling `ifupdown-wait-online.service` was the obvious alternative and does
nothing here: it waits for interfaces `ifupdown` manages, and `ifupdown` manages
none of them.

**The healthcheck was also wrong, independently.** wg-easy's now tests the web
UI as well as the tunnel. The two fail separately and the one that was checked
was the one that could not break. A healthcheck that cannot observe the failure
mode is worse than none, because it is read as evidence.

**Not changed, and worth saying why.** Binding `0.0.0.0` instead would make
`EADDRNOTAVAIL` impossible and was tempting. It was rejected because the wait
fixes all three failures rather than one, and because a specific bind is a
property `validate.sh` asserts and D26 reasons about; weakening it to work
around a boot race would have traded a real invariant for a symptom.

**Still unverified:** this was diagnosed and fixed after the reboot that
exposed it. Verification item 8 is the test, and it has not been re-run — a
graceful reboot exercises the same race, so it is worth doing before the power
cut.

---

## D37. Jellyseerr is now seerr, and `:latest` did not save us

`fallenbagel/jellyseerr:latest` was last pushed on **14 August 2025**. The
project was renamed to **seerr** and publishes `ghcr.io/seerr-team/seerr`,
updated daily. In between, release **v3.4.0** patched **GHSA-mc6w-69r3-62h8**, a
path traversal leading to remote code execution in the image proxy — reachable
from a malicious or compromised media-server response, or by a
man-in-the-middle where that connection is plain HTTP.

The box has been running the abandoned image for twelve months, on one of the
three household-facing names.

**This is D7's counter-example and belongs recorded against it.** The `:latest`
convention assumes the tag keeps moving, so that a security fix arrives with a
`compose pull`. It says nothing about a repository that stops being published
to. `:latest` did not go stale loudly; it went stale silently, which is the
failure signature this repo keeps finding.

Upstream migrates Overseerr and Jellyseerr data automatically on first start, so
there is no export step — take a backup first anyway, because "automatic" and
"reversible" are different words, and rehearse it against a *copy* of
`${CONFIG_ROOT}/jellyseerr` on a spare port before cutting over. The migration
is one-way once it has run.

**The service keeps the name `jellyseerr`** in `docker-compose.yml`, and so does
`${CONFIG_ROOT}/jellyseerr`. Renaming the directory would mean moving it on the
box by hand, and a missed `mv` produces a *fresh* seerr with an open setup
wizard — the D18 bootstrap hole, self-inflicted, on the household front door.
The container name is what Caddy proxies to and what `audit-auth.sh` probes;
none of that is worth a rename. The route was already `seerr.` and needs no
change. The landing page mark does change, because seerr's is a different logo.

**Two things about the image are not visible in the diff, and both bite.**

- It declares `USER node:node`, so it runs as **UID 1000** and no longer as
  root. `${CONFIG_ROOT}/jellyseerr` is root-owned from the old image, so it
  needs `chown -R 1000:1000` before the first start or the container dies on a
  permission denied. That is upstream's fixed UID, not `PUID` — 1000 is `nick`
  on this box rather than the `media` user, which reads oddly and is correct.
  Adding `user: "${PUID}:${PGID}"` to reconcile it with the rest of the stack is
  the tempting wrong answer: the image's own files are node-owned.
- It no longer ships an init process, hence **`init: true`**. Without it a
  crashed child is never reaped.

**The books-and-music branch made this change first** (as its D44) and made
neither of those two adjustments, because that branch is not deployed and never
hit a root-owned config directory. When it merges, this decision is the one that
holds.

---

## D38. Lidarr comes out, and music leaves the scope again

**Supersedes D29.** Lidarr does not work as well as Sonarr and Radarr, and the
things that would fix it — a Soulseek source, a music front end, a request path
— all live on `books-audiobooks-and-music` and are not ready. Running a fourth
*arr that reliably finds nothing is worse than not running it: it costs a
container, a route, a chip, an API key in `.env`, four checks in `audit-auth.sh`
and a database in the backup set, and returns a library nobody uses.

**This reverses D29 exactly**, which is why that decision is left in place rather
than deleted — it is the record of what has to come back.

- spec §1's scope sentence loses "and music". D29 explicitly framed moving that
  sentence as the point of the decision, so moving it back is the point of this
  one.
- The three `music` leaves come out of the §3.1 tree, and out of both copies of
  the list that creates it (`scripts/init-tree.sh` and `setup.sh`).
- `music` comes out of the qBittorrent and SABnzbd category loops in
  `provision.sh`.

**Nothing on disk is deleted.** `${CONFIG_ROOT}/lidarr` stays, the existing
`torrents/music`, `usenet/complete/music` and `media/music` directories stay
with whatever is in them, and the `music` categories already created on both
download clients stay — those loops only add. Re-adding Lidarr is a revert, not
a re-provision.

**The API-version plumbing in `provision.sh` stays, and that is deliberate.**
`add_root_folder`, `upsert_download_client` and `ensure_hardlinks` each take a
trailing `[api-version]` that defaults to `v3`, and `add_root_folder` keeps its
`v1` branch — the one that looks up a default quality *and* metadata profile
rather than assuming id 1. Nothing calls any of it today.

Deleting it is the trap. The books-and-music branch calls those same helpers
with `v1` for Chaptarr, which answers Readarr's API and needs exactly that
root-folder shape. Git would merge the removal here and the new call sites there
**cleanly** — they are different lines — and produce a script that silently
passes an ignored argument, requests `/api/v3/rootfolder` and 404s. That is the
"reported success for something that had not happened" shape that produced all
nine defects of the first deployment, pre-loaded into a merge.

**What this changes downstream.** `validate.sh`'s `MEDIA_SERVICES` goes from
eight to seven. `audit-auth.sh` audits ten apps rather than eleven. The stack is
twelve services, eleven certificates, eight admin chips. `backup-config.sh`
drops to three native *arr backups. The Manage grid was laid out for nine chips
in three columns; eight in three columns leaves an orphaned pair, so the track
floor moved to give four columns and two even rows.

**Recyclarr is unaffected** — D29 already recorded that it has no Lidarr
support, so `config/recyclarr/recyclarr.yml` never mentioned it.

**This is conditional, not final.** If `books-audiobooks-and-music` ships,
Lidarr ships with it.

---

## D39. Caddy's config is mounted as a directory, because a file mount goes stale

Found during the D37/D38 deployment, and it had been latent since the repo
existed. After `git pull` and `docker compose up -d`, Caddy was still serving a
route to a service that had just been deleted — `lidarr.<domain>` answering 502
rather than not existing. `caddy reload` did not fix it. The file on the host was
correct; the file **inside the container** still had the old contents.

**A bind mount of a single file binds the inode, not the path.** Compose had:

```yaml
- ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
- ./caddy/sites.caddy:/etc/caddy/sites.caddy:ro
- ./caddy/admin.caddy:/etc/caddy/admin.caddy:ro
```

`git` does not edit files in place — it writes a new file and renames it over
the old one, which is a new inode. The mount keeps pointing at the old one, for
the life of the container. Every subsequent pull was invisible to Caddy, and
`compose up -d` will not recreate a container whose *definition* has not changed
— the file contents are not part of that definition. Only `--force-recreate`
re-resolves it. The same trap applies to `vim`, `sed -i`, and anything else that
writes-and-renames, which is most things.

`caddy/site/` never had the problem because it was mounted as a **directory**,
and a directory mount resolves the path on every open. That is also what hid the
bug: the landing page updated correctly on every pull, so the mounts looked like
they worked.

The fix is to mount the directory. The three files moved to `caddy/conf/` and
compose mounts `./caddy/conf:/etc/caddy:ro`. `caddy/Dockerfile` stays where it
is — it is a build input, not config, and it is read by `docker build` on the
host rather than through any mount. Caddy looks for `/etc/caddy/Caddyfile` by
default and its `import` lines resolve relative to it, so nothing else changed.

**A reload is still required, and that is a different problem.** The directory
mount makes a pulled change *visible*; Caddy still only reads its config at
start. Nothing in the repo would have caught the gap, so `validate.sh` now
compares the hostnames the running Caddy serves — from its admin API on
`localhost:2019` — against `caddy adapt` of the file on disk. It compares the
host set rather than the whole document, because the running config carries
defaults that `adapt` does not emit and a full comparison would fail on a stack
that is perfectly in step. It skips when the stack is down, so this file stays
usable before anything has started.

**Why this is worth a decision rather than a fix in passing.** It is the exact
failure shape recorded against the first deployment: something reported success
for a thing that had not happened. The stack was healthy, every name answered,
`validate.sh` passed against the file on disk, and the route set being served was
a version nobody had looked at in a day. The thing that made it visible was
checking a route that should have *stopped* existing — which only happened
because this deployment removed one.

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
