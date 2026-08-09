#!/usr/bin/env bash
#
# Runtime security audit. The counterpart to validate.sh: that one is static and
# checks the files, this one asks the running stack what it is actually doing.
#
# It exists because the things most likely to go wrong here are runtime state
# that no file in the repo records:
#
#   - Every app's authentication is configured through its own API or UI. A
#     single toggle in a web UI can switch it off, and nothing else would notice.
#   - The *arrs offer AuthenticationRequired = DisabledForLocalAddresses, which
#     is common forum advice and is actively dangerous in this stack: Caddy
#     reaches the backends over the compose bridge, so every proxied request has
#     a private 172.x source address and would skip authentication entirely.
#     The admin UIs become anonymous-admin while remote access carries on
#     working perfectly. Verified: with that setting, GET / returns 200 with no
#     login.
#   - wg-easy configures itself from INIT_* on first start only, so unlike the
#     *arrs its authentication is not re-asserted every time it comes up. This
#     script is the compensating control (decisions.md D26). Cleanuparr is the
#     same shape and worse — it has no INIT_* equivalent at all, so a wiped
#     /config comes back with an open setup wizard (D30).
#   - Cleanuparr has its own version of the DisabledForLocalAddresses trap,
#     called "Disable Auth for Local Addresses", whose built-in trusted ranges
#     include 172.16.0.0/12. That is Docker's default pool, so enabling it
#     exempts the entire compose bridge rather than merely the LAN.
#   - qBittorrent's "run external program on completion" is arbitrary command
#     execution by design (spec §5.3). provision.sh blanks it, and a UI edit can
#     put it straight back.
#
# Nothing here is read from config.xml. The *arrs apply their environment
# configuration at runtime without writing it to disk, so config.xml goes stale
# and disagrees with the running app — the API is the only source of truth.
#
# Usage:  ./scripts/audit-auth.sh      (needs the stack up)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pass=0 fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  \033[33m–\033[0m %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

[[ -f .env ]] || { echo "No .env found. Copy .env.example to .env first." >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source ./.env
set +a

# Everything is probed on the loopback-published port rather than through Caddy.
# Going through the proxy would test the proxy; the point here is what each app
# enforces on its own, since that is the only thing standing between the LAN and
# an admin session.
SONARR_URL="http://127.0.0.1:${SONARR_PORT:-8989}"
RADARR_URL="http://127.0.0.1:${RADARR_PORT:-7878}"
LIDARR_URL="http://127.0.0.1:${LIDARR_PORT:-8686}"
PROWLARR_URL="http://127.0.0.1:${PROWLARR_PORT:-9696}"
JELLYFIN_URL="http://127.0.0.1:${JELLYFIN_PORT:-8096}"
SEERR_URL="http://127.0.0.1:${SEERR_PORT:-5055}"
SAB_URL="http://127.0.0.1:${SAB_PORT:-8085}"
CLEANUPARR_URL="http://127.0.0.1:${CLEANUPARR_PORT:-11011}"
# No BAZARR_URL: Bazarr serves its SPA shell at 200 whether or not you are
# logged in, so an HTTP probe proves nothing. It is audited from its config.

# code <url> [curl-args...] — HTTP status of an unauthenticated request
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }

up() { docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "$1"; }

# ─── The *arrs ───────────────────────────────────────────────────────────────

audit_arr() {
  local app=$1 url=$2 key=$3 ver=$4 host method required svc
  svc=$(tr '[:upper:]' '[:lower:]' <<<"$app")

  if ! up "$svc"; then
    skip "$app is not running"
    return
  fi

  if [[ -z "$key" ]]; then
    bad "$app: no API key in .env — cannot audit"
    return
  fi

  # The pinned key must be the key the app actually answers to. If the env var
  # is ever dropped, the *arr silently falls back to the key in its own
  # config.xml — which nothing in .env knows — and provision.sh and Recyclarr
  # start failing with 401s for no visible reason.
  if [[ "$(code -H "X-Api-Key: $key" "$url/api/$ver/system/status")" != "200" ]]; then
    bad "$app: the API key in .env is not accepted — is SONARR__AUTH__APIKEY still set?"
    return
  fi
  ok "$app: the API key in .env is the live key"

  if [[ "$(code -H "X-Api-Key: deadbeefdeadbeefdeadbeefdeadbeef" "$url/api/$ver/system/status")" == "200" ]]; then
    bad "$app: a bogus API key was accepted — the API is unauthenticated"
  else
    ok "$app: a bogus API key is rejected"
  fi

  host=$(curl -fsS --max-time 8 -H "X-Api-Key: $key" "$url/api/$ver/config/host")
  method=$(jq -r '.authenticationMethod' <<<"$host")
  required=$(jq -r '.authenticationRequired' <<<"$host")

  case "$method" in
    forms|basic) ok "$app: authentication method is '$method'" ;;
    external)
      bad "$app: authentication method is 'external' — the UI is wide open"
      note "'external' means an upstream proxy is expected to authenticate."
      note "Caddy in this stack does not. Set ARR_AUTH_METHOD=Forms and restart."
      ;;
    *)
      bad "$app: authentication method is '$method'"
      ;;
  esac

  if [[ "$required" == "enabled" ]]; then
    ok "$app: authentication required for all addresses"
  else
    bad "$app: authenticationRequired is '$required', not 'enabled'"
    note "Caddy reaches this app over the compose bridge, so every proxied"
    note "request has a private source address and skips authentication."
    note "The admin UI is reachable without a login. Fix: unset"
    note "ARR_AUTH_REQUIRED in .env and 'docker compose up -d $svc'."
  fi

  if [[ -n "$(jq -r '.username // ""' <<<"$host")" \
     && -n "$(jq -r '.password // ""' <<<"$host")" ]]; then
    ok "$app: a login is set"
  else
    bad "$app: no username or password is set"
    note "Run: ./scripts/provision.sh"
  fi

  # The redirect is the end-to-end proof: whatever the settings claim, an
  # anonymous browser request must not reach the UI.
  if [[ "$(code "$url/")" == "200" ]]; then
    bad "$app: GET / returned 200 without a login"
  else
    ok "$app: GET / redirects an anonymous request to the login page"
  fi
}

echo
echo "Sonarr / Radarr / Lidarr / Prowlarr"
audit_arr Sonarr   "$SONARR_URL"   "${SONARR_API_KEY:-}"   v3
audit_arr Radarr   "$RADARR_URL"   "${RADARR_API_KEY:-}"   v3
audit_arr Lidarr   "$LIDARR_URL"   "${LIDARR_API_KEY:-}"   v1
audit_arr Prowlarr "$PROWLARR_URL" "${PROWLARR_API_KEY:-}" v1

# ─── qBittorrent ─────────────────────────────────────────────────────────────

echo
echo "qBittorrent"

if ! up qbittorrent; then
  skip "qbittorrent is not running"
else
  # Driven from inside the container: qBittorrent rejects requests whose Host
  # header it does not recognise, and the published port is remapped in dev.
  qbt() { docker compose exec -T qbittorrent curl -s --max-time 8 "$@"; }

  if [[ "$(qbt -o /dev/null -w '%{http_code}' http://localhost:8080/api/v2/app/version)" == "200" ]]; then
    bad "qBittorrent: the API answered without a session"
    note "A qBittorrent session is effectively a shell (spec §5.3)."
    note "Check 'Bypass authentication for clients on localhost' in the UI."
  else
    ok "qBittorrent: the API rejects an unauthenticated request"
  fi

  prefs=""
  if [[ -n "${QBIT_PASS:-}" ]]; then
    docker compose exec -T qbittorrent sh -c \
      "curl -s -c /tmp/audit.cookies -o /dev/null \
        --data-urlencode 'username=${QBIT_USER:-admin}' \
        --data-urlencode 'password=${QBIT_PASS}' \
        http://localhost:8080/api/v2/auth/login" 2>/dev/null || true
    prefs=$(docker compose exec -T qbittorrent \
      curl -s -b /tmp/audit.cookies --max-time 8 \
      http://localhost:8080/api/v2/app/preferences 2>/dev/null || true)
    docker compose exec -T qbittorrent rm -f /tmp/audit.cookies >/dev/null 2>&1 || true
  fi

  if [[ -z "$prefs" ]] || ! jq -e . >/dev/null 2>&1 <<<"$prefs"; then
    skip "qBittorrent: could not read preferences (is QBIT_PASS current?)"
  else
    # spec §5.3: this is arbitrary command execution by design, and it is a
    # checkbox away from being re-enabled in the UI at any time.
    if [[ "$(jq -r '.autorun_enabled' <<<"$prefs")" == "false" \
       && -z "$(jq -r '.autorun_program // ""' <<<"$prefs")" ]]; then
      ok "qBittorrent: run-external-program is off and empty"
    else
      bad "qBittorrent: run-external-program is set — this is arbitrary command execution"
      note "program: $(jq -r '.autorun_program // ""' <<<"$prefs")"
    fi

    if [[ "$(jq -r '.bypass_local_auth' <<<"$prefs")" == "false" ]]; then
      ok "qBittorrent: no localhost authentication bypass"
    else
      bad "qBittorrent: authentication is bypassed for localhost clients"
    fi

    if [[ "$(jq -r '.bypass_auth_subnet_whitelist_enabled' <<<"$prefs")" == "false" ]]; then
      ok "qBittorrent: no subnet authentication bypass"
    else
      bad "qBittorrent: authentication is bypassed for $(jq -r '.bypass_auth_subnet_whitelist' <<<"$prefs")"
    fi

    # Deliberately off (decisions.md D13) so a remapped host port works at all.
    # CSRF protection is the one that matters and must stay on — especially now
    # that D13's original mitigation, "no port forwarding", no longer holds.
    if [[ "$(jq -r '.web_ui_csrf_protection_enabled' <<<"$prefs")" == "true" ]]; then
      ok "qBittorrent: CSRF protection on"
    else
      bad "qBittorrent: CSRF protection is off"
      note "Host-header validation is already disabled by design (D13);"
      note "CSRF is the remaining control and must stay on."
    fi
  fi
fi

# ─── SABnzbd ─────────────────────────────────────────────────────────────────

echo
echo "SABnzbd"

if ! up sabnzbd; then
  skip "sabnzbd is not running"
else
  # Assert the specific redirect to /login/, not merely "not 200". SABnzbd also
  # answers 403 to every caller — including the *arrs — when it decides the
  # client is off-network, and a not-200 test reads that broken state as a pass.
  # This check did exactly that until the UI was found dead from the outside.
  sab_root=$(code "$SAB_URL/")
  sab_dest=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 8 "$SAB_URL/" 2>/dev/null || true)
  if [[ "$sab_root" == "200" ]]; then
    bad "SABnzbd: GET / returned 200 without a login"
    note "SABnzbd runs post-processing scripts — same class of risk as"
    note "qBittorrent's external-program setting. Set SAB_PASS and re-provision."
  elif [[ "$sab_root" == "303" && "$sab_dest" == */login/* ]]; then
    ok "SABnzbd: GET / redirects to the login page"
  elif [[ "$sab_root" == "403" ]]; then
    bad "SABnzbd: GET / returns 403 — the UI is refusing everyone, not asking for a login"
    note "inet_exposure is 0 and SABnzbd does not think the caller is local."
    note "Check misc/local_ranges against the source address it actually sees:"
    note "  docker compose exec sabnzbd grep -i refused /config/logs/sabnzbd.log"
  else
    bad "SABnzbd: GET / returned $sab_root, expected a 303 to /login/"
  fi

  # Only the [misc] section is pulled out of the container, never the whole
  # file. sabnzbd.ini also holds the news provider account under [servers], and
  # an authentication audit has no business ever holding those credentials.
  # Narrowing the read is a stronger guarantee than remembering to mask output.
  misc=$(docker compose exec -T sabnzbd \
    sh -c 'sed -n "/^\[misc\]/,/^\[[a-z]/p" /config/sabnzbd.ini' 2>/dev/null || true)

  if [[ -z "$misc" ]]; then
    skip "SABnzbd: could not read the [misc] section of sabnzbd.ini"
  else
    # inet_exposure 0 keeps the API off any external interface regardless of
    # what the container is published on.
    if [[ "$(grep -m1 '^inet_exposure' <<<"$misc" | tr -d ' ' | cut -d= -f2)" == "0" ]]; then
      ok "SABnzbd: inet_exposure is 0"
    else
      bad "SABnzbd: inet_exposure is not 0"
    fi
    # Anchored to [misc] by construction. Run against the whole file this also
    # matches the provider password under [servers], and then reports a web UI
    # password as set when there is none — a false pass on the check that
    # matters most, since SABnzbd runs post-processing scripts.
    if grep -qE '^password = .+' <<<"$misc"; then
      ok "SABnzbd: a password is set"
    else
      bad "SABnzbd: no password is set"
    fi
  fi
fi

# ─── Bazarr ──────────────────────────────────────────────────────────────────

echo
echo "Bazarr"

if ! up bazarr; then
  skip "bazarr is not running"
else
  # Bazarr serves its SPA shell at 200 whether or not you are logged in, so the
  # status code proves nothing. The config is the only reliable signal.
  #
  # Sliced inside the container for the same reason as SABnzbd above: the rest
  # of config.yaml holds the subtitle providers' account credentials.
  auth_block=$(docker compose exec -T bazarr \
    sh -c 'sed -n "/^auth:/,/^[a-z]/p" /config/config/config.yaml' 2>/dev/null || true)

  if [[ -z "$auth_block" ]]; then
    skip "Bazarr: could not read the auth block of config.yaml"
  else
    if grep -qE '^\s+type:\s*form' <<<"$auth_block"; then
      ok "Bazarr: form authentication enabled"
    else
      bad "Bazarr: authentication type is not 'form' — the UI has no login"
      note "Bazarr has full write access to the library. Set BAZARR_PASS and re-provision."
    fi
    if grep -qE '^\s+password:\s*\S' <<<"$auth_block"; then
      ok "Bazarr: a password is set"
    else
      bad "Bazarr: no password is set"
    fi
  fi
fi

# ─── Jellyfin ────────────────────────────────────────────────────────────────

echo
echo "Jellyfin"

if ! up jellyfin; then
  skip "jellyfin is not running"
else
  wizard=$(curl -fsS --max-time 8 "$JELLYFIN_URL/System/Info/Public" 2>/dev/null \
           | jq -r '.StartupWizardCompleted // "unknown"')
  if [[ "$wizard" == "true" ]]; then
    ok "Jellyfin: the setup wizard is complete"
  else
    bad "Jellyfin: the setup wizard has NOT been completed"
    note "Until it is, the first visitor to this port becomes the Jellyfin admin"
    note "— and Jellyseerr authenticates against Jellyfin, so that is the whole"
    note "household front door. Finish it before widening BIND_ADDR off loopback."
  fi

  if [[ "$(code "$JELLYFIN_URL/Users")" == "401" ]]; then
    ok "Jellyfin: the user list requires authentication"
  else
    bad "Jellyfin: GET /Users did not return 401"
  fi
fi

# ─── Jellyseerr ──────────────────────────────────────────────────────────────

echo
echo "Jellyseerr"

if ! up jellyseerr; then
  skip "jellyseerr is not running"
else
  init=$(curl -fsS --max-time 8 "$SEERR_URL/api/v1/settings/public" 2>/dev/null \
         | jq -r '.initialized // "unknown"')
  if [[ "$init" == "true" ]]; then
    ok "Jellyseerr: initialised"
  else
    bad "Jellyseerr: still uninitialised — /setup is open to the first visitor"
    note "Finish it before widening BIND_ADDR off loopback."
  fi

  if [[ "$(code "$SEERR_URL/")" == "200" ]]; then
    bad "Jellyseerr: GET / returned 200 without a login"
  else
    ok "Jellyseerr: GET / redirects an anonymous request to the login page"
  fi
fi

# ─── Cleanuparr ──────────────────────────────────────────────────────────────
#
# The second app in this stack whose authentication is asserted once and assumed
# thereafter, for the same reason as wg-easy below: there is no environment
# variable for it. The account is created through a setup flow and lives in
# Cleanuparr's own database, so a wiped /config comes back with the wizard open
# and the first visitor becomes the administrator — the same failure the *arrs
# are protected from by D12 and D18, and which nothing but this check would
# report (decisions.md D30).
#
# What a session on it is worth: Cleanuparr holds the qBittorrent credential and
# every *arr API key, so it reaches the same arbitrary command execution spec
# §5.3 is about, one step removed.

echo
echo "Cleanuparr"

if ! up cleanuparr; then
  skip "cleanuparr is not running"
else
  # /api/auth/status is deliberately anonymous — it is what the login page reads
  # to decide what to draw — which makes it exactly the right thing to audit.
  status=$(curl -fsS --max-time 8 "$CLEANUPARR_URL/api/auth/status" 2>/dev/null || echo '{}')

  if [[ "$(jq -r '.setupCompleted // "unknown"' <<<"$status")" == "true" ]]; then
    ok "Cleanuparr: setup completed — the account-creation flow is closed"
  else
    bad "Cleanuparr: setup is incomplete — the first visitor becomes the admin"
    note "Open http://<lan-ip>:${CLEANUPARR_PORT:-11011} and create the account now."
  fi

  # The local-address bypass. Its built-in trusted ranges include 172.16.0.0/12,
  # which is Docker's default pool — so switching this on does not merely trust
  # the LAN, it hands an unauthenticated session to every container on the
  # bridge. Precisely the shape of the DisabledForLocalAddresses trap in D18.
  if [[ "$(jq -r '.authBypassActive // "unknown"' <<<"$status")" == "false" ]]; then
    ok "Cleanuparr: local-address auth bypass is off"
  else
    bad "Cleanuparr: local-address auth bypass is ACTIVE"
    note "Settings -> General -> Authentication. Its trusted ranges include the"
    note "Docker bridge (172.16.0.0/12), so this exempts the whole stack."
  fi

  # Everything under /api/configuration is [Authorize]. The SPA shell at / is
  # served at 200 either way, as Bazarr's is, so it proves nothing.
  if [[ "$(code "$CLEANUPARR_URL/api/configuration/general")" == "401" ]]; then
    ok "Cleanuparr: the configuration API rejects an unauthenticated request"
  else
    bad "Cleanuparr: GET /api/configuration/general did not return 401"
  fi
fi

# ─── wg-easy ─────────────────────────────────────────────────────────────────
#
# This check carries more weight than the others. The *arrs re-apply their auth
# configuration from the environment on every start, so a wiped config recovers
# itself. wg-easy v15 does not: INIT_* runs once, on first start, and after that
# the credentials live in its database. Lose /etc/wireguard — a bad restore, a
# `docker compose down -v`, a new CONFIG_ROOT — and the container comes back
# with INIT_* re-applied if the variables are still set, or an open setup wizard
# if they are not. Either way nothing but this check would tell you.
#
# The stakes: an unauthenticated wg-easy admin can mint a peer, and a peer is on
# the LAN (decisions.md D26).

echo
echo "wg-easy"

if ! up wg-easy; then
  skip "wg-easy is not running"
else
  WG_URL="http://127.0.0.1:${WG_UI_PORT:-51821}"

  # v15 answers the session endpoint 401 when unauthenticated. If a future
  # version moves it, this reports 000/404 and fails loudly rather than passing
  # by accident — which is the right direction for an auth check to break in.
  sess=$(code "$WG_URL/api/session")
  case "$sess" in
    401|403)
      ok "wg-easy: the session endpoint requires authentication" ;;
    200)
      bad "wg-easy: GET /api/session returned 200 — the UI has an open session"
      note "Anyone who can reach ${WG_UI_BIND:-<lan-ip>}:${WG_UI_PORT:-51821} can add a VPN peer." ;;
    000)
      bad "wg-easy: no answer on ${WG_UI_PORT:-51821} — is INSECURE=true set?"
      note "v15 serves HTTPS unless told otherwise; this probe speaks plain HTTP." ;;
    *)
      bad "wg-easy: GET /api/session returned $sess, expected 401"
      note "Confirm the endpoint against the running version before trusting this." ;;
  esac

  # The setup wizard is the failure mode that matters. If it is reachable, the
  # database is empty and the next visitor becomes the VPN administrator.
  #
  # 404 is the ONLY pass. This used to treat anything that was not 200 as a
  # pass, which meant 000 — no answer at all — was reported ok: the check most
  # able to hurt you, failing in the reassuring direction. An unreachable probe
  # proves nothing about whether the wizard is open, and the session check above
  # already establishes what a 000 here means.
  setup=$(code "$WG_URL/api/setup")
  case "$setup" in
    404)
      ok "wg-easy: no setup wizard is exposed" ;;
    200)
      bad "wg-easy: the setup wizard is OPEN — /etc/wireguard has been lost"
      note "The first visitor becomes the VPN admin. Stop the container now." ;;
    000)
      bad "wg-easy: no answer from /api/setup — the wizard state is UNKNOWN"
      note "Not a pass. Check INSECURE=true and that WG_UI_PORT is listening:"
      note "  docker compose logs wg-easy; ss -lntp | grep ${WG_UI_PORT:-51821}" ;;
    *)
      bad "wg-easy: GET /api/setup returned $setup, expected 404"
      note "Confirm against the running version before trusting this." ;;
  esac
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
else
  printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
fi
echo
exit $(( fail > 0 ? 1 : 0 ))
