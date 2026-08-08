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
#     The tailnet-facing admin UIs become anonymous-admin while remote access
#     carries on working perfectly. Verified: with that setting, GET / returns
#     200 with no login.
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
PROWLARR_URL="http://127.0.0.1:${PROWLARR_PORT:-9696}"
JELLYFIN_URL="http://127.0.0.1:${JELLYFIN_PORT:-8096}"
SEERR_URL="http://127.0.0.1:${SEERR_PORT:-5055}"
SAB_URL="http://127.0.0.1:${SAB_PORT:-8085}"
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
echo "Sonarr / Radarr / Prowlarr"
audit_arr Sonarr   "$SONARR_URL"   "${SONARR_API_KEY:-}"   v3
audit_arr Radarr   "$RADARR_URL"   "${RADARR_API_KEY:-}"   v3
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

    # Deliberately off (decisions.md D13) so qbit.<host>.ts.net works at all.
    # CSRF protection is the one that matters and must stay on.
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
  if [[ "$(code "$SAB_URL/")" == "200" ]]; then
    bad "SABnzbd: GET / returned 200 without a login"
    note "SABnzbd runs post-processing scripts — same class of risk as"
    note "qBittorrent's external-program setting. Set SAB_PASS and re-provision."
  else
    ok "SABnzbd: GET / requires a login"
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

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
else
  printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
fi
echo
exit $(( fail > 0 ? 1 : 0 ))
