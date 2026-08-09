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
#   - Private tracker indexers. They need per-site credentials. The public ones
#     in TORRENT_INDEXERS are added automatically; add private ones in Prowlarr.
#   - Jellyfin libraries. No API key exists until someone signs in, and the
#     libraries have to exist before Jellyseerr's wizard can offer them.
#   - Jellyseerr's first-run wizard. Its settings endpoints return 403 until an
#     admin session exists, and the API key alone will not do. This script
#     detects that state and prints the steps rather than pretending.
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

  # Fills an existing blank assignment in place, and only appends when the
  # variable is absent entirely. Appending unconditionally works — later
  # assignments win for both `source` and Compose — but it leaves the file with
  # the same key defined twice, which is fragile and hard to read once a few
  # rotations have happened.
  set_key() {
    local var=$1 value=$2
    if grep -qE "^${var}=.+" .env; then
      skip "$var already set"
      return 1
    fi
    if grep -qE "^${var}=[[:space:]]*$" .env; then
      # BSD and GNU sed disagree on -i, so write through a temp file instead.
      awk -v v="$var" -v val="$value" \
        '$0 ~ "^" v "=[[:space:]]*$" { print v "=" val; next } { print }' \
        .env > .env.new && mv .env.new .env
      chmod 600 .env
      ok "generated $var"
    else
      printf '%s=%s\n' "$var" "$value" >> .env
      ok "generated $var"
    fi
    return 0
  }

  added=0
  for var in SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY PROWLARR_API_KEY; do
    set_key "$var" "$(openssl rand -hex 16)" && added=1
  done
  # Cleanuparr is absent from both loops on purpose. It has no environment
  # variable for either its API key or its credentials — both are generated into
  # its own database on first start — so there is nothing to pin ahead of time
  # and nothing here to generate (decisions.md D30).
  # WG_PASS is in this list even though nothing later in this script uses it.
  # It is `${WG_PASS:?}` in docker-compose.yml, so the stack will not start
  # without it, and it is the credential that gates minting a VPN peer — which
  # puts the holder on the LAN. Leaving the one password with the widest blast
  # radius as the only one a human has to invent was the wrong default.
  #
  # Unlike the others it is applied on wg-easy's FIRST START ONLY (INIT_*, v15),
  # after which the value lives in wg-easy's database and editing .env does
  # nothing. So this generates a bootstrap credential, not a rotatable one —
  # change it in the UI afterwards (decisions.md D26).
  for var in QBIT_PASS SAB_PASS BAZARR_PASS ARR_PASS WG_PASS; do
    set_key "$var" "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)" && added=1
  done

  # .env now holds every password in the stack plus the Usenet provider account.
  # It is created by `cp .env.example .env`, which inherits the umask — usually
  # 0644. Nothing else in the deploy narrows it.
  if [[ "$(stat -c '%a' .env)" != "600" ]]; then
    chmod 600 .env
    ok "tightened .env to 0600"
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

for var in SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY PROWLARR_API_KEY QBIT_PASS ARR_PASS; do
  [[ -n "${!var:-}" ]] || die "$var is not set in .env. Run: ./scripts/provision.sh --init-keys"
done

QBIT_USER=${QBIT_USER:-admin}
ARR_USER=${ARR_USER:-admin}

# The *arrs reach the download clients across the compose bridge by container
# name, not via a published port. These are variables rather than literals for
# one reason: when the VPN lands (spec §7), qBittorrent moves to
# `network_mode: service:gluetun` and stops having a network identity of its
# own — the *arrs must then reach it at `gluetun`. Set QBIT_HOST=gluetun that
# day. Hardcoding it is a silent breakage waiting to happen.
QBIT_HOST=${QBIT_HOST:-qbittorrent}
SAB_HOST=${SAB_HOST:-sabnzbd}
SONARR_URL="http://127.0.0.1:${SONARR_PORT:-8989}"
RADARR_URL="http://127.0.0.1:${RADARR_PORT:-7878}"
LIDARR_URL="http://127.0.0.1:${LIDARR_PORT:-8686}"
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

  # Categories map to save paths under /data/torrents/ (spec §6 step 1). This
  # list has to match the category names the *arrs are given further down —
  # Lidarr asks for 'music' — because qBittorrent accepts an unregistered
  # category on an incoming torrent and creates it with no save path. The
  # download then lands in the default /data/torrents rather than its own
  # subdirectory, imports still hardlink because it is the same filesystem, and
  # nothing anywhere reports a problem (decisions.md D29).
  local existing cat
  existing=$(qbt http://localhost:8080/api/v2/torrents/categories)
  for cat in movies tv anime music; do
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
  # Sonarr calling http://sabnzbd:8080 is refused. Same class of problem as
  # qBittorrent's host-header check.
  #
  # No proxy hostname here any more: SABnzbd is not routed through Caddy at all
  # (D25). It is reached at ADMIN_HOST:SAB_PORT, and SABnzbd accepts a bare IP
  # in the Host header without it being listed — verified, a direct hit on the
  # LAN address returns the login redirect rather than a 403.
  sab -d mode=set_config -d section=misc -d keyword=host_whitelist \
      --data-urlencode "value=sabnzbd,localhost,${ADMIN_HOST:-}" >/dev/null
  ok "host whitelist -> sabnzbd, localhost, ${ADMIN_HOST:-<unset>}"

  # Incomplete and complete both live under /data/usenet, a sibling of
  # torrents/ and media/, so finished downloads hardlink into the library
  # instead of being copied (spec §3.3).
  sab -d mode=set_config -d section=misc -d keyword=download_dir \
      --data-urlencode "value=/data/usenet/incomplete" >/dev/null
  sab -d mode=set_config -d section=misc -d keyword=complete_dir \
      --data-urlencode "value=/data/usenet/complete" >/dev/null
  ok "paths -> /data/usenet/{incomplete,complete}"

  # Same list as qBittorrent's above, and for the same reason: a category the
  # *arrs name but SABnzbd does not define falls back to the default, so music
  # would complete into /data/usenet/complete instead of complete/music.
  local c
  for c in movies tv anime music; do
    sab -d mode=set_config -d section=categories -d keyword="$c" \
        --data-urlencode "dir=$c" >/dev/null
  done
  ok "categories movies, tv, anime, music"

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

# ─── Jellyseerr ──────────────────────────────────────────────────────────────

provision_jellyseerr() {
  step "Jellyseerr"

  docker compose ps --status running --services | grep -qx jellyseerr || {
    warn "jellyseerr is not running, skipping"; return 0
  }

  local initialized
  initialized=$(curl -fsS --max-time 15 \
    "http://127.0.0.1:${SEERR_PORT:-5055}/api/v1/settings/public" 2>/dev/null \
    | jq -r '.initialized // false')

  if [[ "$initialized" != "true" ]]; then
    # Jellyseerr gates its settings endpoints behind an admin session that only
    # exists after the wizard, and the API key alone returns 403. So the first
    # run genuinely cannot be automated — say so rather than pretend.
    warn "Jellyseerr setup is not finished; nothing to configure yet."
    warn ""
    warn "  Jellyfin needs libraries BEFORE this will work — the wizard asks you"
    warn "  to select them, and offers nothing if none exist."
    warn ""
    warn "  1. Jellyfin > Dashboard > Libraries, add three:"
    warn "       Movies      -> /data/media/movies"
    warn "       Shows       -> /data/media/tv"
    warn "       Anime       -> /data/media/anime   (also type Shows)"
    warn "  2. Jellyseerr > http://localhost:${SEERR_PORT:-5055}/setup"
    warn "       sign in with your Jellyfin admin account, select the libraries"
    warn "  3. Re-run this script to wire up Radarr and Sonarr"
    return 0
  fi
  ok "setup complete — Jellyfin connected"

  local skey seerr
  skey=$(docker compose exec -T jellyseerr \
    sh -c 'cat /app/config/settings.json' | jq -r '.main.apiKey')
  [[ -n "$skey" && "$skey" != "null" ]] || { warn "could not read Jellyseerr's API key"; return 0; }
  seerr="http://127.0.0.1:${SEERR_PORT:-5055}"

  # jseerr <method> <path> [body]
  jseerr() {
    local m=$1 p=$2 b=${3:-}
    if [[ -n "$b" ]]; then
      curl -fsS -X "$m" -H "X-Api-Key: $skey" -H 'Content-Type: application/json' -d "$b" "${seerr}${p}"
    else
      curl -fsS -X "$m" -H "X-Api-Key: $skey" "${seerr}${p}"
    fi
  }

  # Jellyseerr sits behind Caddy at seerr.<domain>, so without this every request
  # it logs — and every request it rate-limits — carries Caddy's container
  # address instead of the client's. It is the same problem Jellyfin has, and the
  # reason setup.sh ships the fail2ban jellyfin jail disabled: a ban list built
  # from proxy addresses bans the proxy. Jellyseerr can be told over the API;
  # Jellyfin's KnownProxies cannot, and stays a manual post-wizard step (README).
  #
  # Idempotent — reads the current value and only writes when it differs. The
  # read is allowed to fail without taking the script with it: this runs under
  # `set -euo pipefail`, where an unexpected status from one settings endpoint
  # would otherwise abort a provisioning run that is otherwise fine.
  local trust
  trust=$(jseerr GET /api/v1/settings/main 2>/dev/null | jq -r '.trustProxy // false') || trust=""
  if [[ "$trust" == "true" ]]; then
    ok "trustProxy already enabled"
  elif jseerr POST /api/v1/settings/main '{"trustProxy":true}' >/dev/null 2>&1; then
    ok "trustProxy enabled — real client addresses in the log, not Caddy's"
  else
    warn "could not set trustProxy; set it under Settings > General > Enable Proxy Support"
  fi

  # Look the profile up by name rather than hardcoding an id — Recyclarr creates
  # these, and the id depends on what order things happened in.
  local rprofile sprofile rid sid
  rprofile=${SEERR_RADARR_PROFILE:-"UHD-2160p"}
  sprofile=${SEERR_SONARR_PROFILE:-"WEB-1080p"}
  rid=$(arr GET "$RADARR_URL" "$RADARR_API_KEY" /api/v3/qualityprofile \
        | jq -r --arg n "$rprofile" '.[] | select(.name == $n) | .id')
  sid=$(arr GET "$SONARR_URL" "$SONARR_API_KEY" /api/v3/qualityprofile \
        | jq -r --arg n "$sprofile" '.[] | select(.name == $n) | .id')

  if [[ -z "$rid" || -z "$sid" ]]; then
    warn "quality profiles not found — run Recyclarr first:"
    warn "  docker compose exec recyclarr recyclarr sync"
    return 0
  fi

  # Existing connections store a copy of the *arr API key, so rotating a key in
  # .env leaves them holding a stale one and requests silently stop reaching
  # Radarr/Sonarr. Reconcile rather than skipping outright.
  local existing_id existing_key
  existing_id=$(jseerr GET /api/v1/settings/radarr | jq -r '.[] | select(.name=="Radarr") | .id // empty')
  existing_key=$(jseerr GET /api/v1/settings/radarr | jq -r '.[] | select(.name=="Radarr") | .apiKey // empty')

  if [[ -n "$existing_id" ]]; then
    if [[ "$existing_key" == "$RADARR_API_KEY" ]]; then
      skip "Radarr already connected"
    else
      # del(.id): the GET returns it, the PUT rejects it in the body with a 400.
      jseerr PUT "/api/v1/settings/radarr/${existing_id}" "$(jseerr GET /api/v1/settings/radarr \
        | jq --arg k "$RADARR_API_KEY" \
             '.[] | select(.name=="Radarr") | .apiKey = $k | del(.id)')" >/dev/null
      ok "Radarr connection updated with the current API key"
    fi
  else
    jseerr POST /api/v1/settings/radarr "$(jq -n \
      --arg k "$RADARR_API_KEY" --argjson id "$rid" --arg pn "$rprofile" \
      '{name:"Radarr", hostname:"radarr", port:7878, apiKey:$k, useSsl:false, baseUrl:"",
        activeProfileId:$id, activeProfileName:$pn, activeDirectory:"/data/media/movies",
        is4k:false, minimumAvailability:"released", isDefault:true, externalUrl:"",
        syncEnabled:true, preventSearch:false, tagRequests:false}')" >/dev/null
    ok "Radarr -> ${rprofile}, /data/media/movies"
  fi

  existing_id=$(jseerr GET /api/v1/settings/sonarr | jq -r '.[] | select(.name=="Sonarr") | .id // empty')
  existing_key=$(jseerr GET /api/v1/settings/sonarr | jq -r '.[] | select(.name=="Sonarr") | .apiKey // empty')

  if [[ -n "$existing_id" ]]; then
    if [[ "$existing_key" == "$SONARR_API_KEY" ]]; then
      skip "Sonarr already connected"
    else
      # del(.id): the GET returns it, the PUT rejects it in the body with a 400.
      jseerr PUT "/api/v1/settings/sonarr/${existing_id}" "$(jseerr GET /api/v1/settings/sonarr \
        | jq --arg k "$SONARR_API_KEY" \
             '.[] | select(.name=="Sonarr") | .apiKey = $k | del(.id)')" >/dev/null
      ok "Sonarr connection updated with the current API key"
    fi
  else
    # Jellyseerr keeps a separate anime profile and directory, which is what
    # routes anime requests to /data/media/anime instead of the TV library.
    #
    # activeLanguageProfileId must be a NUMBER even though Sonarr v4 removed
    # language profiles entirely — passing null fails schema validation with
    # "should be number".
    jseerr POST /api/v1/settings/sonarr "$(jq -n \
      --arg k "$SONARR_API_KEY" --argjson id "$sid" --arg pn "$sprofile" \
      '{name:"Sonarr", hostname:"sonarr", port:8989, apiKey:$k, useSsl:false, baseUrl:"",
        activeProfileId:$id, activeProfileName:$pn, activeDirectory:"/data/media/tv",
        activeAnimeProfileId:$id, activeAnimeProfileName:$pn,
        activeAnimeDirectory:"/data/media/anime",
        activeLanguageProfileId:1, activeAnimeLanguageProfileId:1,
        is4k:false, isDefault:true, enableSeasonFolders:true, externalUrl:"",
        syncEnabled:true, preventSearch:false, tagRequests:false}')" >/dev/null
    ok "Sonarr -> ${sprofile}, /data/media/tv + anime -> /data/media/anime"
  fi

  unset -f jseerr
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

# add_root_folder <app> <url> <key> <path> [api-version]
#
# The version defaults to v3 so the Sonarr and Radarr calls read as they always
# did. Lidarr is v1 — a wrong version 404s immediately rather than doing
# something subtle, which is why a default is safe here.
add_root_folder() {
  local app=$1 url=$2 key=$3 path=$4 ver=${5:-v3}
  if arr GET "$url" "$key" "/api/$ver/rootfolder" | jq -e --arg p "$path" 'any(.[]; .path == $p)' >/dev/null; then
    skip "$app root folder $path exists"
    return
  fi

  local body="{\"path\":\"$path\"}"

  # Lidarr validates three more fields than Sonarr and Radarr do: a name, and a
  # default quality *and* metadata profile, both of which must reference rows
  # that exist. Neither id is stable — they depend on the order the profiles were
  # created in — so look them up rather than assuming 1.
  if [[ "$ver" == "v1" ]]; then
    local qp mp
    qp=$(arr GET "$url" "$key" "/api/$ver/qualityprofile"  | jq -r 'first(.[].id) // empty')
    mp=$(arr GET "$url" "$key" "/api/$ver/metadataprofile" | jq -r 'first(.[].id) // empty')
    if [[ -z "$qp" || -z "$mp" ]]; then
      warn "$app has no quality or metadata profile yet — skipping root folder $path"
      return
    fi
    body=$(jq -n --arg p "$path" --arg n "$(basename "$path")" \
                 --argjson qp "$qp" --argjson mp "$mp" \
      '{path: $p, name: $n, defaultQualityProfileId: $qp, defaultMetadataProfileId: $mp}')
  fi

  arr POST "$url" "$key" "/api/$ver/rootfolder" "$body" >/dev/null
  ok "$app root folder $path"
}

# ─── Download client ─────────────────────────────────────────────────────────

# upsert_download_client <app> <url> <key> <name> <impl> <contract> <protocol>
#                        <priority> <fields-json> <description> [api-version]
#
# Priority is lowest-wins. SABnzbd is given 1 and qBittorrent 2 so Usenet is
# preferred where both have a release — it is faster and carries no seeding
# obligation. Torrents still win for anime, which Usenet covers poorly, because
# that is where the releases actually are.
#
# The version trails the existing arguments so Sonarr and Radarr's calls are
# unchanged; only Lidarr passes v1.
upsert_download_client() {
  local app=$1 url=$2 key=$3 name=$4 impl=$5 contract=$6 proto=$7 prio=$8 fields=$9 desc=${10} ver=${11:-v3}
  local existing
  existing=$(arr GET "$url" "$key" "/api/$ver/downloadclient" | jq --arg n "$name" '.[] | select(.name == $n)')

  if [[ -n "$existing" ]]; then
    if [[ $(jq -r '.priority' <<<"$existing") == "$prio" ]]; then
      skip "$app: $name exists"
    else
      arr PUT "$url" "$key" "/api/$ver/downloadclient/$(jq -r '.id' <<<"$existing")" \
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
  arr POST "$url" "$key" "/api/$ver/downloadclient" "$body" >/dev/null
  ok "$app: $name -> $desc"
}

qbit_fields() {
  jq -n --arg host "$QBIT_HOST" --arg user "$QBIT_USER" --arg pass "$QBIT_PASS" \
        --arg cf "$1" --arg cat "$2" \
    '[{name:"host",value:$host},{name:"port",value:8080},
      {name:"useSsl",value:false},{name:"username",value:$user},
      {name:"password",value:$pass},{name:$cf,value:$cat}]'
}

sab_fields() {
  jq -n --arg host "$SAB_HOST" --arg key "$SAB_API_KEY" --arg cf "$1" --arg cat "$2" \
    '[{name:"host",value:$host},{name:"port",value:8080},
      {name:"useSsl",value:false},{name:"apiKey",value:$key},
      {name:$cf,value:$cat}]'
}

# ─── *arr login ──────────────────────────────────────────────────────────────

# ensure_arr_auth <app> <url> <key> <api-version>
#
# Only the credentials are set here. The method and whether auth is required at
# all come from SONARR__AUTH__METHOD / __REQUIRED in docker-compose.yml, because
# environment config is re-applied on every container start — an accidental UI
# flip to DisabledForLocalAddresses reverts on the next restart instead of
# quietly persisting. Credentials cannot be pinned the same way: the *arrs keep
# them in their database, not config.xml, so they have to come over the API.
#
# This runs before anyone has logged in, which only works because the API key is
# pinned ahead of first start (decisions.md D12). That is what closes the window
# where a fresh box serves an open account-creation screen on the LAN.
#
# Idempotent. To rotate the password, change ARR_PASS in .env and re-run with
# ARR_AUTH_FORCE=1 — otherwise an already-configured login is left alone so a
# routine provision run does not log you out of every UI.
ensure_arr_auth() {
  local app=$1 url=$2 key=$3 ver=$4 current updated
  current=$(arr GET "$url" "$key" "/api/$ver/config/host")

  if [[ "${ARR_AUTH_FORCE:-0}" != "1" ]] \
     && [[ $(jq -r '.username' <<<"$current") == "$ARR_USER" ]] \
     && [[ -n $(jq -r '.password // ""' <<<"$current") ]]; then
    skip "$app login already set for '$ARR_USER'"
    return
  fi

  # passwordConfirmation must match or the PUT fails schema validation.
  updated=$(jq --arg u "$ARR_USER" --arg p "$ARR_PASS" \
    '.username = $u | .password = $p | .passwordConfirmation = $p' <<<"$current")
  arr PUT "$url" "$key" "/api/$ver/config/host" "$updated" >/dev/null
  ok "$app login set for '$ARR_USER'"
}

# ─── Hardlinks ───────────────────────────────────────────────────────────────

# ensure_hardlinks <app> <url> <key> [api-version]
#
# Lidarr spells the field the same way Sonarr and Radarr do, so only the path
# version differs.
ensure_hardlinks() {
  local app=$1 url=$2 key=$3 ver=${4:-v3} current updated
  current=$(arr GET "$url" "$key" "/api/$ver/config/mediamanagement")
  if [[ $(jq -r '.copyUsingHardlinks' <<<"$current") == "true" ]]; then
    skip "$app already uses hardlinks instead of copy"
  else
    updated=$(jq '.copyUsingHardlinks = true' <<<"$current")
    arr PUT "$url" "$key" "/api/$ver/config/mediamanagement" "$updated" >/dev/null
    ok "$app set to hardlink instead of copy"
  fi
}

# ─── Prowlarr application links ──────────────────────────────────────────────

add_prowlarr_app() {
  local name=$1 impl=$2 contract=$3 app_url=$4 app_key=$5
  local existing current_key

  existing=$(arr GET "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/applications \
             | jq --arg n "$name" '.[] | select(.name == $n)')

  if [[ -n "$existing" ]]; then
    # The link stores its own copy of the app's API key. Rotating a key in .env
    # leaves this holding the old one, and indexer sync stops working with no
    # error anywhere obvious — so reconcile it rather than skipping.
    current_key=$(jq -r '.fields[] | select(.name=="apiKey") | .value // empty' <<<"$existing")
    if [[ "$current_key" == "$app_key" ]]; then
      skip "Prowlarr -> $name link exists"
    else
      arr PUT "$PROWLARR_URL" "$PROWLARR_API_KEY" \
        "/api/v1/applications/$(jq -r '.id' <<<"$existing")" \
        "$(jq --arg k "$app_key" \
             '.fields = [.fields[] | if .name == "apiKey" then .value = $k else . end]' \
             <<<"$existing")" >/dev/null
      ok "Prowlarr -> $name link updated with the current API key"
    fi
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
wait_for Lidarr   "$LIDARR_URL/api/v1/system/status"   "$LIDARR_API_KEY";   ok "Lidarr ready"
wait_for Prowlarr "$PROWLARR_URL/api/v1/system/status" "$PROWLARR_API_KEY"; ok "Prowlarr ready"

# Close the *arr UIs first. Everything below this point is configuration; this
# is the step that stops a fresh box serving an open account-creation screen.
step "Logins"
ensure_arr_auth Sonarr   "$SONARR_URL"   "$SONARR_API_KEY"   v3
ensure_arr_auth Radarr   "$RADARR_URL"   "$RADARR_API_KEY"   v3
ensure_arr_auth Lidarr   "$LIDARR_URL"   "$LIDARR_API_KEY"   v1
ensure_arr_auth Prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" v1

provision_qbittorrent
provision_sabnzbd
provision_bazarr
provision_jellyseerr

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

# Lidarr is v1 throughout, and its category field is musicCategory rather than
# tvCategory/movieCategory. Same priority ordering as the other two: Usenet
# first, torrents as the fallback.
step "Lidarr"
add_root_folder Lidarr "$LIDARR_URL" "$LIDARR_API_KEY" /data/media/music v1
upsert_download_client Lidarr "$LIDARR_URL" "$LIDARR_API_KEY" \
  SABnzbd Sabnzbd SabnzbdSettings usenet 1 "$(sab_fields musicCategory music)" "sabnzbd:8080, category 'music'" v1
upsert_download_client Lidarr "$LIDARR_URL" "$LIDARR_API_KEY" \
  qBittorrent QBittorrent QBittorrentSettings torrent 2 "$(qbit_fields musicCategory music)" "qbittorrent:8080, category 'music'" v1
ensure_hardlinks Lidarr "$LIDARR_URL" "$LIDARR_API_KEY" v1

step "Prowlarr"
add_prowlarr_app Sonarr Sonarr SonarrSettings "http://sonarr:8989" "$SONARR_API_KEY"
add_prowlarr_app Radarr Radarr RadarrSettings "http://radarr:7878" "$RADARR_API_KEY"
add_prowlarr_app Lidarr Lidarr LidarrSettings "http://lidarr:8686" "$LIDARR_API_KEY"
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
#
# Nyaa.si, SubsPlease and AnimeTosho are what make anime work — Usenet covers it
# poorly, so without them Sonarr finds almost nothing for an anime series.
# The Pirate Bay and YTS are the general-purpose half: without them the torrent
# side covers only anime, and everything else depends on the Usenet provider and
# indexer subscriptions both staying live. They are the fallback for a lapsed
# subscription and for titles that have aged out of Usenet retention. YTS is
# films only and its releases are small encodes that the SQP profile ranks low,
# which is the correct behaviour for a last resort.
#
# 1337x is deliberately absent despite being the best general-purpose public
# tracker: it sits behind CloudFlare and Prowlarr rejects it on save with
# "blocked by CloudFlare Protection". Reaching it needs a FlareSolverr container
# and a matching Prowlarr proxy — see .env.example.
#
# Tokyo Toshokan was dropped: it indexes largely the same sources as Nyaa.
#
# Note AnimeTosho, not "Anime Tosho": Prowlarr carries both, and despite being
# labelled private the former needs no credentials and works, while the
# semiprivate one fails to connect.
IFS=',' read -r -a _indexers <<<"${TORRENT_INDEXERS:-Nyaa.si,SubsPlease,AnimeTosho,The Pirate Bay,YTS}"
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
  "Jellyfin: create four libraries — /data/media/{movies,tv,anime,music}," \
  "          anime as its own library, and enable VAAPI on the target." \
  "Recyclarr: docker compose exec recyclarr recyclarr sync (no Lidarr support)" \
  "" \
  "Cleanuparr: nothing here could configure it — it has no environment" \
  "          variable for its credentials or its API key, so both are created" \
  "          in its database on first start (decisions.md D30). Do this now," \
  "          before anyone else can, at http://<lan-ip>:${CLEANUPARR_PORT:-11011}" \
  "            1. Create the admin account. That closes the setup wizard." \
  "            2. Leave 'Disable Auth for Local Addresses' OFF — its trusted" \
  "               ranges include 172.16.0.0/12, the Docker bridge." \
  "            3. Add qBittorrent at http://${QBIT_HOST}:8080 and the four *arrs." \
  "            4. Leave the destructive cleaners disabled until you have" \
  "               watched it run — it has write access to /data."
echo
ok "Provisioning complete. Verify with: ./scripts/test-hardlinks.sh"
echo
