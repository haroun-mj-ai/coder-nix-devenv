# shellcheck shell=bash
# Shared helpers for bootstrap/install.sh, bootstrap/verify.sh and
# bootstrap/update-hashes.sh. Source it; do not execute it.
#
# Nothing in here touches /nix, the nix profile, or any shell rc file.

BOOTSTRAP_DIR=${BOOTSTRAP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
MANIFEST=${MANIFEST:-$BOOTSTRAP_DIR/manifest.tsv}
BOOTSTRAP_CACHE=${BOOTSTRAP_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nixfree-bootstrap}

# Column order of manifest.tsv. Kept in one place so every script agrees.
MANIFEST_COLUMNS=(tool layer nix_version upstream_version source_kind
  url_x86_64 sha256_x86_64 url_arm64 sha256_arm64 license
  install_path verify_cmd bins notes)

# ---------------------------------------------------------------- logging

if [[ -t 2 ]]; then
  _c_dim=$'\e[2m' _c_red=$'\e[31m' _c_grn=$'\e[32m' _c_ylw=$'\e[33m' _c_off=$'\e[0m'
else
  _c_dim='' _c_red='' _c_grn='' _c_ylw='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
info() { printf '%s    %s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
warn() { printf '%swarn:%s %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# Print a command instead of running it when DRY_RUN=1.
run() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '[dry-run]' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- platform

# Echoes the manifest column suffix for this machine: x86_64 or arm64.
detect_arch() {
  local m=${BOOTSTRAP_ARCH:-$(uname -m)}
  case "$m" in
    x86_64 | amd64) echo x86_64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture: $m (supported: x86_64, aarch64)" ;;
  esac
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------- manifest

# Emits manifest rows (tab-separated, header and comments stripped).
manifest_rows() {
  [[ -r $MANIFEST ]] || die "manifest not found: $MANIFEST"
  awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF > 1' "$MANIFEST"
}

# Reads one manifest row into the associative array named by $1.
#   declare -A row; manifest_parse row "$line"
manifest_parse() {
  local -n _row=$1
  local i rest=$2
  local -a f=()
  # Split by hand: `read -a` with IFS=$'\t' collapses runs of tabs (tab is
  # IFS whitespace), which would shift every column after an empty one.
  for ((i = 0; i < ${#MANIFEST_COLUMNS[@]}; i++)); do
    if [[ $rest == *$'\t'* ]]; then
      f+=("${rest%%$'\t'*}")
      rest=${rest#*$'\t'}
    else
      f+=("$rest")
      rest=''
    fi
  done
  _row=()
  for ((i = 0; i < ${#MANIFEST_COLUMNS[@]}; i++)); do
    # shellcheck disable=SC2004 # associative key, not arithmetic
    _row[${MANIFEST_COLUMNS[i]}]=${f[i]:-}
  done
}

# ---------------------------------------------------------------- downloads

# fetch_verified URL SHA256 -> echoes the path of a cached, verified file.
#
# The cache is content-addressed by the expected hash, so a re-run is free and
# a changed pin can never pick up a stale file. The download lands in a temp
# file and is only moved into place after the hash matches.
fetch_verified() {
  local url=$1 want=$2 name dest tmp got
  [[ -n $url && -n $want ]] || die "fetch_verified: url and sha256 are required"
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "fetch_verified: bad sha256 '$want' for $url"
  name=${url##*/}; name=${name%%\?*}
  dest=$BOOTSTRAP_CACHE/${want:0:16}-$name
  if [[ -f $dest ]] && [[ $(sha256_of "$dest") == "$want" ]]; then
    info "cache hit $name"
    echo "$dest"; return 0
  fi
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    info "[dry-run] would download $url -> $dest (sha256 $want)"
    echo "$dest"; return 0
  fi
  mkdir -p "$BOOTSTRAP_CACHE"
  tmp=$(mktemp "$BOOTSTRAP_CACHE/.dl.XXXXXX")
  info "downloading $url"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp" "$url"; then
    rm -f "$tmp"; die "download failed: $url"
  fi
  got=$(sha256_of "$tmp")
  if [[ $got != "$want" ]]; then
    rm -f "$tmp"
    die "sha256 mismatch for $url
  expected $want
  got      $got"
  fi
  mv -f "$tmp" "$dest"
  echo "$dest"
}

# ---------------------------------------------------------------- installs

# Unpacks ARCHIVE into an empty DIR. A file whose name has no archive suffix is
# treated as a bare executable and copied in as BINNAME.
_unpack() {
  local archive=$1 dir=$2 url_name=$3 binname=$4
  case "$url_name" in
    *.tar.gz | *.tgz) tar -xzf "$archive" -C "$dir" ;;
    *.tar.xz) tar -xJf "$archive" -C "$dir" ;;
    *.tar.bz2) tar -xjf "$archive" -C "$dir" ;;
    *.zip)
      if command -v unzip >/dev/null; then unzip -q "$archive" -d "$dir"
      else python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$archive" "$dir"
        find "$dir" -type f -exec chmod +x {} + # zipfile drops modes
      fi ;;
    *) install -m 0755 "$archive" "$dir/$binname" ;;
  esac
}

# Atomically points LINK at TARGET (symlink swap via rename).
_link() {
  local target=$1 link=$2 tmp
  mkdir -p "$(dirname "$link")"
  tmp="$(dirname "$link")/.$(basename "$link").tmp.$$"
  ln -sfn "$target" "$tmp"
  mv -Tf "$tmp" "$link"
}

# install_from_tarball TOOL VERSION ARCHIVE URL BINS PREFIX
#
# Unpacks into PREFIX/opt/TOOL/VERSION via a staging dir and a single rename,
# so a half-extracted tree is never visible. BINS is "dest=src,..." where src
# is relative to the unpacked root (a lone top-level directory is stripped)
# and dest is a bare name (-> PREFIX/bin/NAME) or a PREFIX-relative path.
install_from_tarball() {
  local tool=$1 version=$2 archive=$3 url=$4 bins=$5 prefix=$6
  local optdir=$prefix/opt/$tool final stage root entry dest src first_bin
  final=$optdir/$version
  first_bin=${bins%%,*}; first_bin=${first_bin%%=*}; first_bin=${first_bin##*/}

  if [[ ${DRY_RUN:-0} == 1 ]]; then
    info "[dry-run] would unpack ${archive##*/} -> $final"
    _for_each_bin "$bins" | while IFS='=' read -r dest src; do
      entry=$final/$src
      info "[dry-run] would link $(_bin_dest "$prefix" "$dest") -> ${entry%/.}"
    done
    return 0
  fi

  if [[ -d $final ]]; then
    info "$tool $version already unpacked at $final"
  else
    mkdir -p "$optdir"
    stage=$(mktemp -d "$optdir/.stage.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" RETURN
    mkdir "$stage/x"
    _unpack "$archive" "$stage/x" "${url##*/}" "$first_bin"
    root=$stage/x
    shopt -s nullglob dotglob
    local -a entries=("$root"/*)
    shopt -u nullglob dotglob
    if ((${#entries[@]} == 1)) && [[ -d ${entries[0]} ]]; then
      root=${entries[0]}
    fi
    # Check every declared entry point exists before publishing anything.
    while IFS='=' read -r dest src; do
      [[ -e $root/$src || -L $root/$src ]] || die "$tool: '$src' not found in ${archive##*/}"
    done < <(_for_each_bin "$bins")
    mv -T "$root" "$final"
  fi

  while IFS='=' read -r dest src; do
    entry=$final/$src; entry=${entry%/.}
    _link "$entry" "$(_bin_dest "$prefix" "$dest")"
  done < <(_for_each_bin "$bins")
}

_for_each_bin() { tr ',' '\n' <<<"$1" | sed '/^$/d'; }
_bin_dest() { if [[ $2 == */* ]]; then echo "$1/$2"; else echo "$1/bin/$2"; fi; }

# apt_install PKG... — installs only what is missing. Uses sudo unless root.
apt_install() {
  local -a missing=()
  local p
  for p in "$@"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
      info "apt: $p already installed ($(dpkg-query -W -f='${Version}' "$p"))"
    else
      missing+=("$p")
    fi
  done
  ((${#missing[@]})) || return 0
  command -v apt-get >/dev/null || die "apt-get not found; this bootstrap targets Ubuntu/Debian"
  local -a sudo=()
  [[ $(id -u) == 0 ]] || sudo=(sudo)
  run "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}
