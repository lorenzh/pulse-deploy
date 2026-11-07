# shellcheck shell=bash
# Sourced by e2e/compose-e2e.sh. Replaces known credentials in diagnostic output.

# redact <needles file>: copy stdin to stdout and replace every non-empty line of the needles
# file, as a literal string, with [redacted]. Without a readable needles file it prints nothing.
redact() {
  local needles=$1
  [[ -r "$needles" ]] || { cat >/dev/null; echo "[redacted: no needles file]"; return 0; }
  awk -v nf="$needles" '
    BEGIN { while ((getline n < nf) > 0) if (length(n) > 0) needle[++k] = n }
    {
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
# (tokens, owner.env password and TOTP key, each secret file line) to a mode 600 file.
redact_needles() {
  local out=$1 owner=$2 secrets=$3 f
  shift 3
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
    } >"$out"
  )
}
