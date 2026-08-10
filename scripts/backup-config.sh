#!/usr/bin/env bash
#
# Backs up ${CONFIG_ROOT} — every app's database and settings — to the media
# disk, with retention.
#
# Why this exists: the media on /mnt/disk1 can be re-acquired, but the state in
# ${CONFIG_ROOT} cannot. Watch history, request history, quality profiles,
# indexer configuration, subtitle mappings and every user account live there,
# on the single SSD that also holds the OS. decisions.md D7 says to back this up
# before pulling new images, and until now nothing implemented that.
#
# The backup lands on /mnt/disk1 rather than the SSD, so an SSD failure does not
# take the backups with it. That is one disk, not an offsite copy: spec §3.6 is
# explicit that neither mergerfs nor SnapRAID is a backup, and this is not one
# either. It protects against the SSD dying and against a bad update, which are
# the two failures that actually happen.
#
# SQLite is the reason this is not just a tar. Copying a database that is being
# written produces a file that restores cleanly and is subtly corrupt. Sonarr,
# Radarr and Prowlarr have a native backup command that checkpoints properly, so
# this triggers those and copies the result. Apps without one are stopped for
# the few seconds it takes to copy them.
#
# Usage:
#   ./scripts/backup-config.sh              back up, prune to BACKUP_KEEP
#   ./scripts/backup-config.sh --list       list what is there
#   BACKUP_DIR=/elsewhere ./scripts/backup-config.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31mError:\033[0m %s\n\n' "$1" >&2; exit 1; }

[[ -f .env ]] || die "No .env found. Copy .env.example to .env first."

set -a
# shellcheck disable=SC1091
source ./.env
set +a

CONFIG_ROOT=${CONFIG_ROOT:-/opt/mediaserver}
BACKUP_DIR=${BACKUP_DIR:-/mnt/disk1/backups}
BACKUP_KEEP=${BACKUP_KEEP:-7}

# Apps with a native, SQLite-safe backup command, and the API version to reach
# it on. Triggering these is strictly better than copying their database files.
ARR_APPS="sonarr:v3:${SONARR_PORT:-8989}:${SONARR_API_KEY:-}
radarr:v3:${RADARR_PORT:-7878}:${RADARR_API_KEY:-}
prowlarr:v1:${PROWLARR_PORT:-9696}:${PROWLARR_API_KEY:-}"

if [[ "${1:-}" == "--list" ]]; then
  step "Backups in $BACKUP_DIR"
  if [[ -d "$BACKUP_DIR" ]]; then
    ls -lh "$BACKUP_DIR"/mediaserver-config-*.tar.gz 2>/dev/null || skip "none yet"
  else
    skip "$BACKUP_DIR does not exist"
  fi
  echo
  exit 0
fi

# The backup target is on the media disk, which is a separate mount. If that
# mount is missing, writing would silently fill the SSD with what is supposed to
# be the off-SSD copy — the same class of mistake as containers writing into an
# unmounted /data (verification.md item 8).
parent=$(dirname "$BACKUP_DIR")
[[ -d "$parent" ]] || die "$parent does not exist. Is /mnt/disk1 mounted?"
mkdir -p "$BACKUP_DIR"

[[ -d "$CONFIG_ROOT" ]] || die "CONFIG_ROOT $CONFIG_ROOT does not exist"

# Timestamp comes from the filesystem, so a restore can be matched to a date
# without parsing the archive.
stamp=$(date +%Y%m%d-%H%M%S)
archive="$BACKUP_DIR/mediaserver-config-${stamp}.tar.gz"

# ─── Native *arr backups ─────────────────────────────────────────────────────

step "Triggering native backups"

while IFS=: read -r app ver port key; do
  [[ -n "$app" ]] || continue
  if [[ -z "$key" ]]; then
    warn "$app: no API key in .env, skipping its native backup"
    continue
  fi
  if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "$app"; then
    skip "$app is not running"
    continue
  fi
  if curl -fsS -o /dev/null --max-time 30 -X POST \
       -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
       -d '{"name":"Backup"}' \
       "http://127.0.0.1:${port}/api/${ver}/command" 2>/dev/null; then
    ok "$app backup command queued"
  else
    warn "$app backup command failed — its database will still be copied below"
  fi
done <<<"$ARR_APPS"

# The command is asynchronous and writes into /config/Backups. A few seconds is
# enough for a home-sized database; the tar below captures whatever is there.
sleep 10

# ─── Archive ─────────────────────────────────────────────────────────────────

step "Archiving $CONFIG_ROOT"

# Caddy's certificate store and the Recyclarr guide clone are both reproducible
# — Let's Encrypt reissues, and Recyclarr re-clones on next sync — and
# together they are most of the bulk. Logs are excluded for the same reason.
tar -czf "$archive" \
  --exclude='*/caddy/data/*' \
  --exclude='*/caddy/logs/*' \
  --exclude='*/recyclarr/repositories/*' \
  --exclude='*/jellyfin/cache/*' \
  --exclude='*/jellyfin/log/*' \
  --exclude='*/cleanuparr/logs/*' \
  --exclude='*/transcodes/*' \
  -C "$(dirname "$CONFIG_ROOT")" "$(basename "$CONFIG_ROOT")" 2>/dev/null \
  || die "tar failed writing $archive"

chmod 600 "$archive"
ok "$(du -h "$archive" | cut -f1)  $archive"

# ─── Retention ───────────────────────────────────────────────────────────────

step "Retention"

# The stamp is YYYYmmdd-HHMMSS, so a reverse lexical sort is newest-first
# without having to stat anything.
mapfile -t existing \
  < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'mediaserver-config-*.tar.gz' | sort -r)

pruned=0
i=0
for f in "${existing[@]}"; do
  if [[ $i -ge $BACKUP_KEEP ]]; then
    rm -f "$f"
    ok "pruned $(basename "$f")"
    pruned=$((pruned + 1))
  fi
  i=$((i + 1))
done

if [[ $pruned -eq 0 ]]; then
  skip "${#existing[@]} kept, nothing to prune (BACKUP_KEEP=$BACKUP_KEEP)"
fi

echo
printf '  %s\n' \
  "Restore:" \
  "  docker compose down" \
  "  tar -xzf $archive -C $(dirname "$CONFIG_ROOT")" \
  "  docker compose up -d" \
  "" \
  "Verify a backup actually restores before you need it — an untested" \
  "backup is not a backup (docs/verification.md item 10)."
echo
