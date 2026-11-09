#!/usr/bin/env bash
# PHP 8.4 migration for Ubuntu 22.04/24.04; read-only inventory works across web stacks.
# Supports one-command migration with explicit operator approval.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
umask 077

VERSION='1.3.0'
TARGET='8.4'
MIN_FIXED='8.4.27'
STATE_ROOT='/var/backups/php84-migrator'
ACTION="${1:---check}"

say() { printf '[php84-migrator] %s\n' "$*"; }
fail() { printf '[php84-migrator] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "Missing tool: $1"; }
require_root() { (( EUID == 0 )) || fail 'Run as root (sudo).'; }

# Unexpected failures must never result in an unexplained silent exit.
# (Intentional exits from fail() are already reported separately.)
trap 'rc=$?; printf "[php84-migrator] ERROR: unexpected failure at line %s (exit %s): %s\\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

case "$ACTION" in
  --check|--run|--rollback|--status|--help) ;;
  *) fail "Unknown action: $ACTION (use --help)" ;;
esac

if [[ "$ACTION" == '--help' ]]; then
  cat <<'EOF'
Usage: sudo bash php84-migrate.sh [--check|--run|--status|--rollback]
  --check       Read-only OS/PHP/web-stack inventory (default); works without Apache.
  --run         Backup, install PHP 8.4, switch running Apache mod_php; prompts first.
  --status      Display OS, Apache, nginx, PHP CLI and PHP-FPM state.
  --rollback    Restore previous Apache PHP module and CLI alternative.
Automatic --run: Ubuntu 22.04/24.04, running Apache mod_php, root.
Nginx, PHP-FPM, inactive Apache, and CLI-only systems: diagnostic only.
The old PHP packages remain installed; rollback only switches configuration.
EOF
  exit 0
fi
require_root

# Keep the read-only diagnostics available even on a host without Apache, APT
# or a running web server. Only the migration and rollback require those tools.
read_os() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck source=/dev/null
  source /etc/os-release
}
ubuntu_supported() {
  [[ "${ID:-}" == ubuntu ]] || return 1
  case "${VERSION_ID:-}:${VERSION_CODENAME:-}" in
    22.04:jammy|24.04:noble) return 0 ;;
    *) return 1 ;;
  esac
}
service_state() {
  local unit="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active "$unit" 2>/dev/null || true
  else
    printf 'unknown (systemctl unavailable)\n'
  fi
}
php_module_links() {
  local file found=0
  shopt -s nullglob
  for file in /etc/apache2/mods-enabled/php[0-9]*.load; do
    printf '%s ' "${file##*/}"
    found=1
  done
  shopt -u nullglob
  (( found == 1 )) || printf 'none'
  printf '\n'
}
diagnostic_rollback() {
  local d old alt
  [[ -d "$STATE_ROOT" ]] || fail "No rollback states in $STATE_ROOT"
  d="$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | LC_ALL=C sort | tail -1)"
  [[ -n "$d" && -f "$d/previous_apache_module" ]] || fail 'Missing rollback state.'
  old="$(<"$d/previous_apache_module")"
  [[ "$old" =~ ^[0-9]+\.[0-9]+$ && "$old" != "$TARGET" ]] || fail 'Invalid previous Apache module.'
  [[ -f "/etc/apache2/mods-available/php${old}.load" ]] || fail "Apache module php${old} not available."
  say "Restoring Apache PHP ${old} using snapshot $d"
  read -r -p "Type ROLLBACK to proceed: " answer < /dev/tty
  [[ "$answer" == 'ROLLBACK' ]] || fail 'Cancelled.'
  a2dismod -f "php${TARGET}" || true
  a2enmod "php${old}"
  apache2ctl configtest || fail 'Apache configtest failed; investigate manually.'
  systemctl restart apache2
  if [[ -f "$d/previous_cli" ]]; then
    alt="$(<"$d/previous_cli")"
    if [[ "$alt" == /usr/bin/php* && -x "$alt" ]]; then
      update-alternatives --set php "$alt" || say 'Could not restore CLI alternative.'
    fi
  fi
  say 'Apache module restored. Packages and php.ini were NOT reverted; consult the backup archive if needed.'
  diagnostic_status
}

if [[ "$ACTION" == '--rollback' ]]; then rollback; exit 0; fi

old="$(active_php_module)"
say "OS: Ubuntu ${VERSION_ID} (${VERSION_CODENAME}), Apache mod_php $old -> PHP $TARGET (minimum $MIN_FIXED)"
diagnostic_status
if [[ "$old" == "$TARGET" ]]; then say 'Apache already uses PHP 8.4; no migration necessary.'; exit 0; fi
[[ "$old" =~ ^(7\.[0-9]+|8\.[0-3])$ ]] || fail "Unsupported source PHP module $old"

installed_apache_pkg="$(dpkg-query -W -f='${db:Status-Abbrev}' "libapache2-mod-php${old}" 2>/dev/null)" || \
  fail "Source Apache package libapache2-mod-php${old} is not installed."
[[ "$installed_apache_pkg" == ii* ]] || fail "Source Apache package libapache2-mod-php${old} is not installed."

# Build extension list from installed Debian packages (source version -> target version).
pkgs=("php${TARGET}-cli" "php${TARGET}-common" "php${TARGET}-opcache" "php${TARGET}-readline")
while IFS= read -r pkg; do
  case "$pkg" in
    "php${old}"|"php${old}-cli"|"php${old}-common"|"php${old}-opcache"|"php${old}-readline") continue ;;
    "php${old}-fpm"|"php${old}-cgi") fail "FPM/CGI installed: $pkg. Manual review required." ;;
    "php${old}-"*)
      suffix="${pkg#php${old}-}"
      [[ "$suffix" =~ ^[a-z0-9-]+$ ]] || fail "Unexpected package name: $pkg"
      pkgs+=("php${TARGET}-${suffix}")
      ;;
  esac
done < <(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' "php${old}*" 2>/dev/null | awk '$2 ~ /^ii/ {print $1}' | sed 's/:amd64$//')
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
say "Target extensions: ${pkgs[*]}"

# The migration is intentionally interactive; never designed for silent remote execution.
read -r -p 'Type MIGRATE to back up, install and switch Apache: ' answer < /dev/tty
[[ "$answer" == 'MIGRATE' ]] || fail 'Cancelled.'

mkdir -p "$STATE_ROOT"
d="$(mktemp -d "$STATE_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
printf '%s\n' "$old" > "$d/previous_apache_module"
readlink -f /etc/alternatives/php > "$d/previous_cli" 2>/dev/null || true
say "Backup directory: $d"
tar --acls --xattrs -czpf "$d/etc-php-apache.tar.gz" -C / etc/php etc/apache2
apache2ctl -S > "$d/apache-vhosts-before.txt" 2>&1 || true
php -m > "$d/php-modules-before.txt" 2>&1 || true
dpkg-query -W 'php*' 'libapache2-mod-php*' > "$d/dpkg-before.txt" 2>&1 || true

# Read the complete apt-cache output. An early-exiting awk under pipefail
# can SIGPIPE apt-cache and silently terminate the migration (exit 141).
# Do not infer PPA availability from the mere presence of its text in source
# files: disabled .sources stanzas, comments, and old backup files cause false
# positives. APT's actual package candidate is the source of truth.
say 'Refreshing APT metadata and checking the PHP 8.4 candidate.'
apt-get update
candidate="$(apt-cache policy "php${TARGET}-cli" | awk '$1 == "Candidate:" {print $2}')"
if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
  say 'PHP 8.4 is not available from active APT sources; enabling ppa:ondrej/php.'
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:ondrej/php
  apt-get update
  candidate="$(apt-cache policy "php${TARGET}-cli" | awk '$1 == "Candidate:" {print $2}')"
fi
if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
  say 'PHP candidate is still missing; review whether ppa:ondrej/php is disabled, pinned, or failing during apt-get update.'
  apt-cache policy "php${TARGET}-cli" || true
  fail "No PHP $TARGET candidate in active APT repositories; installation has not started."
fi
say "APT candidate: $candidate"
# Compare upstream version numerically (before -debian suffix); do not install an old unfixed build.
upstream="${candidate%%-*}"
upstream="${upstream#*:}"
dpkg --compare-versions "$upstream" ge "$MIN_FIXED" || fail "Candidate PHP $candidate is older than $MIN_FIXED."

for pkg in "${pkgs[@]}" "libapache2-mod-php${TARGET}"; do
  c="$(apt-cache policy "$pkg" | awk '$1 == "Candidate:" {print $2}')"
  [[ -n "$c" && "$c" != '(none)' ]] || fail "Unavailable extension: $pkg"
done

# Fail before any installation if an APT transaction intends package removal.
apt-get -s install "${pkgs[@]}" "libapache2-mod-php${TARGET}" > "$d/apt-simulation.txt"
if grep -Eq '^(Remv|Purg) ' "$d/apt-simulation.txt"; then
  say 'Simulation requested removals:'
  grep -E '^(Remv|Purg) ' "$d/apt-simulation.txt"
  fail "APT would remove packages; stop and review $d/apt-simulation.txt"
fi
say 'APT dry run passed (no removals).'

# Keep the previously running PHP handler available even if Debian package scripts
# enable the new module or restart Apache before our explicit cutover.
auto_recover() {
  say "Recovery: restoring Apache mod_php $old."
  a2dismod -f "php${TARGET}" >/dev/null 2>&1 || true
  a2enmod "php${old}" || true
  if apache2ctl configtest && systemctl restart apache2; then
    say "Previous Apache handler restored. Investigate application logs before retrying."
  else
    say "CRITICAL: Automatic recovery failed; investigate Apache immediately."
  fi
  if [[ -f "$d/previous_cli" ]]; then
    previous_cli="$(<"$d/previous_cli")"
    if [[ "$previous_cli" == /usr/bin/php* && -x "$previous_cli" ]]; then
      update-alternatives --set php "$previous_cli" || true
    fi
  fi
}

say 'Installing PHP 8.4 and Apache module. Package scripts may restart Apache.'
if ! apt-get install -y "${pkgs[@]}" "libapache2-mod-php${TARGET}"; then
  auto_recover
  fail "APT installation failed; inspect $d"
fi
if ! "/usr/bin/php${TARGET}" -v; then
  auto_recover
  fail "New PHP executable failed after package installation."
fi

# Carry over only a conservative subset of explicit php.ini values.
for sapi in apache2 cli; do
  from="/etc/php/$old/$sapi/php.ini"
  confdir="/etc/php/$TARGET/$sapi/conf.d"
  [[ -f "$from" && -d "$confdir" ]] || continue
  awk -F= '
    /^[[:space:]]*[#;]/ {next}
    /^[[:space:]]*(memory_limit|upload_max_filesize|post_max_size|max_execution_time|max_input_vars|date\.timezone)[[:space:]]*=/ {
       name=$1; gsub(/[[:space:]]/, "", name); print name "=" substr($0,index($0,"=")+1)
    }
  ' "$from" > "$d/explicit-$sapi.ini"
  if [[ -s "$d/explicit-$sapi.ini" ]]; then
    install -m 0644 "$d/explicit-$sapi.ini" "$confdir/99-php84-migrator.ini"
  fi
done

say "Switching mod_php $old -> $TARGET."
# The post-install script may already have disabled the old module.
a2dismod -f "php${old}" || true
if ! a2enmod "php${TARGET}"; then
  auto_recover
  fail "Could not enable PHP $TARGET Apache module."
fi
if ! apache2ctl configtest; then
  auto_recover
  fail "Apache configuration test failed; inspect $d"
fi
if ! systemctl restart apache2; then
  auto_recover
  fail 'Apache restart failed; inspect journalctl -u apache2.'
fi
update-alternatives --set php "/usr/bin/php${TARGET}" || say 'CLI alternative was not switched.'

current="$(active_php_module)"
[[ "$current" == "$TARGET" ]] || fail "Wrong Apache module: $current"
systemctl is-active --quiet apache2 || fail 'Apache did not remain active.'
"/usr/bin/php${TARGET}" -v | sed -n '1p'
say 'Migration completed. Old PHP packages remain installed for manual rollback.'
say "Backup: $d"
say 'IMPORTANT: Test all site URLs and application functionality (login, forms, DB, cron).'
say 'If needed: sudo bash php84-migrate.sh --rollback'
