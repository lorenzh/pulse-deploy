#!/usr/bin/env bash
# The documented checksum check of one downloaded asset (docs/cli.md, "Install").
# Usage: verify-download.sh <asset>, run in the directory that holds <asset> and SHA256SUMS.
# Prints "<asset>: OK" and exits 0 only when the asset's own line of SHA256SUMS matches.
# The block between the markers must equal the one in docs/cli.md (cli/docs.test.ts).
set -u
asset=${1:?usage: verify-download.sh <asset>}

# verify-download:start
expected=$(awk -v f="$asset" '$2 == f { print $1 }' SHA256SUMS)
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$asset"); else actual=$(shasum -a 256 "$asset"); fi
actual=${actual%% *}
test -n "$expected" && test "$expected" = "$actual" && echo "$asset: OK"
# verify-download:end
