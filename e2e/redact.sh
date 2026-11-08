# shellcheck shell=bash
# Sourced by e2e/compose-e2e.sh, e2e/console-lib.sh and e2e/failure-logs.sh. Records and replaces
# credentials in diagnostic output. It only defines functions.
#
# The needle registry is the file named by E2E_NEEDLES: mode 600, in a mode 700 directory of the
# run owner. Only a run owner creates it. Helpers append each value as soon as they see it. A failed
# append makes the registry invalid for good: the marker "$E2E_NEEDLES.invalid" is created and the
# registry removed. Consumers then print no log line. An empty E2E_NEEDLES means "no registry".

# needles_valid: 0 when E2E_NEEDLES is empty, or names a regular, readable and writable file (not a
# symlink) in a writable directory and no invalid marker exists. Prints nothing.
needles_valid() {
  local f=${E2E_NEEDLES:-}
  [[ -z "$f" ]] && return 0
  [[ ! -e "$f.invalid" && ! -L "$f.invalid" ]] || return 1
  [[ -f "$f" && ! -L "$f" && -r "$f" && -w "$f" ]] || return 1
  [[ -w "$(dirname -- "$f")" ]] || return 1
  return 0
}

# needles_invalidate: mark the registry invalid and remove it, both best effort and silent.
needles_invalidate() {
  [[ -n "${E2E_NEEDLES:-}" ]] || return 0
  (umask 077; : >"$E2E_NEEDLES.invalid") 2>/dev/null || true
  rm -f -- "$E2E_NEEDLES" 2>/dev/null || true
  return 0
}

# needle_add <value...>: append each value of at least 6 characters to the registry. Returns 1
# without writing when the registry is invalid, and invalidates it when an append fails.
needle_add() {
  [[ -n "${E2E_NEEDLES:-}" ]] || return 0
  needles_valid || return 1
  local v
  for v in "$@"; do
    ((${#v} >= 6)) || continue
    if ! (umask 077; printf '%s\n' "$v" >>"$E2E_NEEDLES") 2>/dev/null; then
      needles_invalidate
      return 1
    fi
  done
  return 0
}

# redact <needles file>: copy stdin to stdout and replace every non-empty line of the needles
# file, as a literal string, with [redacted]. A line with a credential-bearing field prints as
# [suppressed: credential line]. Without a readable needles file it prints no log line.
redact() {
  local needles=$1
  [[ -r "$needles" ]] || { cat >/dev/null; echo "[redacted: no needles file]"; return 0; }
  awk -v nf="$needles" '
    BEGIN {
      while ((getline n < nf) > 0) if (length(n) > 0) needle[++k] = n
      q = "(\\\\?[\"\047])?"; ws = "[ \t]*"
      h4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
      rc = h4; for (g = 1; g < 8; g++) rc = rc "-" h4
      d6 = "[0-9][0-9][0-9][0-9][0-9][0-9]"
      s[1] = "(^|[^a-z0-9_-])" q "(set-)?cookies?" q ws "[:=]"
      s[2] = "pulse_console_(session|csrf|setup)" q ws "[:=]"
      s[3] = "(^|[^a-z0-9_])" q "(csrf|xsrf|csrf[-_]token|xsrf[-_]token|form_token|recovery_codes?|totp_code)" q ws "[:=]"
      s[4] = "name" ws "=" ws q "(csrf|form_token|code|recovery_code)" q "([^a-z0-9_-]|$)"
      s[5] = "(^|[^a-z0-9_])" q "(code|totp)" q ws "[:=]" ws q d6 "([^0-9]|$)"
      s[6] = "id" ws "=" ws q "recovery-codes"
      s[7] = "(^|[^0-9a-z])" rc "([^0-9a-z]|$)"
      s[8] = "(^|[^a-z0-9_-])" q "(proxy-)?authorization" q ws "[:=]"
      s[9] = "setup[ _-]?code" q ws "[:=]"
    }
    {
      low = tolower($0)
      for (j = 1; j <= 9; j++) if (low ~ s[j]) { print "[suppressed: credential line]"; next }
      line = $0
      for (j = 1; j <= k; j++) {
        out = ""
        while ((i = index(line, needle[j])) > 0) {
          out = out substr(line, 1, i - 1) "[redacted]"
          line = substr(line, i + length(needle[j]))
        }
        line = out line
      }
      print line
    }'
}

# redact_needles <out file> <owner dir> <secrets dir> <token...>: write the credentials of this run
# (tokens, owner.env password and TOTP key, each secret file line, each registry line) to a mode
# 600 file, without empty or duplicate lines, longest first. With an invalid registry it removes
# the out file and returns 1.
redact_needles() {
  local out=$1 owner=$2 secrets=$3 f
  shift 3
  if [[ -n "${E2E_NEEDLES:-}" ]] && ! needles_valid; then
    rm -f -- "$out"
    return 1
  fi
  (
    umask 077
    {
      printf '%s\n' "$@"
      [[ -z "$owner" || ! -f "$owner/owner.env" ]] ||
        sed -n 's/^\(password\|setup_key\)=//p' "$owner/owner.env"
      if [[ -n "$secrets" && -d "$secrets" ]]; then
        while IFS= read -r -d '' f; do cat "$f" 2>/dev/null; echo; done \
          < <(find "$secrets" -type f -print0 2>/dev/null)
      fi
      [[ -z "${E2E_NEEDLES:-}" ]] || cat -- "$E2E_NEEDLES"
    } | awk 'length($0) > 0 && !seen[$0]++ { print length($0) "\t" $0 }' |
      sort -t "$(printf '\t')" -k1,1nr -s | cut -f 2- >"$out"
  )
}
