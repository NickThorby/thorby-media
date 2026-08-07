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

---

## Open

Each of these blocks or shapes a deliverable. Answers go here once settled.

### Q1. Tailnet hostname

The Caddyfile needs the real `<host>` in `sonarr.<host>.ts.net`. Needs the
machine joined to the tailnet first (§2.2). Placeholder until then.

### Q2. How Caddy obtains TLS certs for `*.ts.net`

Two workable approaches, not yet chosen or tested:

- **Caddy's Tailscale integration** — Caddy asks tailscaled for the cert. Needs
  `/var/run/tailscale/tailscaled.sock` mounted into the container.
- **`tailscale cert` on the host** — writes cert and key to disk on a timer;
  Caddy reads them read-only via `tls <cert> <key>`.

Either way, **HTTPS Certificates and MagicDNS must be enabled for the tailnet in
the Tailscale admin console** or no cert can be issued at all. Verify that
first. Do not assert which mechanism is in use until one has actually served a
valid cert.

### Q3. smartd has no mail transport

§3.5 requires email alerts on attribute failure, but the package list in §2.1
contains no MTA — `smartd`'s `-m` directive shells out to `/usr/sbin/sendmail`,
which does not exist on a minimal Debian install. Alerts would fail silently,
which is the exact failure mode the requirement exists to prevent.

Options: `msmtp-mta` with an SMTP relay (simplest), a local `postfix` in
satellite mode, or replace email with a webhook via `-M exec`. Needs a decision
plus a destination address before `setup.sh` can implement §3.5 honestly.

Related: `ufw` is likewise absent from §2.1 but required by §5.3. Both go into
`setup.sh`'s package list.

### Q4. Recyclarr

§8 strongly recommends it for maintained anime quality profiles, but it is
absent from the §4 service table and the §9 deliverables. Add it as an eighth
container (it runs on a schedule and writes to the *arr APIs), or leave it out
of v1 and hand-tune?

### Q5. Anime: dual-audio or subtitle-only

§8 says to decide up front because it drives release-group preferences
significantly. This determines the quality profile, and — if Q4 lands on
Recyclarr — which template gets synced.

### Q6. Media disk state

Is the 8 TB drive blank, or does it already hold data? `setup.sh` formatting a
populated disk is unrecoverable, so the script must refuse to `mkfs` anything it
did not create and the answer must be confirmed before it is run.
