#!/usr/bin/env bash
#
# Host provisioning for the Debian target — spec §2, §3, §5.3.
#
# Idempotent: every step checks before it acts, so re-running is safe and is
# the normal way to apply a changed .env.
#
# This script edits /etc/fstab, creates a system user, installs a firewall and
# can format a disk. It cannot be rehearsed on the macOS dev box, so the first
# run on the target should be:
#
#     sudo ./setup.sh --dry-run --disk /dev/sdX
#
# which prints every mutation without applying any of it.
#
# Disk formatting is opt-in and guarded: --format-disk refuses any device that
# already carries a filesystem or partition table. The script will not be the
# thing that destroys a populated disk.
#
# Usage:
#   sudo ./setup.sh [--dry-run] [--disk /dev/sdX] [--format-disk] [--skip-packages]
#
#   --disk DEV       Block device holding the media filesystem. Needed for the
#                    fstab step; omit it if the disk is already mounted.
#   --format-disk    Format DEV as ext4 first. Requires --disk. Refuses a
#                    device that is not blank.
#   --dry-run        Print what would change; touch nothing.
#   --skip-packages  Skip apt entirely (useful when re-running).

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

MOUNT_POINT=${MOUNT_POINT:-/mnt/disk1}
DATA_DIR="${MOUNT_POINT}/data"
BIND_TARGET=${BIND_TARGET:-/data}
MEDIA_USER=${MEDIA_USER:-media}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# PUID/PGID/SMTP settings come from .env so there is one source of truth
# shared with docker-compose.yml.
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
PUID=${PUID:-1000}
PGID=${PGID:-1000}

DRY_RUN=false
FORMAT_DISK=false
SKIP_PACKAGES=false
DISK_DEV=""

# ─── Plumbing ────────────────────────────────────────────────────────────────

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31mError:\033[0m %s\n\n' "$1" >&2; exit 1; }

run() {
  if $DRY_RUN; then
    printf '  \033[36m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# write_file <path> <mode> — content on stdin
write_file() {
  local path=$1 mode=$2 content
  content=$(cat)
  if $DRY_RUN; then
    printf '  \033[36m[dry-run]\033[0m write %s (mode %s):\n' "$path" "$mode"
    while IFS= read -r line; do printf '      | %s\n' "$line"; done <<<"$content"
  else
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
    ok "wrote $path"
  fi
}

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true ;;
    --format-disk)   FORMAT_DISK=true ;;
    --skip-packages) SKIP_PACKAGES=true ;;
    --disk)          DISK_DEV=${2:-}; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *)               die "Unknown argument: $1" ;;
  esac
  shift
done

$FORMAT_DISK && [[ -z "$DISK_DEV" ]] && die "--format-disk requires --disk /dev/sdX"

# ─── Preconditions ───────────────────────────────────────────────────────────

preflight() {
  step "Preflight"

  # Hard guard. This script is Debian-specific and destructive; running it on
  # the macOS dev box must be an error, not a partial application.
  [[ "$(uname -s)" == "Linux" ]] || die "This script is for the Debian target, not $(uname -s). See docs/dev-testing.md."
  [[ -f /etc/debian_version ]]   || die "Not a Debian system — /etc/debian_version is absent."
  ok "Debian $(cat /etc/debian_version)"

  if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
    die "Must run as root. Try: sudo $0 $*"
  fi

  $DRY_RUN && warn "DRY RUN — nothing will be modified"
}

# ─── Steps ───────────────────────────────────────────────────────────────────

install_packages() {
  step "Packages"
  if $SKIP_PACKAGES; then info "skipped (--skip-packages)"; return; fi

  run apt-get update -qq
  run apt-get install -y -qq ca-certificates curl gnupg

  # Docker must come from Docker's own repository, not Debian's docker.io.
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    ok "added Docker GPG key"
  else
    ok "Docker GPG key already present"
  fi

  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    local codename arch
    # shellcheck disable=SC1091  # /etc/os-release always exists on Debian
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    write_file /etc/apt/sources.list.d/docker.list 0644 <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF
    run apt-get update -qq
  else
    ok "Docker apt repository already configured"
  fi

  run apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    smartmontools intel-gpu-tools vainfo \
    msmtp msmtp-mta \
    ufw curl git htop
  ok "packages installed"

  run systemctl enable --now docker
  ok "docker enabled at boot (required for unattended recovery, spec §9.1)"
}

create_media_user() {
  step "Service user"

  # GID/UID 1000 is often already taken by the first human user on a Debian
  # install. Fail clearly rather than silently binding the media tree to
  # someone else's account.
  if getent group "$PGID" >/dev/null 2>&1; then
    local existing; existing=$(getent group "$PGID" | cut -d: -f1)
    if [[ "$existing" != "$MEDIA_USER" ]]; then
      die "GID $PGID is already used by group '$existing'. Pick a free PGID in .env and keep it in step with docker-compose.yml."
    fi
    ok "group $MEDIA_USER ($PGID) exists"
  else
    run groupadd -g "$PGID" "$MEDIA_USER"
    ok "created group $MEDIA_USER ($PGID)"
  fi

  if getent passwd "$PUID" >/dev/null 2>&1; then
    local existing; existing=$(getent passwd "$PUID" | cut -d: -f1)
    if [[ "$existing" != "$MEDIA_USER" ]]; then
      die "UID $PUID is already used by user '$existing'. Pick a free PUID in .env."
    fi
    ok "user $MEDIA_USER ($PUID) exists"
  else
    run useradd -u "$PUID" -g "$PGID" -M -s /usr/sbin/nologin "$MEDIA_USER"
    ok "created user $MEDIA_USER ($PUID)"
  fi

  # /dev/dri access for Jellyfin's Quick Sync transcoding (spec §4.2).
  if getent group render >/dev/null 2>&1; then
    if id -nG "$MEDIA_USER" 2>/dev/null | tr ' ' '\n' | grep -qx render; then
      ok "$MEDIA_USER already in render group"
    else
      run usermod -aG render "$MEDIA_USER"
      ok "added $MEDIA_USER to render group"
    fi
  else
    warn "no 'render' group — the iGPU is likely disabled in BIOS (spec §1.1)"
  fi
}

format_disk() {
  $FORMAT_DISK || return 0
  step "Format $DISK_DEV"

  [[ -b "$DISK_DEV" ]] || die "$DISK_DEV is not a block device"

  # Refuse anything that is not demonstrably blank. Wiping is a deliberate
  # manual act, never a side effect of running setup.
  local sigs
  sigs=$(lsblk -no FSTYPE,PARTTYPE "$DISK_DEV" 2>/dev/null | tr -d ' \n')
  if [[ -n "$sigs" ]] || blkid "$DISK_DEV" >/dev/null 2>&1; then
    die "$DISK_DEV already carries a filesystem or partition table.
       Refusing to format — this script will not destroy existing data.
       Inspect it with:  lsblk -f $DISK_DEV
       If you are certain it should be wiped, do so manually first:
         wipefs -a $DISK_DEV"
  fi

  if findmnt -S "$DISK_DEV" >/dev/null 2>&1; then
    die "$DISK_DEV is currently mounted. Unmount it before formatting."
  fi

  # -m 0: the default 5% root reserve would waste ~400 GB on an 8 TB disk and
  # serves no purpose on a data-only filesystem (spec §3.2).
  run mkfs.ext4 -m 0 -L media1 "$DISK_DEV"
  ok "formatted $DISK_DEV as ext4 with no root reserve"
}

configure_fstab() {
  step "Mounts"

  if [[ -z "$DISK_DEV" ]]; then
    info "no --disk given; assuming the media filesystem is already mounted"
    if findmnt "$MOUNT_POINT" >/dev/null 2>&1; then
      ok "$MOUNT_POINT is mounted"
    else
      warn "$MOUNT_POINT is not mounted — pass --disk /dev/sdX to add fstab entries"
    fi
  else
    local uuid
    uuid=$(blkid -s UUID -o value "$DISK_DEV" 2>/dev/null || true)
    if [[ -z "$uuid" ]]; then
      if $DRY_RUN; then
        uuid="<uuid-of-$DISK_DEV>"
        info "dry run: UUID unknown until the disk is formatted"
      else
        die "Could not read a UUID from $DISK_DEV. Format it first with --format-disk."
      fi
    fi

    run mkdir -p "$MOUNT_POINT"

    # Back up before touching fstab — a broken fstab means an unbootable box.
    if ! $DRY_RUN && [[ ! -f /etc/fstab.bak ]]; then
      cp /etc/fstab /etc/fstab.bak
      ok "backed up /etc/fstab to /etc/fstab.bak"
    fi

    if grep -qE "^[^#]*[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab; then
      ok "fstab entry for $MOUNT_POINT already present"
    else
      if $DRY_RUN; then
        printf '  \033[36m[dry-run]\033[0m append to /etc/fstab:\n      | UUID=%s  %s  ext4  defaults,noatime  0  2\n' "$uuid" "$MOUNT_POINT"
      else
        printf 'UUID=%s  %s  ext4  defaults,noatime  0  2\n' "$uuid" "$MOUNT_POINT" >> /etc/fstab
        ok "added $MOUNT_POINT to fstab"
      fi
    fi

    run mkdir -p "$DATA_DIR" "$BIND_TARGET"

    # The bind mount is deliberate indirection: swapping it for a mergerfs pool
    # later needs no container changes and breaks no hardlinks (spec §3.1).
    if grep -qE "^[^#]*[[:space:]]${BIND_TARGET}[[:space:]]" /etc/fstab; then
      ok "fstab bind entry for $BIND_TARGET already present"
    else
      if $DRY_RUN; then
        printf '  \033[36m[dry-run]\033[0m append to /etc/fstab:\n      | %s  %s  none  bind  0  0\n' "$DATA_DIR" "$BIND_TARGET"
      else
        printf '%s  %s  none  bind  0  0\n' "$DATA_DIR" "$BIND_TARGET" >> /etc/fstab
        ok "added $BIND_TARGET bind mount to fstab"
      fi
    fi

    if ! $DRY_RUN; then
      findmnt --verify --verbose >/dev/null 2>&1 || warn "findmnt reports issues with /etc/fstab — review before rebooting"
      mount -a
      ok "mounted everything in fstab"
    fi
  fi
}

create_tree() {
  step "Directory tree"

  # torrents/, usenet/ and media/ are siblings on one filesystem so imports
  # hardlink instead of copying (spec §3.3). Splitting them degrades silently.
  local d
  for d in torrents/movies       torrents/tv       torrents/anime \
           usenet/incomplete \
           usenet/complete/movies usenet/complete/tv usenet/complete/anime \
           media/movies          media/tv          media/anime; do
    run mkdir -p "${DATA_DIR}/${d}"
  done
  run chown -R "${PUID}:${PGID}" "$DATA_DIR"
  run chmod -R 775 "$DATA_DIR"
  ok "tree created under $DATA_DIR, owned by ${PUID}:${PGID}"

  run mkdir -p "${CONFIG_ROOT:-/opt/mediaserver}"
  run chown -R "${PUID}:${PGID}" "${CONFIG_ROOT:-/opt/mediaserver}"
  ok "config root ready at ${CONFIG_ROOT:-/opt/mediaserver}"
}

configure_mail() {
  step "Mail transport"

  # smartd shells out to /usr/sbin/sendmail, which a minimal Debian install
  # does not provide. Without this, SMART alerts fail silently — which defeats
  # the entire point of monitoring a single-drive array (docs/decisions.md Q3).
  if [[ -z "${SMTP_HOST:-}" || -z "${ALERT_EMAIL:-}" ]]; then
    warn "SMTP_HOST/ALERT_EMAIL unset in .env — skipping mail setup."
    warn "SMART alerts will NOT be delivered until this is configured."
    return 0
  fi

  write_file /etc/msmtprc 0600 <<EOF
# Managed by setup.sh. Relays SMART alerts; mode 0600 as it holds a password.
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT:-587}
from           ${SMTP_FROM:-$ALERT_EMAIL}
user           ${SMTP_USER:-}
password       ${SMTP_PASS:-}
EOF

  run chown root:root /etc/msmtprc
  ok "msmtp configured to relay via ${SMTP_HOST}"
  info "test it with:  echo test | mail -s smartd-test ${ALERT_EMAIL}"
}

configure_smartd() {
  step "SMART monitoring"

  if [[ -z "${ALERT_EMAIL:-}" ]]; then
    warn "ALERT_EMAIL unset — writing a schedule with no delivery configured"
  fi

  # Prefer a stable /dev/disk/by-id path: kernel names like /dev/sda can move
  # between boots, which would silently monitor the wrong disk.
  local dev_spec="DEVICESCAN"
  if [[ -n "$DISK_DEV" ]]; then
    local byid
    byid=$(find /dev/disk/by-id -lname "*${DISK_DEV##*/}" ! -name "*-part*" 2>/dev/null | head -1 || true)
    dev_spec=${byid:-$DISK_DEV}
  fi

  # Built as one line: a trailing continuation with nothing after it is a
  # syntax error in smartd.conf, which is what an empty ALERT_EMAIL would leave.
  local mail_opts=""
  if [[ -n "${ALERT_EMAIL:-}" ]]; then
    mail_opts=" -m ${ALERT_EMAIL} -M exec /usr/share/smartmontools/smartd-runner"
  fi

  # -a  all standard attributes
  # -o on / -S on  enable offline collection and attribute autosave
  # -s (S/../.././02|L/../../6/03)  short test daily 02:00, long test Sat 03:00
  # -m  where to mail failures      -M exec  also run the runner script
  write_file /etc/smartd.conf 0644 <<EOF
# Managed by setup.sh — spec §3.5.
# A single-drive build has no redundancy, so early warning is the only
# protection. Alerts fire on attribute failure and reallocated-sector growth.
${dev_spec} -a -o on -S on -s (S/../.././02|L/../../6/03)${mail_opts}
EOF

  run systemctl enable --now smartd
  run systemctl restart smartd
  ok "smartd enabled: short test daily 02:00, long test Saturday 03:00"
  info "send a test alert by adding -M test to the device line, then: systemctl restart smartd"
  info "remove -M test afterwards, or every restart will mail you"
}

configure_firewall() {
  step "Firewall"

  run ufw --force default deny incoming
  run ufw --force default allow outgoing
  run ufw allow OpenSSH

  if ip link show tailscale0 >/dev/null 2>&1; then
    run ufw allow in on tailscale0
    ok "allowed all traffic on tailscale0"
  else
    warn "tailscale0 not found — install Tailscale and run 'tailscale up', then re-run this script"
  fi

  # Spec §5.3 says "allow SSH and the Tailscale interface; deny inbound
  # otherwise", but taken literally that also blocks §5.1's direct LAN access
  # — including Infuse on the Apple TV reaching Jellyfin, which is the primary
  # playback path. Allowing the LAN subnet reconciles the two: the home network
  # gets through, the internet still cannot, and there is no port forwarding.
  # See docs/decisions.md D1.
  if [[ -n "${LAN_SUBNET:-}" ]]; then
    run ufw allow from "$LAN_SUBNET"
    ok "allowed inbound from LAN ${LAN_SUBNET}"
  else
    warn "LAN_SUBNET is unset in .env, so this will be a tailnet-only box:"
    warn "  LAN clients cannot reach Jellyfin or any *arr UI by IP and port."
    warn "  Infuse on the Apple TV will not find Jellyfin unless the Apple TV"
    warn "  is itself on the tailnet."
    warn "Set LAN_SUBNET (e.g. 192.168.1.0/24) in .env and re-run to allow it."
  fi

  run ufw --force enable
  ok "ufw enabled"
}

report() {
  step "Values for .env"

  local render_gid tailscale_ip
  render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
  tailscale_ip=$(tailscale ip -4 2>/dev/null | head -1 || true)

  printf '  RENDER_GID=%s\n' "${render_gid:-<none — iGPU disabled in BIOS?>}"
  printf '  CADDY_BIND_ADDR=%s\n' "${tailscale_ip:-<none — run: tailscale up>}"
  printf '  CADDY_DOMAIN=%s\n' "$(tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || echo '<host>.ts.net')"

  step "Next"
  info "1. Put the values above into .env"
  info "2. Verify the iGPU:  vainfo | grep -Ei 'h264|hevc'"
  info "3. Start the stack:  docker compose up -d"
  info "4. Prove hardlinking: ./scripts/test-hardlinks.sh"
  info "5. Work through docs/verification.md"
  echo
}

# ─── Main ────────────────────────────────────────────────────────────────────

preflight "$@"
install_packages
create_media_user
format_disk
configure_fstab
create_tree
configure_mail
configure_smartd
configure_firewall
report
