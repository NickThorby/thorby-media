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

The security boundary is: **no router port forwarding**, plus UFW denying
inbound except SSH and the Tailscale interface. Service ports bind normally so
the LAN can reach them. Only Caddy is restricted to the Tailscale interface,
because Caddy is the remote-access path.

Consequence: if this box is ever moved to an untrusted network, the model breaks.
The assumption is a trusted home LAN behind NAT.

### D2. Caddy binds to the tailnet IP via the port publish

`ports: - "${TAILSCALE_IP}:443:443"` rather than host networking or a bind
directive inside the Caddyfile. Docker's publish address is the simplest
enforcement point, it fails closed if `TAILSCALE_IP` is wrong (Caddy won't
start), and it keeps Caddy on the compose bridge network so it can reach the
other services by container name.

`TAILSCALE_IP` therefore lives in `.env` and is host-specific.

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
host-specific value — `PUID`, `PGID`, `TZ`, `RENDER_GID`, `TAILSCALE_IP`,
`TS_HOSTNAME`, `DATA_ROOT`, `CONFIG_ROOT` — comes from there.

### D6. Config root is `${CONFIG_ROOT}`, defaulting to `/opt/mediaserver`

Per §4, container configs live on the SSD, separate from the media disk. Kept as
a variable so the dev box can point it somewhere harmless.

### D7. Image tags: `:latest`

LinuxServer images are rolling releases and the *arr ecosystem assumes reasonably
current versions; pinning digests here would mean hand-bumping seven images.
Updates are a deliberate `docker compose pull && docker compose up -d`, not
automatic — no Watchtower. Back up `${CONFIG_ROOT}` before pulling.

Revisit if an unattended update ever breaks the stack.

### D8. Two compose files, with production as the default

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

Not a host bind mount. A named volume lives on ext4 inside Docker's Linux VM, so
inodes, link counts and PUID/PGID behave as they will on the target. macOS
VirtioFS has documented permission-mapping bugs and does not reproduce inode
semantics faithfully, which would make a local hardlink test result worthless —
and hardlinking is the invariant most likely to be silently wrong.

The cost is that `/data` is not browsable from Finder; use
`docker compose exec`. `scripts/init-tree.sh` creates the §3.1 tree inside it.

### D10. `LAN_SUBNET` reconciles §5.1 with §5.3

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
Caddy, and requests to a remapped host port. Left on, `qbit.<host>.ts.net` is
unusable and so is any port other than 8080.

`provision.sh` therefore sets `web_ui_host_header_validation_enabled=false`.

It deliberately leaves `web_ui_csrf_protection_enabled=true`. Testing confirmed
only the host-header check was blocking access, so CSRF protection costs nothing
to keep — and it is much the more valuable of the two here, since a valid
qBittorrent session is effectively a shell (spec §5.3).

The residual risk of disabling host-header validation is DNS rebinding, which is
mitigated by the box being LAN- and tailnet-only with no port forwarding.

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

`provision.sh` sets it to `sabnzbd,localhost,sab.${CADDY_DOMAIN}`. This is a
whitelist rather than a blanket disable, so it is a tighter fix than the one
qBittorrent needed.

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

It is static HTML and CSS mounted into the **Caddy container already running**
(`./caddy/site:/srv/site:ro`) and served at the bare `{$CADDY_DOMAIN}`, which
previously 404'd. No extra service, no image to keep patched, no API keys in the
browser, and it is versioned like everything else.

No framework: for eight links and some CSS transitions, a build step earns
nothing and costs a Node toolchain plus a question about whether `dist/` belongs
in git. There are also **no external requests at all** — icons are inline SVG and
fonts are system — so the page works over the tailnet with no internet.

Links are derived at runtime from `location.host`:

```js
el.href = `${location.protocol}//${el.dataset.sub}.${location.host}`;
```

One file therefore works at both `<host>.ts.net` and `localhost:8443`, port
included. A server-side template on `{$CADDY_DOMAIN}` would lose the dev port,
since that variable carries no port.

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

`/var/run/tailscale/tailscaled.sock` is mounted into Caddy so it can fetch
`*.ts.net` certificates (Q2). That socket is the tailnet control API, not a
cert-issuing endpoint, and Caddy in `caddy:alpine` runs as root — so a Caddy
compromise reaches the tailnet, not just the proxy. `:ro` on a socket restricts
nothing.

Accepted rather than fixed, because both alternatives need a real tailnet to
validate and there isn't one yet:

1. Run Caddy as a non-root user and set `TS_PERMIT_CERT_UID` on tailscaled.
2. Issue with `tailscale cert` on the host, mount the cert and key read-only,
   and add an explicit `tls` directive — no socket in the container at all.

Revisit when Q1 and Q2 are closed. Option 2 is the smaller blast radius.

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

---

## Open

Each of these blocks or shapes a deliverable. Answers go here once settled.

### Q1. Tailnet hostname

The Caddyfile needs the real `<host>` in `sonarr.<host>.ts.net`. Needs the
machine joined to the tailnet first (§2.2). Placeholder until then.

### Q5. Anime: dual-audio or subtitle-only

§8 says to decide up front because it drives release-group preferences
significantly. The Recyclarr anime templates in
`config/recyclarr/recyclarr.yml` currently default to subtitle-preferred; going
dual-audio means adding the "Dual Audio" custom format with a positive score.

Not blocking — it can be set when the library is first populated.

---

## Closed

### Q2 → Caddy fetches `*.ts.net` certs from tailscaled automatically *(D2, D11)*

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
