#!/usr/bin/env bash
#
# Host provisioning for the Debian target — spec §2, §3, §5.3.
#
# Idempotent: every step checks before it acts, so re-running is safe and is
# the normal way to apply a changed .env.
#
# This script edits /etc/fstab, creates a system user, installs a firewall and
# can format a disk. The first run should always be:
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

  # Hard guard. This script is Debian-specific and destructive; a partial
  # application on some other OS must be an error rather than a surprise.
  [[ "$(uname -s)" == "Linux" ]] || die "This script is for the Debian target, not $(uname -s)."
  [[ -f /etc/debian_version ]]   || die "Not a Debian system — /etc/debian_version is absent."
  ok "Debian $(cat /etc/debian_version)"

  if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
    die "Must run as root. Try: sudo $0 $*"
  fi

  # Not `$DRY_RUN && warn ...`: as the last statement of a function that would
  # return 1 whenever DRY_RUN is false, and under `set -e` a non-zero return
  # from a top-level call exits the script. That silently aborted every real
  # (non-dry-run) invocation immediately after this step, which is exactly the
  # path that was never exercised because container testing always passes
  # --dry-run.
  if $DRY_RUN; then
    warn "DRY RUN — nothing will be modified"
  fi
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
    unattended-upgrades fail2ban \
    ufw curl git htop jq
  ok "packages installed"

  run systemctl enable --now docker
  ok "docker enabled at boot (required for unattended recovery, spec §9.1)"
}

secure_env_file() {
  step "Secrets"

  local envfile="${SCRIPT_DIR}/.env"
  if [[ ! -f "$envfile" ]]; then
    warn ".env not found — copy .env.example to .env before starting the stack"
    return 0
  fi

  # .env holds every password in the stack plus the Usenet provider account.
  # `cp .env.example .env` inherits the umask, which is usually 0644, and this
  # script sources it as root — so a writable .env is arbitrary root execution.
  local mode
  mode=$(stat -c '%a' "$envfile")
  if [[ "$mode" != "600" ]]; then
    run chmod 600 "$envfile"
    ok ".env tightened from $mode to 0600"
  else
    ok ".env is already 0600"
  fi
}

configure_unattended_upgrades() {
  step "Unattended security updates"

  # Required by spec §2 and never implemented until now. Security updates only:
  # this box is expected to boot and run untouched for months, and an unattended
  # full-release upgrade is how that turns into an unattended outage.
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Managed by setup.sh — spec §2.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  # Deliberately does NOT auto-reboot. A reboot mid-transcode or mid-import is
  # worse than a delayed kernel patch on a LAN-only box; reboots stay manual.
  write_file /etc/apt/apt.conf.d/52unattended-upgrades-local 0644 <<'EOF'
// Managed by setup.sh. Security updates only — see spec §2.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  run systemctl enable --now unattended-upgrades
  ok "security updates applied automatically; reboots stay manual"
}

harden_ssh() {
  step "SSH"

  local cfg=/etc/ssh/sshd_config.d/10-hardening.conf
  run mkdir -p /etc/ssh/sshd_config.d

  # Disabling password authentication locks out anyone without a key, so it is
  # only safe once a key is actually installed. Checking for authorized_keys is
  # the difference between hardening the box and locking yourself out of it —
  # and this may be a headless machine in another room.
  local has_key=false
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] && has_key=true && break
  done

  if $has_key; then
    write_file "$cfg" 0644 <<'EOF'
# Managed by setup.sh — spec §5.3.
# Password auth is off because an authorized_keys file was found at setup time.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
    ok "root login and password authentication disabled (key found)"
  else
    write_file "$cfg" 0644 <<'EOF'
# Managed by setup.sh — spec §5.3.
# PasswordAuthentication is deliberately NOT disabled: no authorized_keys file
# existed when this ran, and turning it off would have locked this box out.
# Install a key, then re-run setup.sh to complete the hardening.
PermitRootLogin no
EOF
    warn "no authorized_keys found — password authentication left ENABLED"
    warn "  install a key:  ssh-copy-id <user>@<host>"
    warn "  then re-run this script to disable password login"
  fi

  # sshd refuses to start on a bad config, which on a remote box means no way
  # back in. Validate before reloading.
  if run sshd -t; then
    run systemctl reload ssh
    ok "sshd configuration reloaded"
  else
    warn "sshd -t rejected the configuration; not reloading"
  fi

  # fail2ban's Debian default already watches sshd; enabling the service is all
  # that is needed there. It matters most on the LAN-facing side, since a packet
  # arriving over wg0 has already been authenticated by WireGuard's key exchange
  # before sshd ever sees it.
  configure_fail2ban_web
  run systemctl enable --now fail2ban
  ok "fail2ban enabled (sshd jail, plus web jails if PUBLIC_DOMAIN is set)"
}

# Brute-force protection for the two apps that face the internet.
#
# Nothing else in the stack rate-limits anything: Caddy has no rate_limit
# directive without a plugin, and neither Jellyfin nor Jellyseerr locks an
# account out by default. Fine when the box was private; thin for a login page
# anyone can reach (decisions.md D25).
configure_fail2ban_web() {
  [[ -n "${PUBLIC_DOMAIN:-}" ]] || return 0
  [[ -d /etc/fail2ban ]] || { warn "/etc/fail2ban not found — skipping web jails"; return 0; }

  local caddy_log="${CONFIG_ROOT:-/opt/mediaserver}/caddy/logs/access.log"

  # The jail bans on any 401 or 403, and Jellyfin's web client and Jellyseerr
  # both return 401 routinely — an expired session, a token refresh, a client
  # reconnecting on a flaky mobile connection. Ten of those inside ten minutes
  # is an ordinary evening, not an attack, so without this the jail's first
  # victim is the household. Exempt the two networks that are already trusted
  # everywhere else in this design; the internet is what it is here to stop.
  #
  # Written as an if rather than `[[ ... ]] && ...`, which returns 1 when the
  # test fails and would abort the script under `set -e` (review-2026-08 A1).
  local ignore="127.0.0.1/8 ::1"
  if [[ -n "${LAN_SUBNET:-}" ]]; then
    ignore="${ignore} ${LAN_SUBNET}"
  else
    warn "LAN_SUBNET unset — the caddy-auth jail can ban LAN clients. Set it and re-run."
  fi
  ignore="${ignore} ${WG_SUBNET:-10.8.0.0/24}"

  if $DRY_RUN; then
    printf '  \033[36m[dry-run]\033[0m write fail2ban caddy-auth and jellyfin jails\n'
    return 0
  fi

  # Caddy's access log is already JSON and already rolled. It is also the only
  # place that records the REAL client address — Jellyfin and Jellyseerr both
  # see Caddy's container IP unless told otherwise, so this jail is the one that
  # can actually ban an attacker rather than the proxy.
  write_file /etc/fail2ban/filter.d/caddy-auth.conf 0644 <<'EOF'
# Managed by setup.sh. Matches Caddy's JSON access log.
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(401|403).*$
ignoreregex =
EOF

  write_file /etc/fail2ban/jail.d/caddy-auth.conf 0644 <<EOF
# Managed by setup.sh — brute-force protection for the public routes.
#
# maxretry is 20, not the 10 the sshd jail uses. This watches a login form on a
# page the household is meant to use, where a wrong password is a typo; sshd
# guards a shell where it is not. Twenty still stops credential stuffing dead.
[caddy-auth]
enabled  = true
filter   = caddy-auth
logpath  = ${caddy_log}
port     = http,https
ignoreip = ${ignore}
maxretry = 20
findtime = 10m
bantime  = 1h
EOF
  ok "fail2ban caddy-auth jail written (watches ${caddy_log})"
  info "caddy-auth ignoreip: ${ignore}"

  # Jellyfin's own log names the user, which Caddy's cannot. It is only useful
  # once Jellyfin's KnownProxies includes the compose bridge — until then every
  # proxied request appears to come from Caddy's container address and this jail
  # would ban the proxy, locking out the whole household. Disabled by default
  # for exactly that reason; see docs/verification.md before enabling.
  write_file /etc/fail2ban/filter.d/jellyfin.conf 0644 <<'EOF'
# Managed by setup.sh. Matches Jellyfin's failed-login line.
[Definition]
failregex = ^.*Authentication request for .* has been denied \(IP: "<HOST>"\)\.$
ignoreregex =
EOF

  write_file /etc/fail2ban/jail.d/jellyfin.conf 0644 <<EOF
# Managed by setup.sh.
#
# enabled = false until Jellyfin's KnownProxies is set to the compose bridge
# subnet. Without it Jellyfin logs Caddy's container IP for every proxied
# request, and this jail bans the reverse proxy — taking the whole household
# offline while the attacker is untouched.
[jellyfin]
enabled  = false
filter   = jellyfin
logpath  = ${CONFIG_ROOT:-/opt/mediaserver}/jellyfin/log/*.log
port     = http,https
ignoreip = ${ignore}
maxretry = 10
findtime = 10m
bantime  = 1h
EOF
  warn "fail2ban jellyfin jail written but DISABLED — set Jellyfin's KnownProxies"
  warn "  to the compose bridge subnet first, or it will ban Caddy, not the attacker."
}

install_backup_timer() {
  step "Config backups"

  # ${CONFIG_ROOT} holds every app database — watch history, requests, quality
  # profiles, indexer setup. The media is re-acquirable; this is not. It also
  # lives on the same SSD as the OS, so it needs a copy on the media disk.
  # decisions.md D7 says to back this up before pulling images and, until now,
  # nothing implemented that.
  write_file /etc/systemd/system/mediaserver-backup.service 0644 <<EOF
[Unit]
Description=Back up mediaserver app configuration
# The backup target is on the media disk. Without this the unit would run
# before the mount and quietly fill the SSD instead.
RequiresMountsFor=${MOUNT_POINT}

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/scripts/backup-config.sh
EOF

  write_file /etc/systemd/system/mediaserver-backup.timer 0644 <<'EOF'
[Unit]
Description=Daily mediaserver config backup

[Timer]
# 04:00, after smartd's long test window and well clear of overnight imports.
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

  run systemctl daemon-reload
  run systemctl enable --now mediaserver-backup.timer
  ok "daily config backup at 04:00 -> ${MOUNT_POINT}/backups"
  info "run one now with:  systemctl start mediaserver-backup.service"
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

  # The administrator still has to be able to read and repair the media tree by
  # hand. The tree is 775 media:media, so group membership is what makes that
  # possible without sudo — and without the containers getting a login account
  # in exchange (spec §3.4). Only relevant when PUID is not the admin's own uid.
  local admin=${SUDO_USER:-}
  if [[ -n "$admin" && "$admin" != "$MEDIA_USER" ]]; then
    if id -nG "$admin" 2>/dev/null | tr ' ' '\n' | grep -qx "$MEDIA_USER"; then
      ok "$admin already in the $MEDIA_USER group"
    else
      run usermod -aG "$MEDIA_USER" "$admin"
      ok "added $admin to the $MEDIA_USER group (log out and back in to pick it up)"
    fi
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

  # -m 0: the default 5% root reserve is meant for a system disk that must not
  # fill; on a pure data disk it just disappears — ~100 GB on 2 TB, ~500 GB on
  # 10 TB. Nothing on this filesystem needs root headroom, and
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
  for d in torrents/movies       torrents/tv       torrents/anime       torrents/music \
           usenet/incomplete \
           usenet/complete/movies usenet/complete/tv usenet/complete/anime usenet/complete/music \
           media/movies          media/tv          media/anime          media/music; do
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

  # Debian packages the daemon as smartmontools.service and ships
  # /etc/systemd/system/smartd.service as an alias symlink. systemd refuses to
  # enable a linked unit, and because this runs under `set -e` that one failure
  # exits the script — silently skipping the firewall, the SSH hardening and the
  # WireGuard prerequisites, which all come after it. Ask for the real name.
  local smartd_unit=smartd
  if systemctl list-unit-files --no-legend smartmontools.service 2>/dev/null | grep -q .; then
    smartd_unit=smartmontools
  fi

  run systemctl enable --now "$smartd_unit"
  run systemctl restart "$smartd_unit"
  ok "smartd enabled via ${smartd_unit}.service: short test daily 02:00, long test Saturday 03:00"
  info "send a test alert by adding -M test to the device line, then: systemctl restart $smartd_unit"
  info "remove -M test afterwards, or every restart will mail you"
}

# Host-side prerequisites for the wg-easy container.
#
# Both of these would normally be the container's job, and cannot be, because it
# runs with network_mode: host (decisions.md D26):
#
#   - Docker rejects `sysctls:` for net.* under host networking, since those are
#     host-global rather than namespaced. They have to be set here.
#   - The container drops SYS_MODULE, so it cannot modprobe wireguard itself.
#     The module is in-tree on Debian 13; loading it at boot is the cheaper half
#     of that trade.
# Hold the Docker daemon until the box actually has its address.
#
# Measured on the target after the first real reboot: networking.service
# "Finished" 0.2s into boot having raised nothing -- /etc/network/interfaces
# configures no interface, the WiFi is associated later by wpa_supplicant and
# addressed later still by dhcpcd. network-online.target is therefore satisfied
# almost immediately, which makes docker.service's After= on it worthless. The
# interface associated five seconds AFTER Docker had started the containers.
#
# Three things broke, none of them loudly:
#
#   - wg-easy binds WG_UI_BIND and threw EADDRNOTAVAIL. Its web server died
#     while wg-quick carried on, and its healthcheck only runs `wg show wg0`,
#     so the container reported healthy with no admin interface at all. On a
#     VPN-only box that is the remote front door.
#   - Caddy publishes CADDY_BIND_ADDR:80 and :443. Docker could not create the
#     bindings, and left the container running with no published ports --
#     `docker port caddy` empty while `docker compose ps` said Up.
#   - Container DNS did not work until the daemon was restarted, so Caddy could
#     not resolve its own upstreams by container name.
#
# Waiting is bounded and deliberately non-fatal: if the address never appears
# the daemon starts anyway, because a box that will not boot is worse than one
# with a broken front door, and SSH is what you need in that case.
configure_docker_boot_order() {
  step "Docker boot ordering"

  local addr=${CADDY_BIND_ADDR:-${ADMIN_HOST:-}}
  if [[ -z "$addr" ]]; then
    warn "CADDY_BIND_ADDR and ADMIN_HOST are both unset, so there is no address"
    warn "  to wait for. Set one and re-run, or Caddy and wg-easy will lose a"
    warn "  race with dhcpcd on every boot."
    return 0
  fi

  local dir=/etc/systemd/system/docker.service.d
  run mkdir -p "$dir"

  write_file "$dir/10-wait-for-address.conf" 0644 <<EOF
# Managed by setup.sh -- decisions.md D36.
#
# network-online.target is reached before this box has an address, so ordering
# against it is not enough. Wait for the address Caddy and wg-easy bind.
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sh -c 'i=0; while [ \$i -lt 60 ]; do ip -4 -o addr show | grep -qw "${addr}" && exit 0; i=\$((i+1)); sleep 1; done; exit 0'
EOF

  run systemctl daemon-reload
  ok "docker waits for ${addr} (up to 60s) before starting containers"
}

configure_wireguard_host() {
  step "WireGuard host prerequisites"

  local modconf=/etc/modules-load.d/wireguard.conf
  local sysconf=/etc/sysctl.d/99-wireguard.conf

  # wg-quick's PostUp runs ip6tables as well as iptables, because WG_SUBNET6 is
  # set. The container holds NET_ADMIN but deliberately not SYS_MODULE (D26), so
  # it cannot insert a netfilter module itself — and a box that has never run
  # ip6tables has no ip6_tables loaded. `wg-quick up` then fails half way
  # through, deletes wg0 on the way out, and wg-easy reports unhealthy with the
  # actual cause twenty lines up its log.
  local desired
  desired=$(cat <<'EOF'
# Managed by setup.sh. wg-easy drops SYS_MODULE, so it cannot load these
# itself. wireguard is the tunnel; the ip6* modules are what wg-quick's IPv6
# PostUp rules need before they will apply (decisions.md D26).
wireguard
ip6_tables
ip6table_nat
ip6table_filter
EOF
)

  # Compared rather than skipped-if-present: a file written by an earlier
  # version of this script is exactly the case that needs rewriting, which is
  # the lesson D28 already learned on the DOCKER-USER block.
  if [[ -f "$modconf" ]] && [[ "$(cat "$modconf")" == "$desired" ]]; then
    ok "$modconf already current"
  else
    write_file "$modconf" 0644 <<<"$desired"
  fi

  local m
  for m in wireguard ip6_tables ip6table_nat ip6table_filter; do
    if lsmod 2>/dev/null | grep -q "^${m} "; then
      ok "$m already loaded"
    elif run modprobe "$m"; then
      ok "loaded $m"
    else
      warn "modprobe $m failed — expected inside a container; on the box it"
      warn "  means wg0 will not come up cleanly."
    fi
  done

  # ip_forward is what lets a peer's packets reach anything but this box.
  # Docker already sets it at daemon start; writing it here makes it explicit
  # and survives a boot where Docker is masked or slow.
  if [[ -f "$sysconf" ]]; then
    ok "$sysconf already present"
  else
    write_file "$sysconf" 0644 <<'EOF'
# Managed by setup.sh — required by the wg-easy container, which runs with host
# networking and therefore cannot set these itself (decisions.md D26).
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
  fi

  # Applied outside the guard above, deliberately. When this warns, the file is
  # on disk but the settings are not live — and if the apply were inside the
  # `else` branch, the re-run the warning asks for would take the `already
  # present` path and never retry. Writing and applying are separate concerns.
  #
  # Tolerant rather than fatal: /proc/sys is read-only in an unprivileged
  # container, and `set -e` on a bare `sysctl --system` would abort the whole
  # script there — the same failure shape as the DRY_RUN bug in preflight().
  if run sysctl --system >/dev/null 2>&1; then
    ok "forwarding sysctls applied"
  else
    warn "sysctl --system failed — the file is written but not yet active."
    warn "  Apply with: sysctl --system"
  fi
}

configure_firewall() {
  step "Firewall"

  # ufw's Python writes the rules files back with an ascii codec, so a single
  # non-ASCII byte anywhere in after.rules makes every ufw invocation below die
  # with UnicodeEncodeError — including the two default-policy calls, before any
  # of this has run. The file that breaks it is one we wrote: an earlier
  # revision of this script put em dashes in its own DOCKER-USER comments,
  # following the repo's prose style. Repair that here, because the rewrite that
  # would otherwise fix it lives at the END of this function and never gets
  # reached.
  local afterrules=/etc/ufw/after.rules
  if [[ -f "$afterrules" ]] && LC_ALL=C grep -qP '[^\x00-\x7F]' "$afterrules"; then
    if $DRY_RUN; then
      info "[dry-run] transliterate non-ASCII in $afterrules (ufw cannot write it)"
    else
      sed -i 's/\xe2\x80\x94/--/g; s/\xe2\x80\x93/-/g; s/\xe2\x80\x99/'"'"'/g' "$afterrules"
      if LC_ALL=C grep -qP '[^\x00-\x7F]' "$afterrules"; then
        die "$afterrules still contains non-ASCII, which ufw refuses to write.
       Find it with:  grep -nP '[^\\x00-\\x7F]' $afterrules"
      fi
      ok "repaired non-ASCII in $afterrules"
    fi
  fi

  run ufw --force default deny incoming
  run ufw --force default allow outgoing

  # Scoped rather than `ufw allow OpenSSH`, which is unsourced and accepts SSH
  # from anywhere the host can be reached. The wg0 rule below already covers
  # remote administration, so SSH only needs to reach the LAN.
  #
  # These two rules are a pair. Removing the wg0 allow without widening this one
  # leaves a headless box with no remote SSH at all (review-2026-08 S5).
  if [[ -n "${LAN_SUBNET:-}" ]]; then
    run ufw allow from "$LAN_SUBNET" to any port 22 proto tcp
    ok "SSH allowed from ${LAN_SUBNET} only"
  else
    run ufw allow OpenSSH
    warn "LAN_SUBNET unset — SSH allowed from any source as a fallback."
    warn "  Set LAN_SUBNET in .env and re-run to scope it to the LAN."
  fi

  # wg-easy creates wg0 on first start, so on a fresh box this is expected to be
  # absent the first time through. Bring the stack up, then re-run.
  if ip link show wg0 >/dev/null 2>&1; then
    run ufw allow in on wg0
    ok "allowed all traffic on wg0"
  else
    warn "wg0 not found — the wg-easy container creates it on first start."
    warn "  Run 'docker compose up -d wg-easy', then re-run this script."
  fi

  # The tunnel itself. UDP, and genuinely filtered by UFW: wg-easy uses host
  # networking, so this is a host listener on the INPUT chain rather than a
  # Docker publish that would bypass it (decisions.md D19, D26).
  if [[ -n "${WG_PORT:-}" ]]; then
    run ufw allow "${WG_PORT}/udp"
    ok "allowed ${WG_PORT}/udp for WireGuard"
    # WG_UI_PORT is still not opened to the LAN or the internet. It is opened to
    # Docker's address pool, and only because D34 proxies the wg-easy UI through
    # Caddy: wg-easy runs with host networking, so it is the one upstream Caddy
    # cannot reach by container name. Caddy's packet leaves the bridge with a
    # 172.x source, arrives at the host's INPUT chain, and default-deny drops it
    # -- the LAN allow does not cover it. The symptom is a 502 on one name out
    # of twelve.
    #
    # The honest cost: spec §5.3 used to say ufw genuinely filters this port,
    # full stop. It now filters it for everything except containers on this box.
    # A compromised container can reach the wg-easy login page, which it could
    # not before. It still has to get past the login, which audit-auth.sh
    # asserts is enforced, and a container that can talk to the Docker socket
    # or the *arr APIs is already past caring about this one.
    if [[ -n "${WG_UI_PORT:-}" ]]; then
      run ufw allow from 172.16.0.0/12 to any port "${WG_UI_PORT}" proto tcp
      ok "allowed the Docker pool to reach the wg-easy UI on ${WG_UI_PORT} (Caddy proxies it)"
    fi
    info "WG_UI_PORT (${WG_UI_PORT:-51821}) is NOT opened to the LAN or the"
    info "  internet; reach it at wg.\${PUBLIC_DOMAIN} or on the LAN address."
  else
    warn "WG_PORT unset in .env — no WireGuard port opened, so no peer can connect"
  fi

  # Spec §5.3 says "allow SSH and the remote-access interface; deny inbound
  # otherwise", but taken literally that also blocks §5.1's direct LAN access
  # — including Infuse on the Apple TV reaching Jellyfin, which is the primary
  # playback path. Allowing the LAN subnet reconciles the two: the home network
  # gets through, the internet still cannot, and there is no port forwarding.
  # See docs/decisions.md D1.
  if [[ -n "${LAN_SUBNET:-}" ]]; then
    run ufw allow from "$LAN_SUBNET"
    ok "allowed inbound from LAN ${LAN_SUBNET}"
  else
    warn "LAN_SUBNET is unset in .env, so this will be a tunnel-only box:"
    warn "  LAN clients cannot reach Jellyfin or any *arr UI by IP and port."
    warn "  Infuse on the Apple TV will not find Jellyfin unless the Apple TV"
    warn "  is itself a WireGuard peer."
    warn "Set LAN_SUBNET (e.g. 192.168.1.0/24) in .env and re-run to allow it."
  fi

  # The public front door. Only reached when PUBLIC_DOMAIN is set, so a
  # tunnel-and-LAN-only box stays exactly as it was.
  #
  # Caddy serves three names here — the landing page, Jellyfin and Jellyseerr.
  # The nine admin apps are not routed through it at all, so opening 80 and 443
  # exposes those three and nothing else (decisions.md D25, spec §5.3).
  if [[ "${PUBLIC_HTTP:-false}" == "true" ]]; then
    [[ -n "${PUBLIC_DOMAIN:-}" ]] || die "PUBLIC_HTTP=true needs PUBLIC_DOMAIN set."
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    ok "allowed 80/443 from any source for ${PUBLIC_DOMAIN}"
  else
    # VPN-only (D33). Deleted, not merely skipped: this script is how the model
    # is changed, and a rule surviving from a run when PUBLIC_HTTP was true is
    # an opening that `ufw status` shows and nobody reads.
    # `ufw status` prints ALLOW; only `ufw status verbose` prints ALLOW IN.
    # Matching the verbose form here silently never fired, so the rules stayed
    # open while the script reported them closed.
    if ufw status 2>/dev/null | grep -qE '^80/tcp[[:space:]]+ALLOW'; then
      run ufw delete allow 80/tcp
      run ufw delete allow 443/tcp
      ok "closed public 80/443 — PUBLIC_HTTP is not true"
    else
      ok "no public HTTP ports open (PUBLIC_HTTP is not true)"
    fi
    info "Caddy still answers on the LAN and over the tunnel; only"
    info "  ${WG_PORT:-51820}/udp is forwarded from the router."
  fi

  configure_docker_firewall

  run ufw --force enable
  ok "ufw enabled"
}

configure_docker_firewall() {
  # UFW does not filter Docker-published ports, and this is the single most
  # misleading thing about the stack's security posture.
  #
  # `ufw default deny incoming` filters the INPUT chain. Traffic to a published
  # container port is DNAT'd in nat/PREROUTING and then traverses FORWARD, so it
  # never reaches INPUT and UFW never sees it. Every service port published by
  # docker-compose.yml is therefore reachable from any network the box is
  # attached to, while `ufw status` reports a default-deny firewall.
  #
  # Docker leaves the DOCKER-USER chain empty and evaluates it before its own
  # rules, precisely so this can be fixed. These rules put container traffic
  # under the same policy the rest of the box already has: the tunnel and the
  # LAN in, everything else out.
  #
  # Without this, the real boundary is only "no port forwarding on the router" —
  # one accidental rule, or one move to an untrusted network, and the *arr UIs
  # and qBittorrent are on the internet. See decisions.md D19.
  local rules=/etc/ufw/after.rules
  local marker="# BEGIN MEDIASERVER DOCKER-USER"
  local end_marker="# END MEDIASERVER DOCKER-USER"

  [[ -f "$rules" ]] || { warn "$rules not found — is ufw installed?"; return 0; }

  if [[ -z "${LAN_SUBNET:-}" ]]; then
    warn "LAN_SUBNET unset — skipping DOCKER-USER rules."
    warn "  Adding them without a LAN subnet would cut the LAN off from Jellyfin"
    warn "  and break Infuse on the Apple TV. Set LAN_SUBNET and re-run."
    return 0
  fi

  # The public rules go in only when a public domain is configured. Written as a
  # separate variable so the generated file reads the same either way.
  local public_rules=""
  if [[ "${PUBLIC_HTTP:-false}" == "true" ]]; then
    public_rules="# The public front door. Port-scoped rather than source-scoped because after
# DNAT the destination is a container IP that is not stable across restarts.
# This is safe because Caddy is the only service published on the address the
# router forwards to: a WAN packet aimed at 8096 still DNATs to Jellyfin and
# then falls through to the DROP below, since its dport is not 80 or 443.
-A DOCKER-USER -p tcp --dport 80 -j RETURN
-A DOCKER-USER -p tcp --dport 443 -j RETURN"
  fi

  local block
  block=$(cat <<EOF
${marker}
# Managed by setup.sh. Docker-published ports bypass UFW's INPUT chain, so
# these rules apply the same policy to forwarded container traffic.
# Order matters: RETURN hands the packet back to Docker's own chains.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
# Container-originated traffic. This chain is jumped from the TOP of FORWARD, so
# it sees egress and container-to-container as well as inbound; the DROP at the
# bottom is not scoped to arriving packets and never was. Without these two it
# kills every outbound connection a container makes, starting with Docker's
# embedded DNS resolver, whose upstream queries leave the container's own
# namespace and are therefore forwarded traffic with a bridge source address.
# Nothing then resolves anything: no indexers, no Usenet, and no ACME, so Caddy
# never obtains a certificate (decisions.md D28).
#
# Scoped by interface AND source on purpose. The interface match alone would
# trust a host bridge named br0, which this box would have if it ever ran VMs;
# the source match alone would trust a WAN packet forging a bridge address.
# 172.16.0.0/12 is Docker's default address pool: change
# default-address-pools in /etc/docker/daemon.json and these must follow.
-A DOCKER-USER -i br+ -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -i docker0 -s 172.16.0.0/12 -j RETURN
# wg0 is a host interface because wg-easy runs with host networking, so peer
# traffic aimed at a published container port is matchable here by interface.
# No rule is needed for the tunnel port itself: that is a host listener and
# never reaches this chain (decisions.md D26).
-A DOCKER-USER -i wg0 -j RETURN
-A DOCKER-USER -i lo -j RETURN
-A DOCKER-USER -s ${LAN_SUBNET} -j RETURN
${public_rules}
# Anything else reaching a container from off-box is dropped. Without the
# public rules above, a router port forward would silently do nothing: the
# packet is DNAT'd, traverses FORWARD, and dies here while the router looks
# correctly configured.
-A DOCKER-USER -j DROP
COMMIT
${end_marker}
EOF
)

  local present=false current="" uptodate=false
  if grep -qF "$marker" "$rules"; then
    present=true
    current=$(awk -v b="$marker" -v e="$end_marker" '
      $0 == b { inblock = 1 }
      inblock { print }
      $0 == e { inblock = 0 }
    ' "$rules")
    if [[ "$current" == "$block" ]]; then
      ok "DOCKER-USER rules already present and current in $rules"
      uptodate=true
    fi
  fi

  # A current file is deliberately NOT an early return, because the file being
  # right says nothing about the kernel being right, and this chain is the whole
  # of D19. Measured on the target: a `systemctl restart docker` does NOT empty
  # DOCKER-USER, so that particular fear is unfounded. What remains is that
  # nothing here has ever verified the two agree, the reload is a second, and
  # the failure it would cover is silent by construction.
  if ! $uptodate; then
    # Rewritten rather than skipped when it differs. LAN_SUBNET and PUBLIC_HTTP
    # are both routinely changed after the first run -- and report() ends by
    # telling you to re-run once wg0 exists -- so a write-once guard here would
    # leave the stalest possible rules in place while every message said the
    # script had succeeded.
    if $DRY_RUN; then
      local action=append
      $present && action=rewrite
      printf '  \033[36m[dry-run]\033[0m %s DOCKER-USER block in %s (LAN %s):\n' \
        "$action" "$rules" "$LAN_SUBNET"
      # Printed in full, in write_file's format, rather than as the one-line
      # summary this used to be. These are the highest-consequence lines the
      # script writes and a dry run is where they get read, so "a block was
      # appended" hid the only thing worth checking.
      while IFS= read -r line; do printf '      | %s\n' "$line"; done <<<"$block"
      return 0
    fi

    # Belt and braces against the failure configure_firewall repairs above: if
    # this block ever picks up a non-ASCII character again, fail here with the
    # cause rather than in ufw's traceback on somebody's next run.
    if LC_ALL=C grep -qP '[^\x00-\x7F]' <<<"$block"; then
      die "The DOCKER-USER block contains non-ASCII. ufw writes after.rules with
       an ascii codec and will refuse every later invocation. Keep this block
       plain ASCII, whatever the prose style elsewhere."
    fi

    cp "$rules" "${rules}.bak"
    ok "backed up $rules to ${rules}.bak"

    local tmp
    tmp=$(mktemp)
    awk -v b="$marker" -v e="$end_marker" '
      $0 == b { inblock = 1; next }
      inblock { if ($0 == e) inblock = 0; next }
      { print }
    ' "$rules" > "$tmp"

    # Written back through the existing file rather than moved over it, so the
    # mode and ownership ufw expects on after.rules survive. The command
    # substitution eats trailing newlines, which normalises the blank line the
    # strip above leaves behind -- otherwise repeated rewrites accumulate them.
    printf '%s\n\n%s\n' "$(< "$tmp")" "$block" > "$rules"
    rm -f "$tmp"

    local verb="appended"
    $present && verb="rewritten"
    if [[ "${PUBLIC_HTTP:-false}" == "true" ]]; then
      ok "DOCKER-USER rules ${verb} (wg0 + ${LAN_SUBNET} + public 80/443 in)"
    else
      ok "DOCKER-USER rules ${verb} (wg0 + ${LAN_SUBNET} in, rest dropped)"
    fi
  elif $DRY_RUN; then
    return 0
  fi

  # after.rules is read only when ufw loads its ruleset, and `ufw --force
  # enable` on an already-active firewall does not re-read it. Every re-run
  # would otherwise leave the file and the kernel disagreeing while every line
  # above said success -- and re-running is the documented workflow, because
  # wg0 does not exist on the first pass. A rule that is written and never
  # loaded protects nothing (review-2026-08).
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    run ufw reload
    ok "ufw reloaded, so the block above is in the kernel and not just on disk"
  else
    info "ufw inactive; the block loads when it is enabled below"
  fi
  info "verify:  iptables -L DOCKER-USER -n -v"
}

report() {
  step "Values for .env"

  local render_gid lan_ip
  render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
  # The address the router forwards 80/443 to, where the Manage links point, and
  # what the wg-easy UI binds to. One address, three variables, on purpose: a
  # peer reaches the box by the same address the LAN does (decisions.md D26).
  lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 || true)

  printf '  RENDER_GID=%s\n' "${render_gid:-<none — iGPU disabled in BIOS?>}"
  printf '  CADDY_BIND_ADDR=%s\n' "${lan_ip:-<none — could not detect the LAN address>}"
  printf '  ADMIN_HOST=%s\n' "${lan_ip:-<none — could not detect the LAN address>}"
  printf '  WG_UI_BIND=%s\n' "${lan_ip:-<none — could not detect the LAN address>}"
  printf '  PUBLIC_DOMAIN=%s\n' "${PUBLIC_DOMAIN:-<your domain, e.g. media.example.com>}"
  printf '  ACME_EMAIL=%s\n' "${ACME_EMAIL:-<contact address for the ACME account>}"
  printf '  LAN_SUBNET=%s\n' "${LAN_SUBNET:-<your home subnet, e.g. 192.168.1.0/24>}"

  step "Next"
  info "1. Put the values above into .env, plus WG_HOST, WG_USER and WG_PASS"
  info "2. DNS: A records for PUBLIC_DOMAIN, jellyfin.<domain>, seerr.<domain>"
  info "   and WG_HOST, pointing at this site's WAN address."
  if [[ "${PUBLIC_HTTP:-false}" == "true" ]]; then
    info "3. Router, two forwards to ${lan_ip:-<lan-ip>}:"
    info "     TCP 80 and 443  — both; Let's Encrypt validates over 80"
    info "     UDP ${WG_PORT:-51820}       — the WireGuard tunnel"
  else
    info "3. Router, ONE forward to ${lan_ip:-<lan-ip>}:"
    info "     UDP ${WG_PORT:-51820}       — the WireGuard tunnel, and nothing else"
    info "   PUBLIC_HTTP is false: certificates come from DNS-01, so 80 and 443"
    info "   stay closed and the three names resolve to ${lan_ip:-<lan-ip>} (D33)."
  fi
  info "   Do NOT forward ${WG_UI_PORT:-51821}. The wg-easy UI is LAN and tunnel only."
  info "4. Verify the iGPU:  vainfo | grep -Ei 'h264|hevc'"
  info "5. Start the stack:  docker compose up -d"
  info "6. Re-run this script — wg0 exists now, so the firewall rules it"
  info "   skipped above get installed."
  info "7. Prove hardlinking: ./scripts/test-hardlinks.sh"
  info "8. Work through docs/verification.md"
  echo
  if ip link show wg0 >/dev/null 2>&1; then
    info "wg0 is up — the admin apps are reachable at ${lan_ip:-<lan-ip>}:<port>"
    info "from the LAN and from any WireGuard peer, by the same address."
  else
    warn "wg0 does not exist yet. Until the wg-easy container has started once,"
    warn "the nine admin apps are LAN-only:  docker compose up -d wg-easy"
  fi
  echo
}

# ─── Main ────────────────────────────────────────────────────────────────────

preflight "$@"
install_packages
secure_env_file
create_media_user
format_disk
configure_fstab
create_tree
configure_mail
configure_smartd
configure_unattended_upgrades
harden_ssh
install_backup_timer
configure_docker_boot_order
configure_wireguard_host
configure_firewall
report
