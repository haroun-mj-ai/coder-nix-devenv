#!/usr/bin/env bash
# Run each tool's verify_cmd from manifest.tsv and compare against the pinned
# upstream_version. Exits non-zero on any mismatch or missing tool.
#
#   bootstrap/verify.sh [--prefix DIR] [--only TOOL]... [--layer base,extras|all]
#
# PATH is rebuilt as PREFIX/bin plus the standard system dirs, deliberately
# WITHOUT ~/.nix-profile/bin: on a box that still has nix, a tool missing from
# the prefix would otherwise resolve to the nix copy and pass by accident.
# Each tool must also resolve to where its source puts it (PREFIX for pinned
# artifacts, outside PREFIX for apt).
set -euo pipefail

# shellcheck source=bootstrap/lib.sh
source "$(dirname "$0")/lib.sh"

prefix=$HOME/.local only=() layers=base,extras
while (($#)); do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --only) only+=("$2"); shift 2 ;;
    --layer) layers=$2; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $layers == all ]] && layers=base,extras,runtime
prefix=$(cd "$prefix" 2>/dev/null && pwd || echo "$prefix")

export PREFIX=$prefix
export PATH=$prefix/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

bad=0 n=0
printf '%-18s %-9s %-24s %s\n' TOOL RESULT EXPECTED GOT
while IFS= read -r line; do
  declare -A r=()
  manifest_parse r "$line"
  if ((${#only[@]})); then
    [[ " ${only[*]} " == *" ${r[tool]} "* ]] || continue
  else
    [[ ",$layers," == *",${r[layer]},"* ]] || continue
  fi
  n=$((n + 1))
  want=${r[upstream_version]} result=PASS where=''

  # Where should the entry point live?
  first=${r[bins]%%,*}; first=${first%%=*}
  if [[ ${r[source_kind]} != apt && $first != */* ]]; then
    where=$(command -v "$first" || true)
    if [[ -z $where ]]; then result=MISSING
    elif [[ $where != "$prefix"/* ]]; then result=WRONGPATH
    fi
  fi

  got=''
  if [[ $result == PASS ]]; then
    got=$(timeout 60 bash -c "${r[verify_cmd]}" 2>&1 </dev/null | head -n 3 | tr '\n' ' ') || true
    got=${got%"${got##*[![:space:]]}"}
    if [[ $got != *"$want"* ]]; then
      case "$got" in
        '' | *"not found"* | *"no packages found"*) result=MISSING ;;
        *) result=MISMATCH ;;
      esac
    fi
  else
    got=${where:-not on PATH}
  fi
  [[ $result == PASS ]] || bad=1
  printf '%-18s %-9s %-24s %s\n' "${r[tool]}" "$result" "$want" "${got:0:90}"
done < <(manifest_rows)

((n > 0)) || die "no tools matched"
if ((bad)); then
  printf '\nverify: FAIL (%d checked)\n' "$n"; exit 1
fi
printf '\nverify: OK (%d checked)\n' "$n"
