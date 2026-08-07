#!/usr/bin/env bash
#
# Static validation. Runs unchanged on macOS and Debian, needs nothing running.
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
MEDIA_SERVICES='["bazarr","jellyfin","qbittorrent","radarr","sonarr"]'

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
echo "Caddy"

for cf in Caddyfile Caddyfile.dev; do
  if out=$(docker run --rm -e CADDY_DOMAIN=validate.example.ts.net \
             -v "$PWD/caddy:/etc/caddy:ro" caddy:alpine \
             caddy validate --config "/etc/caddy/$cf" 2>&1); then
    ok "caddy/$cf valid"
  else
    bad "caddy/$cf invalid"
    tail -5 <<<"$out" | indent
  fi
done

echo
echo "Shell"

shell_files=()
[[ -f setup.sh ]] && shell_files+=(setup.sh)
while IFS= read -r f; do shell_files+=("$f"); done \
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
