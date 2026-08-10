#!/usr/bin/env bash
#
# Static validation. Needs nothing running, but does need Docker and GNU
# coreutils — it is a Debian-target script like everything else here.
#
# Beyond syntax, this enforces the spec §4.1 volume rule mechanically: every
# media-touching service must mount the SAME source at the SAME container path
# /data. That rule is what makes hardlinking work, and violating it produces no
# error at runtime — imports just quietly start copying. A grep-able assertion
# is worth more here than a comment telling people to be careful.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Services that touch media and therefore must share /data. Prowlarr brokers
# indexers, Recyclarr and Seerr talk to APIs, Caddy proxies — none need the
# media tree. Cleanuparr does: its unlinked-download cleaner counts hardlinks on
# the files themselves, which it cannot do through an API (decisions.md D30).
MEDIA_SERVICES='["bazarr","cleanuparr","jellyfin","qbittorrent","radarr","sabnzbd","sonarr"]'

pass=0 fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  \033[33m–\033[0m %s\n' "$1"; }
indent() { while IFS= read -r line; do printf '      %s\n' "$line"; done; }

if [[ ! -f .env ]]; then
  echo "No .env found. Copy .env.example to .env first." >&2
  exit 1
fi

echo
echo "Compose"

if docker compose config -q 2>/dev/null; then
  ok "config parses and interpolates"
else
  bad "config failed to parse:"
  docker compose config -q 2>&1 | indent
  # Everything downstream reads the rendered config, so stop here.
  echo
  echo "$fail failed, $pass passed"
  exit 1
fi

rendered=$(docker compose config --format json)

# Which services mount something at /data — must be exactly the media set.
actual=$(jq -c '[.services | to_entries[]
                 | select((.value.volumes // []) | any(.target == "/data"))
                 | .key] | sort' <<<"$rendered")
if [[ "$actual" == "$MEDIA_SERVICES" ]]; then
  ok "exactly the media services mount /data"
else
  bad "wrong set of services mount /data"
  printf '      expected: %s\n      actual:   %s\n' "$MEDIA_SERVICES" "$actual"
fi

# All of those /data mounts must resolve to one source. Different sources means
# torrents/ and media/ can land on different filesystems and hardlinks break.
sources=$(jq -c '[.services[].volumes // [] | .[]
                  | select(.target == "/data") | .source] | unique' <<<"$rendered")
if [[ $(jq 'length' <<<"$sources") -eq 1 ]]; then
  ok "all /data mounts share one source: $(jq -r '.[0]' <<<"$sources")"
else
  bad "media services mount /data from different sources — hardlinks will break"
  printf '      %s\n' "$sources"
fi

# The container-side path must never be parameterised away from /data.
if jq -e '[.services[].volumes // [] | .[]
           | select(.target | test("^/(data|media|tv|movies|anime|downloads|torrents)$"))
           | select(.target != "/data")] | length == 0' <<<"$rendered" >/dev/null; then
  ok "no service remaps media to a non-/data container path"
else
  bad "a service mounts media somewhere other than /data (spec §4.1)"
fi

# Gluetun is deferred (spec §7) and must stay commented out. Note this is the
# OUTBOUND VPN client for qBittorrent's traffic, nothing to do with wg-easy,
# which is the inbound remote-access server and is expected to be present.
if jq -e '.services | has("gluetun") | not' <<<"$rendered" >/dev/null; then
  ok "gluetun still commented out"
else
  bad "gluetun is active — confirm a provider with port forwarding was chosen"
fi

# The remote-access door. Absent, and the eight admin apps are LAN-only with no
# way in from outside — which fails quietly, since the stack is otherwise fine.
if jq -e '.services | has("wg-easy")' <<<"$rendered" >/dev/null; then
  ok "wg-easy is present"
else
  bad "wg-easy is missing — there is no remote administration path"
fi

echo
echo "Exposure"

# Every published port must name an interface. A bare "8096:8096" publishes on
# 0.0.0.0 no matter what BIND_ADDR says, which is the one way to leak a service
# past the intended boundary without any file looking wrong.
unbound=$(jq -r '[.services | to_entries[] as $s
                  | ($s.value.ports // [])[]
                  | select((.host_ip // "") == "")
                  | "\($s.key):\(.published)"] | join(", ")' <<<"$rendered")
if [[ -z "$unbound" ]]; then
  ok "every published port names an interface"
else
  bad "published ports with no bind address (these land on 0.0.0.0)"
  printf '      %s\n' "$unbound"
fi

# Caddy is the internet-facing service. It must publish on the single LAN
# address the router forwards to, so that a bad router rule is the only way in
# rather than one of two. A wildcard here also removes the distinction between
# "forwarded" and "every interface this box ever joins".
caddy_ips=$(jq -r '[.services.caddy.ports // [] | .[] | .host_ip // ""] | unique | join(", ")' <<<"$rendered")
if [[ "$caddy_ips" == *"0.0.0.0"* || "$caddy_ips" == *"::"* ]]; then
  bad "caddy publishes on $caddy_ips — it must bind one LAN address, not a wildcard"
  printf '      %s\n' "CADDY_BIND_ADDR should be the address the router forwards 80/443 to."
else
  ok "caddy binds to $caddy_ips, not a wildcard"
fi

# wg-easy runs with host networking, so it has no `ports:` and slips past the
# check above entirely. Its UI bind address is the equivalent control, and the
# equivalent mistake: a wildcard puts the VPN admin panel on every interface the
# box ever joins. Unlike a Docker publish this one is at least filtered by UFW,
# but that is defence in depth, not a reason to bind wide (decisions.md D26).
wg_host=$(jq -r '.services["wg-easy"].environment.HOST // ""' <<<"$rendered")
if [[ -z "$wg_host" ]]; then
  bad "wg-easy does not set HOST — the UI would bind 0.0.0.0"
  printf '      %s\n' "Set WG_UI_BIND in .env to this box's LAN address."
elif [[ "$wg_host" == "0.0.0.0" || "$wg_host" == "::" || "$wg_host" == "*" ]]; then
  bad "wg-easy binds its UI to $wg_host — it must be one LAN address"
else
  ok "wg-easy binds its UI to $wg_host, not a wildcard"
fi

# This check used to run the other way round: everything the landing page linked
# to unproxied pointed at ADMIN_HOST:<port>, so BIND_ADDR had to be ADMIN_HOST or
# a wildcard, and loopback was a state you were meant to leave.
#
# D34 inverted it. Every app is reached through Caddy on a name now, and Caddy
# reaches them over the compose bridge by container name, so a published host
# port buys nothing. Loopback is the end state, not a stage — and it is the
# quieter one: with 127.0.0.1 there is no admin port on the LAN at all, so
# DOCKER-USER is defending an empty room.
#
# Still a warning and not a failure, because a wider BIND_ADDR is a defensible
# choice rather than a mistake: it leaves <lan-ip>:<port> working as break-glass
# if Caddy itself is down. An SSH tunnel does the same job without the exposure,
# which is why it is not the default.
admin_host=$(jq -r '.services.caddy.environment.ADMIN_HOST // ""' <<<"$rendered")
svc_ips=$(jq -r '[.services | to_entries[] | select(.key != "caddy")
                  | (.value.ports // [])[] | .host_ip // ""] | unique | .[]' <<<"$rendered")
if [[ -z "$admin_host" ]]; then
  bad "ADMIN_HOST is unset — caddy/admin.caddy needs it to reach the wg-easy UI"
elif ! grep -qvxE '127\.0\.0\.1|::1' <<<"$svc_ips"; then
  ok "services publish on loopback only — no admin port is exposed on the LAN"
else
  skip "BIND_ADDR ($(tr '\n' ' ' <<<"$svc_ips" | sed 's/ $//')) is wider than loopback"
  printf '      %s\n' \
    "Every app is reachable by name through Caddy, so nothing needs a host port" \
    "on the LAN. This is not wrong — it keeps <lan-ip>:<port> as break-glass if" \
    "Caddy is down — but an SSH tunnel does that without the listeners."
fi

# The wg-easy chip is the same link with a different backing: host networking,
# so WG_UI_BIND is what has to match rather than BIND_ADDR.
if [[ -n "$admin_host" && -n "$wg_host" && "$wg_host" != "$admin_host" ]]; then
  skip "wg-easy binds $wg_host but its chip points at $admin_host"
  printf '      %s\n' "WG_UI_BIND and ADMIN_HOST are normally the same LAN address."
fi

# wg-easy v15 refuses to start if either of these is present — deliberately, so
# a v14 configuration cannot be silently carried across a major upgrade. Every
# v14-era tutorial tells you to set one, so assert they are absent rather than
# discovering it as a container that will not come up.
legacy=$(jq -r '[.services["wg-easy"].environment // {} | keys[]
                 | select(. == "PASSWORD" or . == "PASSWORD_HASH")] | join(", ")' <<<"$rendered")
if [[ -z "$legacy" ]]; then
  ok "wg-easy sets no v14 password variables"
else
  bad "wg-easy sets $legacy — v15 refuses to start with these"
  printf '      %s\n' "Use INIT_USERNAME / INIT_PASSWORD instead (decisions.md D26)."
fi

# The tunnel subnet has to fall inside the ranges caddy/sites.caddy treats as
# private, or the landing page stops rendering Manage for tunnel clients — the
# one group that most needs it. Nothing else couples these two files, and the
# symptom (a page that looks right from the sofa and wrong from the airport)
# points nowhere near either of them.
wg_cidr=$(jq -r '.services["wg-easy"].environment.INIT_IPV4_CIDR // ""' <<<"$rendered")
priv_line=$(grep -m1 '@private remote_ip' caddy/sites.caddy || true)
if [[ "$priv_line" != *"10.0.0.0/8"*   ||
      "$priv_line" != *"172.16.0.0/12"* ||
      "$priv_line" != *"192.168.0.0/16"* ]]; then
  skip "private_only lists non-default ranges — check WG_SUBNET against them by hand"
else
  case "${wg_cidr%%/*}" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      ok "WG_SUBNET ($wg_cidr) is inside the private_only ranges" ;;
    *)
      bad "WG_SUBNET ($wg_cidr) is outside caddy/sites.caddy's private_only ranges"
      printf '      %s\n' "Manage will not render for tunnel clients. Add the range to the" \
                          "@private matcher in caddy/sites.caddy, or move WG_SUBNET into RFC1918." ;;
  esac
fi

# A placeholder domain reaches Caddy as a real one: it starts, asks Let's Encrypt
# for a certificate it can never validate, and burns the five-failures-per-hour
# budget for the name you actually meant to use.
pub=$(jq -r '.services.caddy.environment.PUBLIC_DOMAIN // ""' <<<"$rendered")
case "$pub" in
  ""|*CHANGEME*|example.com|*.example.com|*.example.net|*.example.org|*.invalid|*.test|*.localhost)
    bad "PUBLIC_DOMAIN is \"$pub\" — a placeholder, not a name that can be issued for"
    printf '      %s\n' "Set it to the real domain in .env before starting Caddy." ;;
  *)
    ok "PUBLIC_DOMAIN ($pub) is not a placeholder" ;;
esac

# The *arr auth settings are the difference between a login prompt and an
# anonymous admin session, and deleting them looks like tidying up. Verified:
# with AUTH__REQUIRED unset to DisabledForLocalAddresses, GET / returns 200.
for svc in sonarr radarr prowlarr; do
  prefix=$(tr '[:lower:]' '[:upper:]' <<<"$svc")
  if jq -e --arg m "${prefix}__AUTH__METHOD" --arg r "${prefix}__AUTH__REQUIRED" --arg s "$svc" \
       '.services[$s].environment | has($m) and has($r)' <<<"$rendered" >/dev/null; then
    ok "$svc pins its authentication method and scope"
  else
    bad "$svc is missing ${prefix}__AUTH__METHOD / __REQUIRED"
    printf '      %s\n' "Without these the app falls back to its first-run wizard."
  fi
done

# .env holds every password in the stack plus the Usenet provider account.
env_mode=$(stat -c '%a' .env)
if [[ "$env_mode" == "600" ]]; then
  ok ".env is mode 0600"
else
  bad ".env is mode $env_mode — it holds every password in the stack"
  printf '      %s\n' "chmod 600 .env"
fi

echo
echo "Caddy"

# Validated against the image this stack actually runs, not stock caddy:alpine.
# `acme_dns cloudflare` only parses in a binary with that module compiled in, so
# the stock image would report a syntax error in a file that is correct. Docker's
# layer cache makes the build a no-op unless caddy/Dockerfile changed.
#
# The placeholder token has to be shaped like a real one. The Cloudflare module
# format-checks it while provisioning, before any API call, so an obviously fake
# string fails validation on a Caddyfile that is perfectly good. Forty
# characters from the charset it accepts; it is never sent anywhere.
if ! out=$(docker build -q -t mediaserver/caddy:latest ./caddy 2>&1); then
  bad "caddy image failed to build from caddy/Dockerfile"
  tail -5 <<<"$out" | indent
elif out=$(docker run --rm -e PUBLIC_DOMAIN=validate.example.com \
           -e ACME_EMAIL=validate@example.com \
           -e CF_API_TOKEN=0123456789abcdefghijklmnopqrstuvwxyzABCD \
           -v "$PWD/caddy:/etc/caddy:ro" mediaserver/caddy:latest \
           caddy validate --config /etc/caddy/Caddyfile 2>&1); then
  ok "caddy/Caddyfile valid (sites.caddy imported, cloudflare module present)"
else
  bad "caddy/Caddyfile invalid"
  tail -5 <<<"$out" | indent
fi

echo
echo "Landing page"

# Invariant 7. A CDN link or a webfont here renders perfectly for a client with
# internet, and breaks for one without — a tunnel client on a split tunnel is
# not guaranteed a route out. That is a silent failure in front of the
# household, so it gets an assertion (D17, D24).
#
# Scoped to things the browser FETCHES — every src=, and href= on a <link>. An
# <a href> is a place the user can go, not a request the page makes, and the
# admin chips legitimately point at http://<lan-ip>:<port>. That those stay
# templated rather than hardcoded is a separate check below.
if out=$(grep -rEn 'src="(https?:)?//|<link[^>]+href="(https?:)?//' caddy/site); then
  bad "landing page fetches an external subresource"
  indent <<<"$out"
else
  ok "landing page fetches nothing external"
fi

# Same rule, CSS side. Allowed: data: URIs (the favicon, the grain filter) and
# fragment references — which appear percent-encoded as %23 when they sit inside
# a data: URI, as the favicon's gradient reference does.
if out=$(grep -rEn 'url\([^)]*\)|@import' caddy/site | grep -Ev "url\((\"|')?(data:|#|%23)"); then
  bad "landing page CSS fetches something"
  indent <<<"$out"
else
  ok "landing page CSS uses only data: URIs"
fi

# The two hero tiles are the only links that are proxied, and they and the
# routes are the same names kept in two files. Nothing notices when they drift —
# a stale link fails at TLS, not with a 404.
# Same `|| true` reasoning as below: with pipefail, a grep that matches nothing
# fails the pipeline and aborts the run rather than reporting an empty set.
tiles=$(sed -n '/<nav class="tiles"/,/<\/nav>/p' caddy/site/index.html \
        | { grep -oE 'data-sub="[a-z]+"' || true; } | sed -E 's/.*"(.*)"/\1/' | sort -u)
# shellcheck disable=SC2016  # {$PUBLIC_DOMAIN} is Caddy's literal placeholder, not a shell expansion
routes=$({ grep -oE '^[a-z]+\.\{\$PUBLIC_DOMAIN\}' caddy/sites.caddy || true; } | sed -E 's/\..*//' | sort -u)
if [[ "$tiles" == "$routes" ]]; then
  ok "landing page tiles match the proxied routes"
else
  bad "landing page tiles and sites.caddy routes disagree"
  printf '      only on the page:  %s\n' "$(comm -23 <(echo "$tiles") <(echo "$routes") | tr '\n' ' ')"
  printf '      only in caddy:     %s\n' "$(comm -13 <(echo "$tiles") <(echo "$routes") | tr '\n' ' ')"
fi

# The whole point of D25. qBittorrent runs an external program on completion and
# SABnzbd runs post-processing scripts, so a public route to either is a shell
# on the box. They are excluded structurally — by not being routed — and this is
# what keeps it that way when someone adds a block "just to test something".
#
# Cleanuparr is on this list for the same reason at one remove: it holds a
# qBittorrent credential and every *arr API key, so a session on it reaches the
# same command execution by proxy (decisions.md D30).
if out=$(grep -nEi 'sonarr|radarr|prowlarr|bazarr|qbittorrent|sabnzbd|cleanuparr|\bqbit\b|\bsab\b' caddy/sites.caddy \
         | grep -vE '^[0-9]+:\s*#'); then
  bad "an admin service appears in caddy/sites.caddy — it must not be routed there"
  indent <<<"$out"
else
  ok "no admin service is routed in sites.caddy"
fi

# D34 moved the admin apps behind Caddy, so "there is no route" stopped being
# the control and `admin_only` became it. One snippet now carries what three
# independent mechanisms carried before, which is only acceptable while it is
# impossible to add a block here without it. That is this check.
# shellcheck disable=SC2016  # {$PUBLIC_DOMAIN} is Caddy's literal placeholder
admin_routes=$({ grep -oE '^[a-z]+\.\{\$PUBLIC_DOMAIN\}' caddy/admin.caddy || true; } \
               | sed -E 's/\..*//' | sort -u)
# shellcheck disable=SC2016  # {$PUBLIC_DOMAIN} is Caddy's literal placeholder
admin_blocks=$(grep -cE '^[a-z]+\.\{\$PUBLIC_DOMAIN\} \{' caddy/admin.caddy || true)
admin_guards=$(grep -cE '^[[:space:]]*import admin_only[[:space:]]*$' caddy/admin.caddy || true)
if [[ "$admin_blocks" -gt 0 && "$admin_blocks" == "$admin_guards" ]]; then
  ok "all $admin_blocks admin routes import admin_only"
else
  bad "admin.caddy has $admin_blocks route(s) but $admin_guards import admin_only"
  printf '      every block in that file must import it, or it answers the internet\n'
  printf '      the moment PUBLIC_HTTP is set true\n'
fi

# The guard is only as good as its ranges, and there are two copies of them —
# here and in private_only. Narrowing one alone leaves tunnel clients matching
# neither: locked out of the admin apps by this list, and losing the Manage
# block by the other, with nothing to connect the two symptoms.
admin_ranges=$(grep -m1 '@offnet not remote_ip' caddy/admin.caddy \
               | sed -E 's/.*remote_ip //' | tr -s ' ' || true)
priv_ranges=$(grep -m1 '@private remote_ip' caddy/sites.caddy \
              | sed -E 's/.*remote_ip //' | tr -s ' ' || true)
if [[ -n "$admin_ranges" && "$admin_ranges" == "$priv_ranges" ]]; then
  ok "admin_only and private_only agree on the private ranges"
else
  bad "admin_only and private_only disagree on which addresses are private"
  printf '      admin.caddy:  %s\n' "${admin_ranges:-<none found>}"
  printf '      sites.caddy:  %s\n' "${priv_ranges:-<none found>}"
fi

# Same drift check the tiles get above, for the Manage chips. A chip whose
# subdomain has no route fails at TLS rather than with a 404, which reads like
# a certificate problem and sends you to the wrong place entirely.
chips=$(sed -n '/class="manage"/,/<\/details>/p' caddy/site/index.html \
        | { grep -oE 'data-sub="[a-z]+"' || true; } | sed -E 's/.*"(.*)"/\1/' | sort -u)
if [[ "$chips" == "$admin_routes" ]]; then
  ok "Manage chips match the admin routes"
else
  bad "Manage chips and admin.caddy routes disagree"
  printf '      only on the page:  %s\n' "$(comm -23 <(echo "$chips") <(echo "$admin_routes") | tr '\n' ' ')"
  printf '      only in caddy:     %s\n' "$(comm -13 <(echo "$chips") <(echo "$admin_routes") | tr '\n' ' ')"
fi

# Without `templates` the {{if}} in index.html renders as literal text AND the
# admin block renders with it — the failure is visible but it is still a leak of
# the internal hostnames to the public page.
# `|| true` on both: grep -c prints 0 but exits 1 when nothing matches, and
# under `set -e` that aborts the whole run — so the check meant to catch a
# missing `templates` would silently kill validate.sh instead of failing it.
site_blocks=$(grep -c 'root \* /srv/site' caddy/sites.caddy || true)
tmpl_blocks=$(grep -c '^[[:space:]]*templates[[:space:]]*$' caddy/sites.caddy || true)
if [[ "$site_blocks" -gt 0 && "$site_blocks" -eq "$tmpl_blocks" ]]; then
  ok "every block serving /srv/site enables templates"
else
  bad "$site_blocks block(s) serve /srv/site but $tmpl_blocks enable templates"
  printf '      %s\n' "Without templates the {{if}} leaks as text and Manage renders publicly."
fi

# X-Local-Client decides what the page renders, and `templates` reads it off the
# request as it arrived. Set it for @private and nothing else, and a client from
# the internet supplying its own header keeps it — Manage and the admin sprite
# render for anyone who sends one line. Not a route to the apps, but it hands
# out ADMIN_HOST and the port map, which is the disclosure the sprite is gated
# to prevent. The strip is what closes it and it is one deletion from being
# gone again (decisions.md D31).
if grep -qE '^[[:space:]]*request_header @public -X-Local-Client[[:space:]]*$' caddy/sites.caddy; then
  ok "sites.caddy strips a client-supplied X-Local-Client"
else
  bad "sites.caddy does not strip X-Local-Client for public clients"
  printf '      %s\n' "A request from the internet can set it itself and render Manage." \
                      "Add '@public not remote_ip ...' and 'request_header @public -X-Local-Client'."
fi

# .env is the single source of truth for a host port. A literal address or port
# in the page is a second one, and the two drift silently.
#
# data-lan is checked alongside href because D31 made it a second place an
# address can be written — the hero tiles' LAN override. It is not an href, so
# the original pattern walked straight past it.
if out=$(grep -nE '(href|data-lan)="https?://[^"{]' caddy/site/index.html); then
  bad "landing page hardcodes a host — links must come from {{env}}"
  indent <<<"$out"
else
  ok "landing page takes its hosts and ports from the environment"
fi

# Every {{env}} the page reads has to be handed to the Caddy container, or it
# expands to the empty string and renders http://10.0.0.5: as a live link —
# a broken link, not an error. This is the one failure mode of D31 that looks
# like nothing at all.
missing=""
mapfile -t page_envs < <(grep -oE '\{\{env "[A-Z_]+"\}\}' caddy/site/index.html \
                         | sed -E 's/.*"(.*)".*/\1/' | sort -u)
for var in ${page_envs[@]+"${page_envs[@]}"}; do
  jq -e --arg v "$var" '.services.caddy.environment | has($v)' <<<"$rendered" >/dev/null \
    || missing+=" $var"
done
if [[ -z "$missing" ]]; then
  ok "every {{env}} the page reads is set on the caddy service (${#page_envs[@]})"
else
  bad "the page reads {{env}} names the caddy service does not set:$missing"
  printf '      %s\n' "Caddy expands an unset name to '', rendering http://host: as a link."
fi

# nosniff is set on this site, so a file Caddy types wrongly is a blank page
# rather than a warning. Anything that is not html/css/js is almost certainly
# a stray — a screenshot variant left behind, an editor backup.
stray=$(find caddy/site -type f ! -name '*.html' ! -name '*.css' ! -name '*.js' | tr '\n' ' ')
if [[ -z "$stray" ]]; then
  ok "caddy/site holds only html, css and js"
else
  bad "unexpected file types under caddy/site: $stray"
fi

echo
echo "Shell"

shell_files=()
[[ -f setup.sh ]] && shell_files+=(setup.sh)
mapfile -t -O "${#shell_files[@]}" shell_files \
  < <(find scripts -name '*.sh' -type f 2>/dev/null | sort)

if [[ ${#shell_files[@]} -eq 0 ]]; then
  skip "no shell scripts found"
else
  if out=$(docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable \
             "${shell_files[@]}" 2>&1); then
    ok "shellcheck clean (${#shell_files[@]} files)"
  else
    bad "shellcheck findings"
    indent <<<"$out"
  fi
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
else
  printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
fi
echo
exit $(( fail > 0 ? 1 : 0 ))
