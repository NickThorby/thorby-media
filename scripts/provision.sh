#!/usr/bin/env bash
#
# Wires the stack together over the apps' REST APIs — steps 1 to 6 of the
# configuration sequence in README.md, which is the fiddly, error-prone part.
#
# Idempotent: every resource is checked before it is created, so re-running is
# safe and is how you apply a changed .env.
#
# This works because the API keys are pinned in .env and passed to the *arrs as
# environment variables, so they are known before the containers ever start.
# Without that there is a chicken-and-egg problem — you cannot call the API
# until the app has generated a key, and it only does that on first run.
#
# Usage:
#   ./scripts/provision.sh              configure everything
#   ./scripts/provision.sh --init-keys  generate missing keys into .env, then exit
#
# What it does NOT do, and why:
#   - Indexers. Public ones could be scripted, but private trackers need your
#     own credentials. Add them in Prowlarr; they sync to the *arrs from there.
#   - Bazarr. Its API is far weaker than the others and its config is a file.
#   - Jellyfin libraries. The setup wizard is a one-off, three-minute job.
#   - Quality profiles. That is Recyclarr's job, declaratively.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31mError:\033[0m %s\n\n' "$1" >&2; exit 1; }

[[ -f .env ]] || die "No .env found. Copy .env.example to .env first."

# ─── Key generation ──────────────────────────────────────────────────────────

if [[ "${1:-}" == "--init-keys" ]]; then
  step "Generating API keys"
  added=0
  for var in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY; do
    if grep -qE "^${var}=.+" .env; then
      skip "$var already set"
    else
      printf '%s=%s\n' "$var" "$(openssl rand -hex 16)" >> .env
      ok "generated $var"
      added=1
    fi
  done
  if grep -qE '^QBIT_PASS=.+' .env; then
    skip "QBIT_PASS already set"
  else
    printf 'QBIT_PASS=%s\n' "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)" >> .env
    ok "generated QBIT_PASS"
    added=1
  fi
  echo
  if [[ $added -eq 1 ]]; then
    echo "  Keys were appended to .env. The *arrs read them at startup, so:"
    echo "    docker compose up -d && ./scripts/provision.sh"
  fi
  echo
  exit 0
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

for var in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY QBIT_PASS; do
  [[ -n "${!var:-}" ]] || die "$var is not set in .env. Run: ./scripts/provision.sh --init-keys"
done

QBIT_USER=${QBIT_USER:-admin}
SONARR_URL="http://127.0.0.1:${SONARR_PORT:-8989}"
RADARR_URL="http://127.0.0.1:${RADARR_PORT:-7878}"
PROWLARR_URL="http://127.0.0.1:${PROWLARR_PORT:-9696}"

# ─── HTTP helpers ────────────────────────────────────────────────────────────

# arr <method> <base-url> <api-key> <path> [json-body]
arr() {
  local method=$1 base=$2 key=$3 path=$4 body=${5:-}
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
         -d "$body" "${base}${path}"
  else
    curl -fsS -X "$method" -H "X-Api-Key: $key" "${base}${path}"
  fi
}

# qBittorrent is driven from inside its own container. qBittorrent 5.x validates
# the Host header on every request, so calls from the host to a remapped port
# (or through Caddy) are rejected with 401 until that validation is turned off —
# which is itself one of the things this script fixes. Going through the
# container sidesteps the bootstrap ordering entirely and does not care what
# BIND_ADDR or the published port happen to be.
qbt() {
  docker compose exec -T qbittorrent \
    curl -fsS -b /tmp/qbt.cookies "$@"
}

wait_for() {
  local name=$1 url=$2 key=$3
  curl -fsS -o /dev/null --max-time 120 --retry 30 --retry-delay 2 \
       --retry-all-errors --retry-connrefused \
       -H "X-Api-Key: $key" "$url" \
    || die "$name did not become ready at $url. Is the stack up?"
}

# ─── qBittorrent ─────────────────────────────────────────────────────────────

provision_qbittorrent() {
  step "qBittorrent"

  docker compose ps --status running --services | grep -qx qbittorrent \
    || die "qbittorrent is not running. Start the stack: docker compose up -d"

  # Log in with the permanent password if it is already set, otherwise fall back
  # to the temporary one qBittorrent prints to its log on every start until a
  # permanent password exists.
  if docker compose exec -T -e U="$QBIT_USER" -e P="$QBIT_PASS" qbittorrent sh -c \
       'curl -fsS -c /tmp/qbt.cookies -o /dev/null -X POST \
          --data-urlencode "username=$U" --data-urlencode "password=$P" \
          http://localhost:8080/api/v2/auth/login' 2>/dev/null; then
    ok "authenticated with the password from .env"
  else
    local tmp
    tmp=$(docker compose logs qbittorrent 2>&1 \
          | grep -o 'temporary password is provided for this session: .*' \
          | tail -1 | awk '{print $NF}' | tr -d '\r')
    [[ -n "$tmp" ]] || die "Cannot log in to qBittorrent and no temporary password found in its log.
       If the password was changed by hand, put it in QBIT_PASS in .env."

    docker compose exec -T -e P="$tmp" qbittorrent sh -c \
      'curl -fsS -c /tmp/qbt.cookies -o /dev/null -X POST \
         --data-urlencode "username=admin" --data-urlencode "password=$P" \
         http://localhost:8080/api/v2/auth/login' \
      || die "Login with the temporary password failed. Try: docker compose restart qbittorrent"
    ok "authenticated with the temporary password"
  fi

  # web_ui_host_header_validation_enabled=false is required for qBittorrent to
  # be reachable through Caddy or on a remapped host port — with it on, every
  # login is rejected with 401. CSRF protection deliberately stays ON: it is the
  # more valuable of the two here, since a qBittorrent session is effectively a
  # shell (spec §5.3).
  #
  # temp_path sits inside /data/torrents so incomplete downloads stay on the
  # same filesystem as the finished ones (spec §6 step 1).
  #
  # autorun stays empty — "run external program on completion" is arbitrary
  # command execution by design.
  qbt -X POST http://localhost:8080/api/v2/app/setPreferences \
    --data-urlencode "json={
      \"web_ui_password\": \"${QBIT_PASS}\",
      \"web_ui_host_header_validation_enabled\": false,
      \"web_ui_csrf_protection_enabled\": true,
      \"save_path\": \"/data/torrents\",
      \"temp_path_enabled\": true,
      \"temp_path\": \"/data/torrents/incomplete\",
      \"preallocate_all\": true,
      \"autorun_enabled\": false,
      \"autorun_program\": \"\"
    }" >/dev/null
  ok "preferences set (password, save paths, preallocation, host-header validation off)"

  # Categories map to save paths under /data/torrents/ (spec §6 step 1).
  local existing cat
  existing=$(qbt http://localhost:8080/api/v2/torrents/categories)
  for cat in movies tv anime; do
    if jq -e --arg c "$cat" 'has($c)' <<<"$existing" >/dev/null 2>&1; then
      skip "category '$cat' exists"
    else
      qbt -X POST http://localhost:8080/api/v2/torrents/createCategory \
        --data-urlencode "category=${cat}" \
        --data-urlencode "savePath=/data/torrents/${cat}" >/dev/null
      ok "created category '$cat' -> /data/torrents/${cat}"
    fi
  done
}

# ─── Root folders ────────────────────────────────────────────────────────────

add_root_folder() {
  local app=$1 url=$2 key=$3 path=$4
  if arr GET "$url" "$key" /api/v3/rootfolder | jq -e --arg p "$path" 'any(.[]; .path == $p)' >/dev/null; then
    skip "$app root folder $path exists"
  else
    arr POST "$url" "$key" /api/v3/rootfolder "{\"path\":\"$path\"}" >/dev/null
    ok "$app root folder $path"
  fi
}

# ─── Download client ─────────────────────────────────────────────────────────

add_download_client() {
  local app=$1 url=$2 key=$3 category_field=$4 category=$5

  if arr GET "$url" "$key" /api/v3/downloadclient | jq -e 'any(.[]; .name == "qBittorrent")' >/dev/null; then
    skip "$app download client exists"
    return
  fi

  # host is the container name, not localhost: the *arr reaches qBittorrent
  # across the compose bridge network, not via a published port.
  local body
  body=$(jq -n \
    --arg user "$QBIT_USER" --arg pass "$QBIT_PASS" \
    --arg cf "$category_field" --arg cat "$category" \
    '{
      enable: true,
      protocol: "torrent",
      priority: 1,
      removeCompletedDownloads: true,
      removeFailedDownloads: true,
      name: "qBittorrent",
      implementation: "QBittorrent",
      configContract: "QBittorrentSettings",
      fields: [
        {name: "host",     value: "qbittorrent"},
        {name: "port",     value: 8080},
        {name: "useSsl",   value: false},
        {name: "username", value: $user},
        {name: "password", value: $pass},
        {name: $cf,        value: $cat}
      ]
    }')
  arr POST "$url" "$key" /api/v3/downloadclient "$body" >/dev/null
  ok "$app download client -> qbittorrent:8080, category '$category'"
}

# ─── Hardlinks ───────────────────────────────────────────────────────────────

ensure_hardlinks() {
  local app=$1 url=$2 key=$3 current updated
  current=$(arr GET "$url" "$key" /api/v3/config/mediamanagement)
  if [[ $(jq -r '.copyUsingHardlinks' <<<"$current") == "true" ]]; then
    skip "$app already uses hardlinks instead of copy"
  else
    updated=$(jq '.copyUsingHardlinks = true' <<<"$current")
    arr PUT "$url" "$key" /api/v3/config/mediamanagement "$updated" >/dev/null
    ok "$app set to hardlink instead of copy"
  fi
}

# ─── Prowlarr application links ──────────────────────────────────────────────

add_prowlarr_app() {
  local name=$1 impl=$2 contract=$3 app_url=$4 app_key=$5

  if arr GET "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/applications \
     | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
    skip "Prowlarr -> $name link exists"
    return
  fi

  local body
  body=$(jq -n \
    --arg name "$name" --arg impl "$impl" --arg contract "$contract" \
    --arg appurl "$app_url" --arg appkey "$app_key" \
    '{
      name: $name,
      implementation: $impl,
      configContract: $contract,
      syncLevel: "fullSync",
      fields: [
        {name: "prowlarrUrl", value: "http://prowlarr:9696"},
        {name: "baseUrl",     value: $appurl},
        {name: "apiKey",      value: $appkey}
      ]
    }')
  arr POST "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/applications "$body" >/dev/null
  ok "Prowlarr -> $name (indexers now sync automatically)"
}

# ─── Main ────────────────────────────────────────────────────────────────────

step "Waiting for services"
wait_for Sonarr   "$SONARR_URL/api/v3/system/status"   "$SONARR_API_KEY";   ok "Sonarr ready"
wait_for Radarr   "$RADARR_URL/api/v3/system/status"   "$RADARR_API_KEY";   ok "Radarr ready"
wait_for Prowlarr "$PROWLARR_URL/api/v1/system/status" "$PROWLARR_API_KEY"; ok "Prowlarr ready"

provision_qbittorrent

step "Sonarr"
add_root_folder Sonarr "$SONARR_URL" "$SONARR_API_KEY" /data/media/tv
add_root_folder Sonarr "$SONARR_URL" "$SONARR_API_KEY" /data/media/anime
# Sonarr has a single category field, so anime downloads land in the 'tv'
# category too. Harmless: it is the same filesystem, and the TV/anime split
# that matters happens at the root folder and Jellyfin library level.
add_download_client Sonarr "$SONARR_URL" "$SONARR_API_KEY" tvCategory tv
ensure_hardlinks Sonarr "$SONARR_URL" "$SONARR_API_KEY"

step "Radarr"
add_root_folder Radarr "$RADARR_URL" "$RADARR_API_KEY" /data/media/movies
add_download_client Radarr "$RADARR_URL" "$RADARR_API_KEY" movieCategory movies
ensure_hardlinks Radarr "$RADARR_URL" "$RADARR_API_KEY"

step "Prowlarr"
add_prowlarr_app Sonarr Sonarr SonarrSettings "http://sonarr:8989" "$SONARR_API_KEY"
add_prowlarr_app Radarr Radarr RadarrSettings "http://radarr:7878" "$RADARR_API_KEY"

step "Left for you"
printf '  %s\n' \
  "Prowlarr: add indexers — including Nyaa.si, AnimeTosho and SubsPlease," \
  "          without which Sonarr will find no anime at all." \
  "Bazarr:   connect to Sonarr and Radarr, choose subtitle providers." \
  "Jellyfin: create three libraries — /data/media/{movies,tv,anime}," \
  "          anime as its own library, and enable VAAPI on the target." \
  "Recyclarr: docker compose exec recyclarr recyclarr sync"
echo
ok "Provisioning complete. Verify with: ./scripts/test-hardlinks.sh"
echo
