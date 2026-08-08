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
# indexers, Recyclarr talks to APIs, Caddy proxies — none need the media tree.
MEDIA_SERVICES='["bazarr","jellyfin","qbittorrent","radarr","sabnzbd","sonarr"]'

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

# Gluetun is deferred (spec §7) and must stay commented out.
if jq -e '.services | has("gluetun") | not' <<<"$rendered" >/dev/null; then
  ok "gluetun still commented out"
else
  bad "gluetun is active — confirm a provider with port forwarding was chosen"
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

# The socket is the tailnet control API, not a cert endpoint, and Caddy runs as
# root. It existed only to fetch *.ts.net certificates; those are gone, and
# Caddy now faces the internet. Re-adding it would reinstate S7 against a much
# worse threat model (decisions.md D21, D25).
sock=$(jq -r '[.services | to_entries[] as $s | ($s.value.volumes // [])[]
               | select((.source // "") | test("tailscaled.sock"))
               | $s.key] | unique | join(", ")' <<<"$rendered")
if [[ -z "$sock" ]]; then
  ok "no service mounts tailscaled.sock"
else
  bad "tailscaled.sock is mounted into: $sock"
  printf '      %s\n' "An internet-facing container must not hold the tailnet control API."
fi

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

if out=$(docker run --rm -e PUBLIC_DOMAIN=validate.example.com \
           -e ACME_EMAIL=validate@example.com \
           -v "$PWD/caddy:/etc/caddy:ro" caddy:alpine \
           caddy validate --config /etc/caddy/Caddyfile 2>&1); then
  ok "caddy/Caddyfile valid (sites.caddy imported)"
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
if out=$(grep -nEi 'sonarr|radarr|prowlarr|bazarr|qbittorrent|sabnzbd|\bqbit\b|\bsab\b' caddy/sites.caddy \
         | grep -vE '^[0-9]+:\s*#'); then
  bad "an admin service appears in caddy/sites.caddy — it must not be routed"
  indent <<<"$out"
else
  ok "no admin service is routed through Caddy"
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

# .env is the single source of truth for a host port. A literal address or port
# in the page is a second one, and the two drift silently.
if out=$(grep -nE 'href="https?://[^"{]' caddy/site/index.html); then
  bad "landing page hardcodes a host — admin links must come from {{env}}"
  indent <<<"$out"
else
  ok "landing page takes its admin host and ports from the environment"
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
