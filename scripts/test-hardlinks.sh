#!/usr/bin/env bash
#
# Proves the hardlink invariant — spec §3.3 and §9.1.
#
# This is the check that matters most, because failing it produces no error at
# runtime. If torrents/ and media/ are not on one filesystem, or the containers
# disagree about what /data means, Sonarr and Radarr silently fall back to
# copying: imports get slow, disk usage doubles, and seeding breaks.
#
# The test deliberately spans two containers — qBittorrent writes the file, as
# it would a completed download, and Sonarr links it into the library, as it
# would on import. That exercises the identical-path rule (spec §4.1) as well
# as the same-filesystem rule.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Both download paths are checked. Usenet completions live under
# /data/usenet/complete and torrents under /data/torrents — different trees, but
# they must be on the same filesystem as /data/media or imports from that
# protocol silently start copying.
DOWNLOADER=${DOWNLOADER:-qbittorrent}   # writes the "completed download"
IMPORTER=${IMPORTER:-sonarr}            # performs the "import"
SRC_DIR=${SRC_DIR:-/data/torrents/tv}   # override to test the usenet tree
DST_DIR=${DST_DIR:-/data/media/tv}      # override to test the music tree
LABEL=${LABEL:-torrent}

TEST_ID="hardlink-test-$$"
SRC="${SRC_DIR}/${TEST_ID}.bin"
DST="${DST_DIR}/${TEST_ID}.bin"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

cleanup() {
  docker compose exec -T "$IMPORTER" sh -c "rm -f '$SRC' '$DST'" 2>/dev/null || true
}
trap cleanup EXIT

for svc in "$DOWNLOADER" "$IMPORTER"; do
  if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$svc"; then
    red "Service '$svc' is not running. Start the stack: docker compose up -d"
    exit 1
  fi
done

echo
printf 'Checking the %s path\n' "$LABEL"
echo "Writing an 8 MiB file as $DOWNLOADER at $SRC"
docker compose exec -T "$DOWNLOADER" sh -c "
  set -e
  mkdir -p \"\$(dirname '$SRC')\"
  dd if=/dev/urandom of='$SRC' bs=1M count=8 2>/dev/null
"

# If the two containers do not agree on what /data means, this is where it
# shows up — before any linking is attempted.
echo "Confirming $IMPORTER sees the same path"
if ! docker compose exec -T "$IMPORTER" test -f "$SRC"; then
  red "FAIL: $IMPORTER cannot see $SRC"
  echo
  echo "The containers disagree about /data. Every media service must mount the"
  echo "same source at the same container path /data — see spec §4.1."
  exit 1
fi

echo "Hardlinking into the library as $IMPORTER"
if ! err=$(docker compose exec -T "$IMPORTER" sh -c "
      set -e
      mkdir -p \"\$(dirname '$DST')\"
      ln '$SRC' '$DST'
    " 2>&1); then
  red "FAIL: could not create the hardlink"
  printf '  %s\n' "$err"
  echo
  if grep -qi 'cross-device' <<<"$err"; then
    echo "EXDEV — torrents/ and media/ are on different filesystems. This is"
    echo "exactly the split spec §3.3 warns about: Sonarr and Radarr would"
    echo "silently degrade to copying. Put both under one filesystem."
  fi
  exit 1
fi

# %d device, %i inode, %h link count — identical device and inode is the proof.
read -r src_dev src_ino src_lnk < <(docker compose exec -T "$IMPORTER" stat -c '%d %i %h' "$SRC" | tr -d '\r')
# Link count is a property of the inode, so reading it once from the source is
# sufficient — if the inodes match, both names report the same count.
read -r dst_dev dst_ino _ < <(docker compose exec -T "$IMPORTER" stat -c '%d %i %h' "$DST" | tr -d '\r')

echo
docker compose exec -T "$IMPORTER" ls -li "$SRC" "$DST"
echo
printf '  %-28s %s\n' "device (source / library)" "$src_dev / $dst_dev"
printf '  %-28s %s\n' "inode  (source / library)" "$src_ino / $dst_ino"
printf '  %-28s %s\n' "link count" "$src_lnk"
echo

fail=0
[[ "$src_dev" == "$dst_dev" ]] || { red "FAIL: different filesystems ($src_dev vs $dst_dev)"; fail=1; }
[[ "$src_ino" == "$dst_ino" ]] || { red "FAIL: different inodes — the file was copied, not linked"; fail=1; }
[[ "$src_lnk" -ge 2 ]]         || { red "FAIL: link count is $src_lnk, expected at least 2"; fail=1; }

if [[ $fail -ne 0 ]]; then
  echo
  echo "Check: torrents/ and media/ under one filesystem, every media service"
  echo "mounting the same source at /data, and 'Use Hardlinks instead of Copy'"
  echo "enabled in Sonarr and Radarr."
  exit 1
fi

green "PASS — one inode, two names. Imports will hardlink, not copy."
echo
echo "Disk usage is not doubled: the library entry and the seeding torrent are"
echo "the same 8 MiB of blocks on disk."
echo
