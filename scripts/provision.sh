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
  for var in QBIT_PASS SAB_PASS BAZARR_PASS; do
    if grep -qE "^${var}=.+" .env; then
      skip "$var already set"
    else
      printf '%s=%s\n' "$var" "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)" >> .env
      ok "generated $var"
      added=1
    fi
  done
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

# ─── SABnzbd ─────────────────────────────────────────────────────────────────

SAB_API_KEY=""

provision_sabnzbd() {
  step "SABnzbd"

  docker compose ps --status running --services | grep -qx sabnzbd \
    || die "sabnzbd is not running. Start the stack: docker compose up -d"

  # SABnzbd generates its own API key on first start and offers no environment
  # variable to pin it, unlike the *arrs — so read it back out of the ini.
  SAB_API_KEY=$(docker compose exec -T sabnzbd \
    sh -c "grep '^api_key' /config/sabnzbd.ini | cut -d' ' -f3" | tr -d '\r')
  [[ -n "$SAB_API_KEY" ]] || die "Could not read SABnzbd's API key from /config/sabnzbd.ini"
  ok "read API key from sabnzbd.ini"

  sab() {
    docker compose exec -T sabnzbd curl -fsS -G http://localhost:8080/api \
      --data-urlencode "apikey=${SAB_API_KEY}" --data-urlencode "output=json" "$@"
  }

  # SABnzbd rejects any request whose Host header is not whitelisted, with a
  # bare 403. Out of the box the list holds only the container's own ID, so
  # Sonarr calling http://sabnzbd:8080 is refused, and so is anything arriving
  # through Caddy. Same class of problem as qBittorrent's host-header check.
  sab -d mode=set_config -d section=misc -d keyword=host_whitelist \
      --data-urlencode "value=sabnzbd,localhost,sab.${CADDY_DOMAIN}" >/dev/null
  ok "host whitelist -> sabnzbd, localhost, sab.${CADDY_DOMAIN}"

  # Incomplete and complete both live under /data/usenet, a sibling of
  # torrents/ and media/, so finished downloads hardlink into the library
  # instead of being copied (spec §3.3).
  sab -d mode=set_config -d section=misc -d keyword=download_dir \
      --data-urlencode "value=/data/usenet/incomplete" >/dev/null
  sab -d mode=set_config -d section=misc -d keyword=complete_dir \
      --data-urlencode "value=/data/usenet/complete" >/dev/null
  ok "paths -> /data/usenet/{incomplete,complete}"

  local c
  for c in movies tv anime; do
    sab -d mode=set_config -d section=categories -d keyword="$c" \
        --data-urlencode "dir=$c" >/dev/null
  done
  ok "categories movies, tv, anime"

  # The provider is what actually holds the articles; the indexers only say
  # where they are. Without one, SABnzbd finds everything and downloads nothing.
  if [[ -z "${USENET_USER:-}" ]]; then
    warn "USENET_USER is blank — no news server configured."
    warn "  Indexers find NZBs; a provider supplies the bytes. Until you add"
    warn "  one, every Usenet download will fail. Set USENET_USER/USENET_PASS"
    warn "  in .env and re-run this script."
  else
    sab -d mode=set_config -d section=servers -d keyword=provider \
        --data-urlencode "host=${USENET_HOST}" \
        -d "port=${USENET_PORT:-563}" \
        -d "ssl=$([[ ${USENET_SSL:-true} == true ]] && echo 1 || echo 0)" \
        -d "connections=${USENET_CONNECTIONS:-20}" \
        --data-urlencode "username=${USENET_USER}" \
        --data-urlencode "password=${USENET_PASS:-}" \
        -d enable=1 >/dev/null
    ok "news server -> ${USENET_HOST}:${USENET_PORT:-563} (${USENET_CONNECTIONS:-20} connections, SSL)"

    # Prove the credentials actually work. Bad ones otherwise surface only as
    # every download failing later, with nothing obvious pointing at the cause.
    local test_result
    test_result=$(sab -d mode=config -d name=test_server \
      --data-urlencode "host=${USENET_HOST}" \
      -d "port=${USENET_PORT:-563}" \
      -d "ssl=$([[ ${USENET_SSL:-true} == true ]] && echo 1 || echo 0)" \
      -d "connections=${USENET_CONNECTIONS:-20}" \
      --data-urlencode "username=${USENET_USER}" \
      --data-urlencode "password=${USENET_PASS:-}" 2>/dev/null \
      | jq -r '.value.result' 2>/dev/null)

    if [[ "$test_result" == "true" ]]; then
      ok "news server connection verified"
    else
      warn "news server did NOT connect — check USENET_USER/USENET_PASS in .env"
    fi
  fi

  # SABnzbd ships with no web UI login at all. It runs post-processing scripts,
  # so an open UI is the same class of exposure as qBittorrent's external
  # program setting. The *arrs authenticate with the API key, not these
  # credentials, so setting them does not break the download client.
  if [[ -n "${SAB_PASS:-}" ]]; then
    sab -d mode=set_config -d section=misc -d keyword=username \
        --data-urlencode "value=${SAB_USER:-admin}" >/dev/null
    sab -d mode=set_config -d section=misc -d keyword=password \
        --data-urlencode "value=${SAB_PASS}" >/dev/null
    ok "web UI login enabled for '${SAB_USER:-admin}'"
  else
    warn "SAB_PASS is blank — the SABnzbd web UI has NO login."
    warn "  Anyone who can reach the port can queue downloads and run scripts."
  fi

  unset -f sab
}

# ─── Bazarr ──────────────────────────────────────────────────────────────────

provision_bazarr() {
  step "Bazarr"

  docker compose ps --status running --services | grep -qx bazarr || {
    warn "bazarr is not running, skipping"; return 0
  }

  local bkey
  bkey=$(docker compose exec -T bazarr \
    sh -c "grep -A4 '^auth:' /config/config/config.yaml | grep apikey | awk '{print \$2}'" | tr -d '\r')
  [[ -n "$bkey" ]] || { warn "could not read Bazarr's API key"; return 0; }

  # Bazarr's API always requires its key; it is the web UI that ships open.
  if [[ -z "${BAZARR_PASS:-}" ]]; then
    warn "BAZARR_PASS is blank — the Bazarr web UI has NO login."
    return 0
  fi

  local current
  current=$(docker compose exec -T bazarr \
    sh -c "grep -A4 '^auth:' /config/config/config.yaml | grep '  type:' | awk '{print \$2}'" | tr -d '\r')
  if [[ "$current" == "form" ]]; then
    skip "web UI login already enabled"
    return 0
  fi

  curl -fsS -o /dev/null -X POST -H "X-API-KEY: ${bkey}" \
    --data-urlencode "settings-auth-type=form" \
    --data-urlencode "settings-auth-username=${BAZARR_USER:-admin}" \
    --data-urlencode "settings-auth-password=${BAZARR_PASS}" \
    "http://127.0.0.1:${BAZARR_PORT:-6767}/api/system/settings"

  # Bazarr only picks the change up on restart.
  docker compose restart bazarr >/dev/null 2>&1
  ok "web UI login enabled for '${BAZARR_USER:-admin}' (bazarr restarted)"
}

# ─── Prowlarr indexers ───────────────────────────────────────────────────────

# add_indexer <definition-name> [api-key]
#
# Public indexers take no key and are added as-is. Private ones need one, and
# the caller is responsible for skipping when it is missing.
add_indexer() {
  local definition=$1 apikey=${2:-}

  if arr GET "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/indexer \
     | jq -e --arg n "$definition" 'any(.[]; .name == $n)' >/dev/null; then
    skip "$definition exists"
    return
  fi

  local body resp
  body=$(arr GET "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/indexer/schema \
    | jq --arg n "$definition" --arg k "$apikey" \
        '.[] | select(.name == $n)
         | if $k != "" then
             .fields = ([.fields[] | if .name == "apiKey" then .value = $k else . end])
           else . end
         | . + {enable: true, appProfileId: 1, priority: 25}')
  [[ -n "$body" ]] || { warn "$definition: no such definition in Prowlarr"; return; }

  # Prowlarr validates the key against the indexer on save, so a bad key fails
  # here rather than silently returning no results later.
  if resp=$(curl -sS -X POST -H "X-Api-Key: $PROWLARR_API_KEY" \
              -H 'Content-Type: application/json' -d "$body" \
              "${PROWLARR_URL}/api/v1/indexer" 2>&1) \
     && jq -e '.id' <<<"$resp" >/dev/null 2>&1; then
    ok "$definition added"
  else
    warn "$definition rejected: $(jq -r 'if type=="array" then .[0].errorMessage else . end' <<<"$resp" 2>/dev/null || echo "$resp")"
  fi
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

# upsert_download_client <app> <url> <key> <name> <impl> <contract> <protocol>
#                        <priority> <fields-json> <description>
#
# Priority is lowest-wins. SABnzbd is given 1 and qBittorrent 2 so Usenet is
# preferred where both have a release — it is faster and carries no seeding
# obligation. Torrents still win for anime, which Usenet covers poorly, because
# that is where the releases actually are.
upsert_download_client() {
  local app=$1 url=$2 key=$3 name=$4 impl=$5 contract=$6 proto=$7 prio=$8 fields=$9 desc=${10}
  local existing
  existing=$(arr GET "$url" "$key" /api/v3/downloadclient | jq --arg n "$name" '.[] | select(.name == $n)')

  if [[ -n "$existing" ]]; then
    if [[ $(jq -r '.priority' <<<"$existing") == "$prio" ]]; then
      skip "$app: $name exists"
    else
      arr PUT "$url" "$key" "/api/v3/downloadclient/$(jq -r '.id' <<<"$existing")" \
        "$(jq --argjson p "$prio" '.priority = $p' <<<"$existing")" >/dev/null
      ok "$app: $name priority -> $prio"
    fi
    return
  fi

  local body
  body=$(jq -n --arg name "$name" --arg impl "$impl" --arg contract "$contract" \
               --arg proto "$proto" --argjson prio "$prio" --argjson fields "$fields" \
    '{enable: true, protocol: $proto, priority: $prio,
      removeCompletedDownloads: true, removeFailedDownloads: true,
      name: $name, implementation: $impl, configContract: $contract,
      fields: $fields}')
  arr POST "$url" "$key" /api/v3/downloadclient "$body" >/dev/null
  ok "$app: $name -> $desc"
}

# host is the container name, not localhost: the *arrs reach the download
# clients across the compose bridge network, not via a published port.
qbit_fields() {
  jq -n --arg user "$QBIT_USER" --arg pass "$QBIT_PASS" --arg cf "$1" --arg cat "$2" \
    '[{name:"host",value:"qbittorrent"},{name:"port",value:8080},
      {name:"useSsl",value:false},{name:"username",value:$user},
      {name:"password",value:$pass},{name:$cf,value:$cat}]'
}

sab_fields() {
  jq -n --arg key "$SAB_API_KEY" --arg cf "$1" --arg cat "$2" \
    '[{name:"host",value:"sabnzbd"},{name:"port",value:8080},
      {name:"useSsl",value:false},{name:"apiKey",value:$key},
      {name:$cf,value:$cat}]'
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
provision_sabnzbd
provision_bazarr

step "Sonarr"
add_root_folder Sonarr "$SONARR_URL" "$SONARR_API_KEY" /data/media/tv
add_root_folder Sonarr "$SONARR_URL" "$SONARR_API_KEY" /data/media/anime
# Sonarr has a single category field per client, so anime downloads land in the
# 'tv' category too. Harmless: it is the same filesystem, and the TV/anime split
# that matters happens at the root folder and Jellyfin library level.
upsert_download_client Sonarr "$SONARR_URL" "$SONARR_API_KEY" \
  SABnzbd Sabnzbd SabnzbdSettings usenet 1 "$(sab_fields tvCategory tv)" "sabnzbd:8080, category 'tv'"
upsert_download_client Sonarr "$SONARR_URL" "$SONARR_API_KEY" \
  qBittorrent QBittorrent QBittorrentSettings torrent 2 "$(qbit_fields tvCategory tv)" "qbittorrent:8080, category 'tv'"
ensure_hardlinks Sonarr "$SONARR_URL" "$SONARR_API_KEY"

step "Radarr"
add_root_folder Radarr "$RADARR_URL" "$RADARR_API_KEY" /data/media/movies
upsert_download_client Radarr "$RADARR_URL" "$RADARR_API_KEY" \
  SABnzbd Sabnzbd SabnzbdSettings usenet 1 "$(sab_fields movieCategory movies)" "sabnzbd:8080, category 'movies'"
upsert_download_client Radarr "$RADARR_URL" "$RADARR_API_KEY" \
  qBittorrent QBittorrent QBittorrentSettings torrent 2 "$(qbit_fields movieCategory movies)" "qbittorrent:8080, category 'movies'"
ensure_hardlinks Radarr "$RADARR_URL" "$RADARR_API_KEY"

step "Prowlarr"
add_prowlarr_app Sonarr Sonarr SonarrSettings "http://sonarr:8989" "$SONARR_API_KEY"
add_prowlarr_app Radarr Radarr RadarrSettings "http://radarr:7878" "$RADARR_API_KEY"
# Usenet indexers are private and useless without a key, so skip them until
# one is supplied rather than creating a broken entry.
for pair in "NZBgeek:${NZBGEEK_API_KEY:-}" "NzbPlanet:${NZBPLANET_API_KEY:-}"; do
  if [[ -z "${pair#*:}" ]]; then
    skip "${pair%%:*}: no API key in .env, skipping"
  else
    add_indexer "${pair%%:*}" "${pair#*:}"
  fi
done

# Public torrent indexers need no account, so they ship enabled by default.
# These are what make anime work — Usenet covers it poorly, so without them
# Sonarr finds almost nothing for an anime series.
#
# Note AnimeTosho, not "Anime Tosho": Prowlarr carries both, and despite being
# labelled private the former needs no credentials and works, while the
# semiprivate one fails to connect.
IFS=',' read -r -a _indexers <<<"${TORRENT_INDEXERS:-Nyaa.si,SubsPlease,AnimeTosho,Tokyo Toshokan}"
for definition in "${_indexers[@]}"; do
  definition="${definition#"${definition%%[![:space:]]*}"}"   # trim leading space
  definition="${definition%"${definition##*[![:space:]]}"}"   # trim trailing space
  [[ -n "$definition" ]] && add_indexer "$definition"
done

step "Left for you"
printf '  %s\n' \
  "Prowlarr: the public torrent indexers are already added. Add any private" \
  "          trackers by hand — they need per-site credentials." \
  "Bazarr:   connect to Sonarr and Radarr, choose subtitle providers." \
  "Jellyfin: create three libraries — /data/media/{movies,tv,anime}," \
  "          anime as its own library, and enable VAAPI on the target." \
  "Recyclarr: docker compose exec recyclarr recyclarr sync"
echo
ok "Provisioning complete. Verify with: ./scripts/test-hardlinks.sh"
echo
