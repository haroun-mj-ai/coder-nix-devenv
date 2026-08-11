#!/usr/bin/env bash
# Print this flake's toolchain as a markdown table, for pasting into README.md.
#
#   ./scripts/export-packages.sh
#
# The data comes from the `toolchain` list in flake.nix (via the toolchainInfo
# output), NOT from the live `nix profile list`. That is deliberate: a running
# workspace accumulates hand-installed extras and can lag the flake, so the
# flake is the source of truth and the profile is not.
set -euo pipefail

cd "$(dirname "$0")/.."

system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

nix eval ".#toolchainInfo.${system}" --json \
  | python3 -c '
import json, sys

rows = json.load(sys.stdin)
rows.sort(key=lambda r: r["name"])

print("| Package | Version | License |")
print("| --- | --- | --- |")
for r in rows:
    lic = "unfree" if r["unfree"] else "free"
    print(f'"'"'| `{r["name"]}` | {r["version"]} | {lic} |'"'"')
'
