#!/usr/bin/env bash
# PHP 8.4 migration for Ubuntu 22.04/24.04; inventory for all web stacks.
# Supports one-command migration with explicit operator approval.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
umask 077

VERSION='1.6.0'
TARGET='8.4'
MIN_FIXED='8.4.27'
STATE_ROOT='/var/backups/php84-migrator'
ACTION="${1:---check}"
MPTCP_CONF='/etc/sysctl.d/99-zz-kit-disable-mptcp.conf'
MPTCP_PROC='/proc/sys/net/mptcp/enabled'
MPTCP_STATE="$STATE_ROOT/mptcp-original"

say() { printf '[php84-migrator] %s\n' "$*"; }
fail() { printf '[php84-migrator] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "Missing tool: $1"; }
require_root() { (( EUID == 0 )) || fail 'Run as root (sudo).'; }

# Unexpected failures must never result in an unexplained silent exit.
# (Intentional exits from fail() are already reported separately.)
trap 'rc=$?; printf "[php84-migrator] ERROR: unexpected failure at line %s (exit %s): %s\\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

case "$ACTION" in
  --check|--run|--rollback|--status|--disable-mptcp|--restore-mptcp|--help) ;;
  *) fail "Unknown action: $ACTION (use --help)" ;;
esac

if [[ "$ACTION" == '--help' ]]; then
  cat <<'EOF'
Usage: sudo bash php84-migrate.sh [--check|--run|--status|--rollback|--disable-mptcp|--restore-mptcp]
  --check       Read-only inventory: Ubuntu / AlmaLinux, Apache/httpd, Nginx, FPM, CLI.
  --run         Ubuntu: migrate mod_php. AlmaLinux 9: switch PHP 7/8 to Remi 8.4.
  --status      Show OS, PHP CLI and web-stack status without requiring Apache.
  --rollback    Restore previous Apache mod_php and CLI alternative.
  --disable-mptcp   Disable MPTCP now and persistently (no Apache/PHP changes).
  --restore-mptcp   Restore MPTCP settings saved by the first disable.
Automatic --run: Ubuntu 22.04/24.04 Apache mod_php, or AlmaLinux 9
with standard PHP RPMs, active php-fpm and available remi-8.4 module.
AlmaLinux: previews DNF package removals and requires SWITCH-PHP84 approval.
--run also disables MPTCP after a successful PHP migration, if supported.
The old PHP packages remain installed. PHP rollback does NOT restore MPTCP.
EOF
  exit 0
fi
require_root

# MPTCP hardening is independent of PHP and Apache. Keep the original runtime
# value and our managed config file for an explicit, auditable restoration.
mptcp_status() {
  if [[ -r "$MPTCP_PROC" ]]; then
    say "MPTCP runtime: $(<"$MPTCP_PROC") (0=disabled; 1=enabled)"
  else
    say 'MPTCP runtime: unavailable in current network namespace/kernel; nothing to disable'
  fi
  if [[ -f "$MPTCP_CONF" ]]; then
    say "MPTCP persistent override: $MPTCP_CONF"
  else
    say 'MPTCP persistent override: not installed by this script'
  fi
}

mptcp_disable() {
  local current state_tmp config_tmp
  need sysctl
  if [[ ! -r "$MPTCP_PROC" || ! -w "$MPTCP_PROC" ]]; then
    say 'MPTCP kernel setting unavailable or read-only; skipping MPTCP change.'
    return 0
  fi
  current="$(<"$MPTCP_PROC")"
  [[ "$current" == 0 || "$current" == 1 ]] || fail "Unexpected MPTCP value: $current"
  [[ ! -L "$MPTCP_CONF" ]] || fail "MPTCP config path is a symlink; refusing to overwrite: $MPTCP_CONF"
  [[ ! -e "$MPTCP_CONF" || -f "$MPTCP_CONF" ]] || fail "MPTCP config path is not a regular file: $MPTCP_CONF"

  # procps sysctl --system may process /etc/sysctl.conf after sysctl.d;
  # fail rather than promise persistence if it explicitly re-enables MPTCP.
  if [[ -f /etc/sysctl.conf ]] &&
     grep -Eq '^[[:space:]]*net[./]mptcp[./]enabled[[:space:]]*=[[:space:]]*1([[:space:]#]|$)' /etc/sysctl.conf; then
    fail '/etc/sysctl.conf explicitly enables MPTCP; resolve the conflict before migration.'
  fi

  mkdir -p "$STATE_ROOT"
  if [[ -e "$MPTCP_STATE" ]]; then
    [[ -d "$MPTCP_STATE" && -f "$MPTCP_STATE/runtime" && -f "$MPTCP_STATE/had-file" ]] ||
      fail "Existing MPTCP baseline is incomplete: $MPTCP_STATE"
  fi
  if [[ ! -e "$MPTCP_STATE" ]]; then
    state_tmp="$(mktemp -d "$STATE_ROOT/.mptcp-original.XXXXXXXX")"
    printf '%s\n' "$current" > "$state_tmp/runtime"
    if [[ -f "$MPTCP_CONF" ]]; then
      printf 'yes\n' > "$state_tmp/had-file"
      cp -p -- "$MPTCP_CONF" "$state_tmp/config"
    else
      printf 'no\n' > "$state_tmp/had-file"
    fi
    mv -- "$state_tmp" "$MPTCP_STATE"
    say "Original MPTCP state saved in $MPTCP_STATE"
  fi

  config_tmp="$(mktemp /etc/sysctl.d/.kit-disable-mptcp.XXXXXXXX)"
  printf '# Managed by sprava-serveru-kit php84-migrate.sh\nnet.mptcp.enabled = 0\n' > "$config_tmp"
  chmod 0644 "$config_tmp"
  mv -f -- "$config_tmp" "$MPTCP_CONF"
  if ! sysctl -w net.mptcp.enabled=0; then
    fail 'Unable to apply net.mptcp.enabled=0 at runtime; inspect kernel settings.'
  fi
  [[ "$(<"$MPTCP_PROC")" == 0 ]] || fail 'MPTCP remains enabled after sysctl -w.'
  say "MPTCP disabled now and configured after reboot: $MPTCP_CONF"
  say 'If other sysctl.d files override this key later, investigate their ordering.'
}

mptcp_restore() {
  local had_file previous_runtime archive
  need sysctl
  [[ -d "$MPTCP_STATE" && -f "$MPTCP_STATE/runtime" && -f "$MPTCP_STATE/had-file" ]] ||
    fail 'No saved MPTCP baseline available for restoration.'
  previous_runtime="$(<"$MPTCP_STATE/runtime")"
  had_file="$(<"$MPTCP_STATE/had-file")"
  [[ "$previous_runtime" == 0 || "$previous_runtime" == 1 ]] || fail 'Invalid saved MPTCP runtime state.'
  [[ ! -L "$MPTCP_CONF" ]] || fail 'Refusing to restore through a symlink.'
  case "$had_file" in
    yes)
      [[ -f "$MPTCP_STATE/config" ]] || fail 'Original MPTCP config backup is missing.'
      cp -p -- "$MPTCP_STATE/config" "$MPTCP_CONF"
      ;;
    no) rm -f -- "$MPTCP_CONF" ;;
    *) fail 'Invalid saved MPTCP file state.' ;;
  esac
  if [[ -w "$MPTCP_PROC" ]]; then
    sysctl -w "net.mptcp.enabled=$previous_runtime" ||
      fail 'Original config restored but runtime MPTCP value could not be restored.'
  else
    say 'MPTCP runtime setting is unavailable; restored persistent configuration only.'
  fi
  archive="$STATE_ROOT/mptcp-restored-$(date +%Y%m%d-%H%M%S)-$(date +%N)"
  mv -- "$MPTCP_STATE" "$archive"
  say "MPTCP settings restored; original baseline archived at $archive"
}

if [[ "$ACTION" == '--disable-mptcp' ]]; then
  read -r -p 'Type MPTCP to disable Multipath TCP on this host: ' answer < /dev/tty
  [[ "$answer" == MPTCP ]] || fail 'Cancelled.'
  mptcp_disable
  mptcp_status
  exit 0
fi
if [[ "$ACTION" == '--restore-mptcp' ]]; then
  read -r -p 'Type RESTORE-MPTCP to restore the saved setting: ' answer < /dev/tty
  [[ "$answer" == RESTORE-MPTCP ]] || fail 'Cancelled.'
  mptcp_restore
  mptcp_status
  exit 0
fi

# Read-only inventory on all hosts, including hosts without Apache.
# Preserve strict safety checks for --run/--rollback below.
inventory() {
  local release='unknown' apache_state='unknown' nginx_state='unknown' httpd_state='unknown' distro='unknown'
  local apache_modules='' php_modules='' fpm_packages='' php_fpm_services=''
  local errors=() item
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    release="${PRETTY_NAME:-${ID:-unknown}}"
    distro="${ID:-unknown}"
  fi
  say "Host: $(hostname -f 2>/dev/null || hostname)"
  say "OS: $release"
  if command -v php >/dev/null 2>&1; then
    say "Default PHP CLI: $(php -v 2>/dev/null | sed -n '1p')"
  else
    say 'Default PHP CLI: not installed / not in PATH'
  fi
  if command -v php8.4 >/dev/null 2>&1; then
    say "PHP 8.4 CLI: $(php8.4 -v 2>/dev/null | sed -n '1p')"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    apache_state="$(systemctl is-active apache2 2>/dev/null || true)"
    httpd_state="$(systemctl is-active httpd 2>/dev/null || true)"
    nginx_state="$(systemctl is-active nginx 2>/dev/null || true)"
    php_fpm_services="$(systemctl list-units --all --plain --no-legend 'php*-fpm.service' 2>/dev/null | sed -n '1,15p')" || true
  fi
  say "Apache (Ubuntu apache2): $apache_state"
  say "Apache (RHEL httpd): $httpd_state"
  say "Nginx state: $nginx_state"
  if [[ "$distro" == almalinux ]]; then
    if command -v rpm >/dev/null 2>&1; then
      say 'Installed RPM PHP packages:'
      rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 'php*' 2>/dev/null | sort | sed -n '1,35p' || true
    fi
    if command -v dnf >/dev/null 2>&1; then
      say 'Enabled PHP module streams:'
      dnf -q module list php --enabled 2>&1 | sed -n '1,25p' || true
    fi
    if command -v php-fpm >/dev/null 2>&1; then
      say "PHP-FPM service: $(systemctl is-active php-fpm 2>/dev/null || true)"
      php-fpm -t 2>&1 | sed -n '1,8p' || true
    fi
    if command -v httpd >/dev/null 2>&1; then
      say 'Apache httpd configuration:'
      httpd -t 2>&1 || true
    fi
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    fpm_packages="$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'php*-fpm' 2>/dev/null | awk '$2 ~ /^ii/ {print $1}' | paste -sd ',' -)" || true
  fi
  say "Installed PHP-FPM packages: ${fpm_packages:-none}"
  mptcp_status
  if [[ -n "$php_fpm_services" ]]; then
    say "PHP-FPM services:"
    printf '%s\n' "$php_fpm_services"
  else
    say "PHP-FPM services: none found in systemd list"
  fi
  if [[ -d /etc/apache2/mods-enabled ]]; then
    local module
    shopt -s nullglob
    for module in /etc/apache2/mods-enabled/php[0-9]*.load; do
      php_modules+="${module##*/} "
    done
    shopt -u nullglob
  fi
  say "Enabled Apache PHP module links: ${php_modules:-none}"
  if command -v apache2ctl >/dev/null 2>&1; then
    apache_modules="$(apache2ctl -M 2>/dev/null)" || apache_modules=''
    say 'Configured Apache virtual hosts (not proof of a running server):'
    apache2ctl -S 2>&1 | grep -E 'namevhost|default server|\*:80' || true
  fi

  if [[ "$ACTION" == '--check' ]]; then
    if [[ "${ID:-}" == almalinux ]]; then
      if [[ "${VERSION_ID:-}" != 9 && "${VERSION_ID:-}" != 9.* ]]; then
        errors+=('AlmaLinux automatic updates are supported only on major version 9')
      fi
      if ! command -v dnf >/dev/null 2>&1; then
        errors+=('DNF is unavailable')
      fi
      if [[ "$(systemctl is-active php-fpm 2>/dev/null || true)" != active ]]; then
        errors+=('Standard php-fpm service is not active; PHP handler needs review')
      fi
      if ! command -v php >/dev/null 2>&1 || [[ "$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)" != 8.4 ]]; then
        errors+=('PHP CLI is not 8.4; module switching is not automated')
      fi
      local enabled_php=''
      enabled_php="$(dnf -q module list php --enabled 2>/dev/null)" || true
      [[ "$enabled_php" =~ remi-8\.4 ]] || errors+=('PHP module stream remi-8.4 is not enabled')
      if (( ${#errors[@]} )); then
        say 'AlmaLinux 9: automatic PHP 8.4 package update NOT ELIGIBLE (no changes made).'
        for item in "${errors[@]}"; do say "  - $item"; done
        say 'Review RPM packages, enabled module and PHP-FPM handler before migration.'
      else
        say 'AlmaLinux 9: existing Remi PHP 8.4 update preliminarily ELIGIBLE; no changes made.'
        say 'Module stream switching and application compatibility are NOT covered.'
      fi
    else
      if [[ "${ID:-}" != ubuntu || ( "${VERSION_ID:-}" != 22.04 && "${VERSION_ID:-}" != 24.04 ) ]]; then
        errors+=('Automatic mod_php migration supports only Ubuntu 22.04/24.04')
      fi
      if [[ "$apache_state" != active ]]; then
        errors+=('Apache is not running; it will not be started automatically')
      fi
      if ! command -v apache2ctl >/dev/null 2>&1; then
        errors+=('Apache is not installed or apache2ctl is missing')
      else
        [[ "$apache_modules" == *mpm_prefork_module* ]] || errors+=('Apache prefork MPM not detected')
        [[ "$apache_modules" =~ [[:space:]]php_module[[:space:]] ]] || errors+=('Apache mod_php not detected')
        [[ "$apache_modules" != *proxy_fcgi_module* ]] || errors+=('Apache proxy_fcgi enabled; FPM stack requires review')
      fi
      if grep -RIEqs '(php[0-9]+\.[0-9]+-fpm|/run/php/.*fpm\.sock|ProxyPassMatch)' \
        /etc/apache2/sites-enabled /etc/apache2/conf-enabled 2>/dev/null; then
        errors+=('Apache FPM/proxy handler reference detected')
      fi
      if (( ${#errors[@]} )); then
        say 'Automatic Ubuntu mod_php migration: NOT ELIGIBLE; no changes made.'
        for item in "${errors[@]}"; do say "  - $item"; done
        say 'Review the detected web stack before enabling a migration path for it.'
      else
        say 'Automatic Ubuntu mod_php migration: preliminarily ELIGIBLE; no changes made.'
        say 'APT package availability and application compatibility are checked later.'
      fi
    fi
  fi
}

if [[ "$ACTION" == '--check' || "$ACTION" == '--status' ]]; then
  inventory
  exit 0
fi

# AlmaLinux requires DNF and PHP-FPM, not Debian's mod_php/apt workflow.
almalinux_update() {
  local php_minor enabled_stream module_catalog candidate d confpath answer
  local switch_required=0 preview_rc=0 preview_file=''
  local -a installed_php=() backup_paths=()
  need dnf
  need rpm
  need php
  need php-fpm
  need systemctl

  [[ "${VERSION_ID:-}" == 9 || "${VERSION_ID:-}" == 9.* ]] ||
    fail 'Automatic AlmaLinux PHP migration supports only AlmaLinux 9.'
  systemctl is-active --quiet php-fpm ||
    fail 'The standard php-fpm service is not active; identify the actual PHP handler with --check.'
  rpm -q php-cli php-common php-fpm >/dev/null ||
    fail 'Standard php-cli, php-common and php-fpm RPM packages must be installed.'
  [[ "$(rpm -qf "$(readlink -f "$(command -v php)")" --qf '%{NAME}' 2>/dev/null)" == php-cli ]] ||
    fail 'The active PHP CLI does not belong to the standard php-cli RPM; possible parallel/custom installation.'

  php_minor="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)" ||
    fail 'Cannot determine PHP CLI version.'
  [[ "$php_minor" =~ ^(7[.][0-4]|8[.][0-4])$ ]] ||
    fail "Source PHP $php_minor unsupported: expected standard PHP 7.x or PHP 8.0-8.4."

  enabled_stream="$(dnf -q module list php --enabled 2>/dev/null)" ||
    fail 'Cannot inspect enabled PHP module stream.'
  module_catalog="$(dnf -q module list php 2>/dev/null)" ||
    fail 'Cannot read available PHP module streams. Check Remi installation and DNF metadata.'
  [[ "$module_catalog" =~ remi-8[.]4 ]] ||
    fail 'Remi 8.4 stream not available. Configure the trusted Remi repository (remi-modular) before running migration.'

  # Query Remi's PHP 8.4 packages even if the stream is not enabled yet.
  # Require an explicitly patched candidate before changing module streams.
  candidate="$(dnf -q repoquery --disable-modular-filtering --qf '%{version} %{repoid}' php-cli 2>/dev/null |
    awk '$1 ~ /^8[.]4[.][0-9]+$/ && $2 ~ /^remi-modular/ {print $1}' |
    sort -V | tail -n 1)" ||
    fail 'DNF repoquery failed. Install/enable dnf-plugins-core and remi-modular, then retry.'
  [[ "$candidate" =~ ^8[.]4[.][0-9]+$ ]] ||
    fail "No PHP 8.4 candidate visible in remi-modular (got: ${candidate:-none}). Check repository access."
  php -r 'exit(version_compare($argv[1], $argv[2], ">=") ? 0 : 1);' -- "$candidate" "$MIN_FIXED" ||
    fail "Available PHP $candidate is older than mandatory $MIN_FIXED."
  say "Available PHP 8.4: $candidate (Remi modular)"

  php-fpm -t || fail 'Existing PHP-FPM configuration test failed.'
  if systemctl is-active --quiet httpd; then
    need httpd
    httpd -t || fail 'Existing httpd configuration test failed.'
    local httpd_modules=''
    httpd_modules="$(httpd -M 2>/dev/null)" || fail 'Cannot inspect Apache httpd modules.'
    [[ ! "$httpd_modules" =~ [[:space:]]php_module[[:space:]] ]] ||
      fail 'Apache mod_php detected; automatic AlmaLinux migration expects PHP-FPM. Review Apache handler.'
  fi
  if systemctl is-active --quiet nginx; then
    need nginx
    nginx -t || fail 'Existing nginx configuration test failed.'
  fi

  mapfile -t installed_php < <(rpm -qa --qf '%{NAME}\n' |
    awk '$1 == "php" || $1 ~ /^php-/ {print $1}' | sort -u)
  (( ${#installed_php[@]} )) || fail 'No standard PHP RPM packages installed.'
  say "Currently installed PHP RPMs: ${installed_php[*]}"

  if [[ "$php_minor" == 8.4 && "$enabled_stream" =~ remi-8[.]4 ]]; then
    say 'Remi 8.4 is already active: updating installed PHP RPMs.'
  else
    switch_required=1
    say "Switching PHP $php_minor to php:remi-8.4/common (DNF4 module switch-to)."
  fi

  # DNF --assumeno is a transaction preview; a declined transaction may have a
  # nonzero exit code. Detect success by a complete transaction summary.
  # A module switch can remove incompatible extensions: FAIL CLOSED.
  mkdir -p "$STATE_ROOT"
  d="$(mktemp -d "$STATE_ROOT/almalinux-$(date +%Y%m%d-%H%M%S)-XXXXXXXX")"
  preview_file="$d/dnf-preview.txt"
  if (( switch_required )); then
    dnf --refresh --assumeno module switch-to php:remi-8.4/common > "$preview_file" 2>&1 ||
      preview_rc=$?
  else
    dnf --refresh --assumeno upgrade "${installed_php[@]}" > "$preview_file" 2>&1 ||
      preview_rc=$?
  fi
  say "DNF preview recorded: $preview_file (exit $preview_rc)"
  if ! grep -Eq '(^Transaction Summary|^Nothing to do[.]?$)' "$preview_file"; then
    sed -n '1,100p' "$preview_file"
    fail "DNF did not produce a valid preview. No PHP packages were changed; inspect $preview_file."
  fi
  if grep -Eiq '^[[:space:]]*(Removing|Erasing|Removing dependent packages|Removing unused dependencies):' "$preview_file"; then
    say 'DNF proposes removals; review package and extension compatibility:'
    sed -n '1,180p' "$preview_file"
    fail "Package removal detected in DNF preview; no changes applied. Inspect $preview_file."
  fi
  if grep -Eiq '^Error:|^Problem:|conflicting requests|cannot install the best' "$preview_file"; then
    fail "Dependency issue detected in DNF preview: $preview_file."
  fi

  say "DNF transaction preview (first 110 lines):"
  sed -n '1,110p' "$preview_file"
  say 'The migration cannot automatically roll back RPM packages or PHP application data.'
  read -r -p 'Type SWITCH-PHP84 after taking a full VM snapshot: ' answer < /dev/tty
  [[ "$answer" == SWITCH-PHP84 ]] || fail 'Cancelled.'

  for confpath in /etc/php.ini /etc/php.d /etc/php-fpm.conf /etc/php-fpm.d /etc/httpd /etc/nginx /etc/dnf/modules.d/php.module; do
    [[ -e "$confpath" ]] && backup_paths+=("${confpath#/}")
  done
  (( ${#backup_paths[@]} )) || fail 'No configuration paths found to back up.'
  tar --acls --xattrs -czpf "$d/etc-php-web.tar.gz" -C / "${backup_paths[@]}"
  rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' | sort > "$d/rpm-before.txt"
  printf '%s\n' "$enabled_stream" > "$d/php-module-before.txt"
  php -m | LC_ALL=C sort -u > "$d/php-modules-before.txt"
  say "Backup created in $d."

  if (( switch_required )); then
    if ! dnf -y module switch-to php:remi-8.4/common; then
      fail "DNF module switch failed. Review dnf history, packages and backup $d; do not restart PHP-FPM blindly."
    fi
  fi
  # Update only currently installed standard PHP packages; no --allowerasing.
  if ! dnf -y upgrade "${installed_php[@]}"; then
    fail "DNF PHP RPM update failed. Review dnf history and backup $d."
  fi

  local actual_enabled actual_minor
  actual_enabled="$(dnf -q module list php --enabled 2>/dev/null)" ||
    fail 'Could not confirm enabled PHP module after migration.'
  [[ "$actual_enabled" =~ remi-8[.]4 ]] ||
    fail 'PHP module stream is NOT remi-8.4 after switch. Investigate DNF state.'
  actual_minor="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)" ||
    fail 'Cannot read new PHP CLI version.'
  [[ "$actual_minor" == 8.4 ]] || fail "Expected PHP 8.4, found $actual_minor."
  php -r 'exit(version_compare(PHP_VERSION, $argv[1], ">=") ? 0 : 1);' -- "$MIN_FIXED" ||
    fail "Installed PHP is older than required $MIN_FIXED."

  php -m | LC_ALL=C sort -u > "$d/php-modules-after.txt"
  comm -23 "$d/php-modules-before.txt" "$d/php-modules-after.txt" > "$d/php-modules-missing.txt" || true
  if [[ -s "$d/php-modules-missing.txt" ]]; then
    say 'CRITICAL: PHP modules disappeared during migration:'
    cat "$d/php-modules-missing.txt"
    fail "Do not restart php-fpm before resolving missing extensions. Review $d."
  fi
  php-fpm -t || fail "PHP-FPM configuration invalid after migration; investigate $d before restart."
  systemctl restart php-fpm || fail "PHP-FPM restart failed; investigate journalctl -u php-fpm and $d."
  systemctl is-active --quiet php-fpm || fail 'PHP-FPM is not active after restart.'
  if systemctl is-active --quiet httpd; then httpd -t || fail 'httpd configtest failed after migration.'; fi
  if systemctl is-active --quiet nginx; then nginx -t || fail 'nginx configtest failed after migration.'; fi

  say "AlmaLinux PHP migration completed: $(php -v | sed -n '1p')"
  say "Configuration and RPM inventory backup: $d"
  say 'Validate application endpoints, DB access and error logs. Snapshot rollback is manual.'
  mptcp_disable
}

if [[ -r /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
fi
if [[ "${ID:-}" == almalinux ]]; then
  case "$ACTION" in
    --run) almalinux_update; exit 0 ;;
    --rollback) fail 'AlmaLinux rollback requires a verified VM snapshot or reviewed DNF history, not Ubuntu mod_php rollback.' ;;
  esac
fi

need apache2ctl
need dpkg-query
need apt-get
need update-alternatives

if [[ "$ACTION" != '--rollback' && "$ACTION" != '--status' ]]; then
  # Determine the Ubuntu release from os-release, never from the running kernel.
  [[ -r /etc/os-release ]] || fail 'Cannot read /etc/os-release.'
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || fail "Only Ubuntu is supported (detected: ${ID:-unknown})."
  case "${VERSION_ID:-}" in
    22.04)
      [[ "${VERSION_CODENAME:-}" == 'jammy' ]] || fail 'Ubuntu 22.04 codename mismatch; review OS installation.'
      ;;
    24.04)
      [[ "${VERSION_CODENAME:-}" == 'noble' ]] || fail 'Ubuntu 24.04 codename mismatch; review OS installation.'
      ;;
    *) fail "Ubuntu ${VERSION_ID:-unknown} is not supported for automated PHP migration. Supported releases: 22.04 (Jammy) and 24.04 (Noble); upgrade the OS first if older." ;;
  esac
  systemctl is-active --quiet apache2 || fail 'Apache is not running.'
  # Capture the complete module list once. grep -q on a pipeline under
  # pipefail can close the reader early (SIGPIPE), falsely failing checks.
  apache_modules="$(apache2ctl -M 2>/dev/null)" || fail 'Could not inspect Apache loaded modules.'
  [[ "$apache_modules" == *mpm_prefork_module* ]] || fail 'Apache is not using mpm_prefork.'
  [[ "$apache_modules" =~ [[:space:]]php_module[[:space:]] ]] || fail 'Apache mod_php is not active.'
  if [[ "$apache_modules" == *proxy_fcgi_module* ]]; then
    fail 'proxy_fcgi is enabled; review FPM configuration manually.'
  fi
  if grep -RIEqs '(php[0-9]+\.[0-9]+-fpm|/run/php/.*fpm\.sock|ProxyPassMatch)' \
    /etc/apache2/sites-enabled /etc/apache2/conf-enabled 2>/dev/null; then
    fail 'FPM/proxy configuration detected. Manual migration required.'
  fi
fi

active_php_module() {
  local p ver names=()
  shopt -s nullglob
  for p in /etc/apache2/mods-enabled/php[0-9]*.load; do
    ver="${p##*/}"; ver="${ver#php}"; ver="${ver%.load}"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    names+=("$ver")
  done
  shopt -u nullglob
  ((${#names[@]} == 1)) || fail "Expected exactly one enabled Apache PHP module; found ${#names[@]}"
  printf '%s\n' "${names[0]}"
}

status() {
  say "Hostname: $(hostname -f 2>/dev/null || hostname)"
  say "Apache PHP module: $(active_php_module)"
  if command -v php >/dev/null; then php -v | sed -n '1p'; fi
  if command -v php8.4 >/dev/null; then php8.4 -v | sed -n '1p'; fi
  say "Apache: $(systemctl is-active apache2 || true)"
  apache2ctl -S 2>&1 | grep -E 'namevhost|default server|\*:80' || true
}

if [[ "$ACTION" == '--status' ]]; then status; exit 0; fi

rollback() {
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
  status
}

if [[ "$ACTION" == '--rollback' ]]; then rollback; exit 0; fi

old="$(active_php_module)"
say "OS: Ubuntu ${VERSION_ID} (${VERSION_CODENAME}), Apache mod_php $old -> PHP $TARGET (minimum $MIN_FIXED)"
status
if [[ "$old" == "$TARGET" ]]; then
  say 'Apache already uses PHP 8.4; no PHP migration necessary.'
  say 'For MPTCP hardening on this server, use --disable-mptcp (independent action).'
  exit 0
fi
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
if [[ "$ACTION" == '--check' ]]; then
  say 'Read-only check complete. --run will add the PHP PPA if necessary, then simulate installation.'
  say 'Current virtual hosts:'
  apache2ctl -S 2>&1 | grep -E 'namevhost|default server|\*:80' || true
  exit 0
fi

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
say 'PHP migration passed basic checks; applying requested MPTCP hardening.'
mptcp_disable
say 'Migration completed. Old PHP packages remain installed for manual rollback.'
say "Backup: $d"
say 'IMPORTANT: Test all site URLs and application functionality (login, forms, DB, cron).'
say 'If needed: sudo bash php84-migrate.sh --rollback'
