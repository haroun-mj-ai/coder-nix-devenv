#!/usr/bin/env bash
# Print the current nix profile as a markdown table.
#
# Use this to refresh the package table in README.md after adding or removing
# tools, instead of editing the table by hand:
#
#   ./scripts/export-packages.sh
#
# Note: `nix profile list` prints a multi-line block per package, so never pipe
# it through `head` to "preview" it — you will silently truncate the inventory.
set -euo pipefail

nix profile list \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | awk '
      /^Name:/         { name = $2 }
      /^Store paths:/  {
        path = $3
        sub(/^\/nix\/store\/[a-z0-9]+-/, "", path)
        # Strip the trailing version to isolate the version string itself.
        version = path
        sub(/^.*-/, "", version)
        if (name != "nix") printf "| `%s` | %s |\n", name, version
      }
    ' \
  | sort
