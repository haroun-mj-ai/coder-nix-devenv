#!/usr/bin/env bash
# Nix-free toolchain bootstrap for Ubuntu (apt), x86_64 and arm64.
#
#   ./bootstrap/install.sh                       # base + extras into ~/.local
#   ./bootstrap/install.sh --only gh --only jq   # just those tools
#   ./bootstrap/install.sh --dry-run             # print every step, change nothing
#   ./bootstrap/install.sh --verify-only         # run bootstrap/verify.sh
#
# Options:
#   --prefix DIR      install root (default: $HOME/.local). Binaries are linked
#                     into DIR/bin, trees unpacked into DIR/opt/<tool>/<version>.
#   --only TOOL       install only TOOL (repeatable; any layer). poetry pulls
#                     in python311, which it is built on.
#   --layer LIST      comma list of base,extras,runtime or all
#                     (default: base,extras). Ignored when --only is given.
#   --dry-run         print downloads, apt commands and links; change nothing
#   --verify-only     skip installing; just verify what is there
#   --write-env       also add one `source DIR/share/nixfree-bootstrap/env.sh`
#                     line to ~/.bashrc (the env file itself is always written)
#   --cache DIR       download cache (default: ~/.cache/nixfree-bootstrap)
#   --allow-root      permit running as root (image builds with a system prefix)
#
# Every non-apt artifact is pinned by URL and sha256 in bootstrap/manifest.tsv
# and verified before it is unpacked. apt packages come from whatever apt
# sources the machine has; apt checks their signatures itself.
set -euo pipefail

BOOTSTRAP_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bootstrap/lib.sh
source "$BOOTSTRAP_DIR/lib.sh"

prefix=$HOME/.local
only=() layers=base,extras
DRY_RUN=0 verify_only=0 write_env=0 allow_root=0

while (($#)); do
  case "$1" in
    --prefix) prefix=${2:?--prefix needs a value}; shift 2 ;;
    --only) only+=("${2:?--only needs a tool}"); shift 2 ;;
    --layer) layers=${2:?--layer needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verify-only) verify_only=1; shift ;;
    --write-env) write_env=1; shift ;;
    --cache) BOOTSTRAP_CACHE=${2:?--cache needs a value}; shift 2 ;;
    --allow-root) allow_root=1; shift ;;
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
export DRY_RUN BOOTSTRAP_CACHE
[[ $layers == all ]] && layers=base,extras,runtime

if [[ $verify_only == 1 ]]; then
  args=(--prefix "$prefix" --layer "$layers")
  for t in "${only[@]}"; do args+=(--only "$t"); done
  exec "$BOOTSTRAP_DIR/verify.sh" "${args[@]}"
fi

if [[ $(id -u) == 0 && $allow_root == 0 ]]; then
  die "refusing to run as root: the prefix would end up root-owned.
  Run as your normal user (apt steps use sudo), or pass --allow-root for an
  image build that installs into a system prefix such as /usr/local."
fi

if [[ $DRY_RUN == 0 ]]; then mkdir -p "$prefix" || die "cannot create $prefix"; fi
prefix=$(cd "$prefix" 2>/dev/null && pwd || echo "$prefix")

arch=$(detect_arch)
log "nix-free bootstrap: arch=$arch prefix=$prefix$([[ $DRY_RUN == 1 ]] && echo ' (dry run)')"

# ---------------------------------------------------------------- selection

declare -A known=()
selected=()
while IFS= read -r line; do
  declare -A r=()
  manifest_parse r "$line"
  known[${r[tool]}]=1
  if ((${#only[@]})); then
    [[ " ${only[*]} " == *" ${r[tool]} "* ]] && selected+=("$line")
  elif [[ ",$layers," == *",${r[layer]},"* ]]; then
    selected+=("$line")
  fi
done < <(manifest_rows)

for t in "${only[@]}"; do [[ -n ${known[$t]:-} ]] || die "unknown tool '$t' (not in $MANIFEST)"; done
# poetry is a venv on python311; make sure python311 comes along.
if [[ " ${only[*]} " == *" poetry "* && " ${only[*]} " != *" python311 "* ]]; then
  info "poetry needs python311; adding it"
  selected=("$(manifest_rows | awk -F'\t' '$1 == "python311"')" "${selected[@]}")
fi
((${#selected[@]})) || die "nothing selected"

# ---------------------------------------------------------------- install

declare -A status=()
order=()

# 1. apt layer, one batched apt-get call (cheap no-op when all present).
apt_pkgs=()
for line in "${selected[@]}"; do
  declare -A r=(); manifest_parse r "$line"
  if [[ ${r[source_kind]} == apt ]]; then
    read -r -a pkgs <<<"${r[bins]}"
    apt_pkgs+=("${pkgs[@]}")
    order+=("${r[tool]}")
  fi
done
if ((${#apt_pkgs[@]})); then
  log "apt: ${apt_pkgs[*]}"
  if apt_install "${apt_pkgs[@]}"; then st=ok; else st=FAILED; fi
  [[ $DRY_RUN == 1 ]] && st=dry-run
  for line in "${selected[@]}"; do
    declare -A r=(); manifest_parse r "$line"
    [[ ${r[source_kind]} == apt ]] && status[${r[tool]}]="$st (apt: ${r[bins]})"
  done
fi

install_pip() { # tool version wheel prefix bins
  local tool=$1 version=$2 wheel=$3 pfx=$4 bins=$5 venv py tmpd
  venv=$pfx/opt/$tool/$version
  py=$pfx/bin/python3.11
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] would create venv $venv with $py and pip install ${wheel##*/}"
    return 0
  fi
  [[ -x $py ]] || die "$tool needs python311 in $pfx (install.sh --only python311)"
  # venvs are not relocatable (absolute shebangs), so it is built in place;
  # the .complete marker is what makes a half-built venv detectable.
  if [[ ! -f $venv/.complete ]]; then
    rm -rf "$venv"
    tmpd=$(mktemp -d)
    # pip insists on the canonical wheel filename; the cache name carries a
    # 16-hex-char hash prefix plus a dash (see fetch_verified).
    local base=${wheel##*/}
    cp "$wheel" "$tmpd/${base:17}"
    "$py" -m venv "$venv"
    "$venv/bin/pip" install --quiet --disable-pip-version-check "$tmpd"/*.whl \
      || { rm -rf "$venv" "$tmpd"; die "pip install failed for $tool"; }
    rm -rf "$tmpd"
    touch "$venv/.complete"
  else
    info "$tool $version venv already complete at $venv"
  fi
  local dest src
  while IFS='=' read -r dest src; do _link "$venv/$src" "$(_bin_dest "$pfx" "$dest")"; done < <(_for_each_bin "$bins")
}

# 2. pinned artifacts, in manifest order (python311 precedes poetry there).
for line in "${selected[@]}"; do
  declare -A r=(); manifest_parse r "$line"
  kind=${r[source_kind]} tool=${r[tool]}
  [[ $kind == apt ]] && continue
  order+=("$tool")
  if [[ $kind == none ]]; then status[$tool]="skipped (no non-nix source)"; continue; fi
  url=${r[url_$arch]} sha=${r[sha256_$arch]}
  if [[ -z $url || $url == - || -z $sha || $sha == - ]]; then
    status[$tool]="FAILED (no $arch artifact in manifest)"; continue
  fi
  log "$tool ${r[upstream_version]} ($kind)"
  if (
    set -e
    file=$(fetch_verified "$url" "$sha")
    if [[ $kind == pip ]]; then
      install_pip "$tool" "${r[upstream_version]}" "$file" "$prefix" "${r[bins]}"
    else
      install_from_tarball "$tool" "${r[upstream_version]}" "$file" "$url" "${r[bins]}" "$prefix"
    fi
  ); then
    status[$tool]=$([[ $DRY_RUN == 1 ]] && echo dry-run || echo ok)
  else
    status[$tool]=FAILED
  fi
done

# ---------------------------------------------------------------- env file

env_file=$prefix/share/nixfree-bootstrap/env.sh
if [[ $DRY_RUN == 1 ]]; then
  info "[dry-run] would write $env_file"
else
  mkdir -p "${env_file%/*}"
  cat >"$env_file.tmp" <<EOF
# Generated by coder-nix-devenv bootstrap/install.sh. Safe to source repeatedly.
case ":\$PATH:" in *":$prefix/bin:"*) ;; *) export PATH="$prefix/bin:\$PATH" ;; esac
EOF
  mv -f "$env_file.tmp" "$env_file"
fi
if [[ $write_env == 1 ]]; then
  line="[ -r \"$env_file\" ] && . \"$env_file\"  # nixfree-bootstrap"
  if grep -qF '# nixfree-bootstrap' "$HOME/.bashrc" 2>/dev/null; then
    info "$HOME/.bashrc already sources the bootstrap env"
  elif [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] would append to ~/.bashrc: $line"
  else
    printf '\n%s\n' "$line" >>"$HOME/.bashrc"
    info "appended env line to ~/.bashrc"
  fi
fi

# ---------------------------------------------------------------- summary

failed=0
printf '\n%-18s %s\n' TOOL RESULT
for t in "${order[@]}"; do
  printf '%-18s %s\n' "$t" "${status[$t]:-?}"
  [[ ${status[$t]:-} == FAILED* ]] && failed=1
done
printf '\nprefix: %s\n' "$prefix"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) printf 'note: %s/bin is not on PATH. Run:  . %s   (or rerun with --write-env)\n' "$prefix" "$env_file" ;;
esac
((failed == 0)) || die "some tools failed to install"
