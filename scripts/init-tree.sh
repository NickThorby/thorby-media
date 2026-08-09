#!/usr/bin/env bash
#
# Creates the spec §3.1 directory tree inside /data, from within a running
# container so it works regardless of what backs the volume.
#
# setup.sh already does this on the host, so running it again is a harmless
# no-op. It exists for the case where /data was replaced or emptied without
# re-running setup.sh.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SVC=${SVC:-sonarr}

# The tree must end up owned by the same UID/GID the containers run as, or the
# *arr apps cannot write to it. `docker compose exec` runs as root, so read the
# intended values rather than inheriting the exec user's.
# shellcheck disable=SC1091
[[ -f .env ]] && source ./.env
PUID=${PUID:-1000}
PGID=${PGID:-1000}

if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$SVC"; then
  echo "Service '$SVC' is not running. Start the stack first: docker compose up -d" >&2
  exit 1
fi

echo "Creating /data tree via the $SVC container (owner ${PUID}:${PGID})..."

# torrents/ and media/ must be siblings under one filesystem so imports can
# hardlink rather than copy (spec §3.3).
docker compose exec -T -e PUID="$PUID" -e PGID="$PGID" "$SVC" sh -c '
  set -e
  for d in torrents/movies       torrents/tv       torrents/anime       torrents/music \
           usenet/incomplete \
           usenet/complete/movies usenet/complete/tv usenet/complete/anime usenet/complete/music \
           media/movies          media/tv          media/anime          media/music; do
    mkdir -p "/data/$d"
  done
  chown -R "${PUID}:${PGID}" /data
  chmod -R 775 /data
'

echo
docker compose exec -T "$SVC" find /data -maxdepth 2 -type d -exec ls -ld {} + | sort -k9
echo
echo "Done."
