#!/usr/bin/env bash
# init-secrets.sh [--dir <dir>]: create the host secrets directory (mode 0700) and three random
# values, each mode 0600: the probe token <dir>/probe-token and the console admin token
# <dir>/admin-token, and the console encryption key <dir>/console-secret-key. Each is created on its own; an existing token is never overwritten.
# Default directory: secrets/ at the repository root. Prints the path, never the value.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets"
while (($# > 0)); do
  case "$1" in
    --dir)
      [[ $# -ge 2 && -n "$2" ]] || { echo "init-secrets: --dir needs a directory" >&2; exit 2; }
      dir=$2
      shift 2
      ;;
    -h | --help)
      echo "usage: scripts/init-secrets.sh [--dir <dir>]"
      exit 0
      ;;
    *)
      echo "init-secrets: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
tmp=""
trap 'rm -f "$tmp"' EXIT

# make_token <name>: write a random token to <dir>/<name> unless it exists.
make_token() {
  local file="$dir/$1"
  if [[ -e "$file" || -L "$file" ]]; then
    echo "init-secrets: $file exists, kept"
    return 0
  fi
  # mktemp creates a new file with a random name and O_EXCL, so it never follows a
  # planted symlink.
  tmp="$(mktemp "$dir/.$1.XXXXXXXXXX")"
  # 32 random bytes as 64 hex characters.
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | head -c 64 >"$tmp"
  printf '\n' >>"$tmp"
  chmod 600 "$tmp"
  mv -n "$tmp" "$file"
  tmp=""
  echo "init-secrets: wrote $file"
}

make_token probe-token
make_token admin-token
# The console encryption key: same format (64 lowercase hex characters and a newline).
make_token console-secret-key
