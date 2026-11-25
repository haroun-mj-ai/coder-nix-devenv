#!/usr/bin/env bash
# Download every artifact URL in manifest.tsv and write the sha256 of the
# downloaded bytes back into the manifest. This is the ONLY way hashes should
# enter the manifest — never paste one from a web page.
#
#   bootstrap/update-hashes.sh                 # every row
#   bootstrap/update-hashes.sh --only gh ...   # selected tools
#   bootstrap/update-hashes.sh --audit FILE    # also write url<TAB>http<TAB>bytes<TAB>sha256
#
# Downloads go to $BOOTSTRAP_CACHE (default ~/.cache/nixfree-bootstrap).
set -euo pipefail

# shellcheck source=bootstrap/lib.sh
source "$(dirname "$0")/lib.sh"

only=() audit=/dev/null
while (($#)); do
  case "$1" in
    --only) only+=("$2"); shift 2 ;;
    --audit) audit=$2; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

mkdir -p "$BOOTSTRAP_CACHE"
declare -A hash_for=()
fail=0

# fetch_hash URL -> sets REPLY to the sha256, or '' on failure (recorded).
fetch_hash() {
  local url=$1 tmp code bytes
  REPLY=''
  if [[ -n ${hash_for[$url]:-} ]]; then REPLY=${hash_for[$url]}; return; fi
  tmp=$(mktemp "$BOOTSTRAP_CACHE/.uh.XXXXXX")
  code=$(curl -sSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp" \
    -w '%{http_code}' "$url" 2>/dev/null) || true
  bytes=$(stat -c %s "$tmp")
  if [[ $code != 200 ]]; then
    warn "FAILED $code $url"
    printf '%s\t%s\t%s\t%s\n' "$url" "$code" "$bytes" "-" >>"$audit"
    rm -f "$tmp"; fail=1; return
  fi
  REPLY=$(sha256_of "$tmp")
  hash_for[$url]=$REPLY
  mv -f "$tmp" "$BOOTSTRAP_CACHE/${REPLY:0:16}-$(basename "${url%%\?*}")"
  printf '%s\t%s\t%s\t%s\n' "$url" "$code" "$bytes" "$REPLY" >>"$audit"
  info "$code $bytes $REPLY $url"
}

out=$(mktemp)
trap 'rm -f "$out"' EXIT
head -n1 "$MANIFEST" >"$out"
while IFS= read -r line; do
  declare -A row=()
  manifest_parse row "$line"
  if ((${#only[@]})) && [[ " ${only[*]} " != *" ${row[tool]} "* ]]; then
    printf '%s\n' "$line" >>"$out"; continue
  fi
  log "${row[tool]}"
  for a in x86_64 arm64; do
    u=${row[url_$a]}
    [[ $u == - || -z $u ]] && { row[sha256_$a]=-; continue; }
    fetch_hash "$u"
    row[sha256_$a]=${REPLY:-}
  done
  vals=()
  for c in "${MANIFEST_COLUMNS[@]}"; do vals+=("${row[$c]}"); done
  (IFS=$'\t'; printf '%s\n' "${vals[*]}") >>"$out"
done < <(tail -n +2 "$MANIFEST")

cp "$out" "$MANIFEST"
((fail == 0)) || die "one or more downloads failed; their sha256 cells were left empty"
log "manifest hashes updated"
