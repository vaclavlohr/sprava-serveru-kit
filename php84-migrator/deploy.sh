#!/usr/bin/env bash
# Run the pinned/local PHP migration script over SSH without GitHub credentials on servers.
set -Eeuo pipefail
umask 077

usage() {
  echo 'Usage: ./deploy.sh user@server [--check|--run|--status|--rollback|--disable-mptcp|--restore-mptcp]' >&2
  echo 'Default is --check. --run prompts for MIGRATE; MPTCP actions require their own confirmation.' >&2
}

if (( $# < 1 || $# > 2 )); then usage; exit 2; fi
remote="$1"
action="${2:---check}"
[[ "$remote" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*$ ]] || { echo 'Invalid SSH destination.' >&2; exit 2; }
case "$action" in
  --check|--run|--status|--rollback|--disable-mptcp|--restore-mptcp) ;;
  *) usage; exit 2 ;;
esac
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_file="$script_dir/php84-migrate.sh"
[[ -r "$source_file" ]] || { echo 'Cannot read php84-migrate.sh.' >&2; exit 1; }
command -v ssh >/dev/null
command -v scp >/dev/null
command -v sha256sum >/dev/null

# Use SSH to create a randomized remote staging location, then verify byte-for-byte
# before executing. Script credentials live only on the administrator workstation.
remote_file="$(ssh -T -- "$remote" 'umask 077; mktemp /tmp/php84-migrate.XXXXXXXX.sh')"
[[ "$remote_file" =~ ^/tmp/php84-migrate\.[a-zA-Z0-9]{8}\.sh$ ]] || {
  echo 'Unexpected remote temp path.' >&2; exit 1;
}
scp -q -- "$source_file" "$remote:$remote_file"
local_sha="$(sha256sum "$source_file" | cut -d ' ' -f1)"
remote_sha="$(ssh -T -- "$remote" "sha256sum '$remote_file'" | cut -d ' ' -f1)"
if [[ "$local_sha" != "$remote_sha" ]]; then
  ssh -T -- "$remote" "rm -f '$remote_file'" || true
  echo 'Checksum mismatch; migration aborted.' >&2
  exit 1
fi

# -tt allocates a remote terminal so sudo and the MIGRATE/ROLLBACK prompts work.
# The temporary script is removed after execution, including on a nonzero exit.
ssh -tt -- "$remote" "sudo bash '$remote_file' '$action'; code=\$?; rm -f '$remote_file'; exit \$code"
