# Nix-free bootstrap: design note

Status: **proposal + working implementation** on branch `nix-free-bootstrap`
(2026-11-25). The Nix flake still works and is untouched. This note covers how
to move the Coder template off it.

## Why

The workspace image is Ubuntu 26.04 and already manages its system packages
with apt, including docker (`docker-ce-cli`), websockify, noVNC and x11vnc. Nix
sits on top as a second package manager for 16 developer tools plus 6 personal
extras, and it costs us:

- **Two package managers, one PATH.** `.nix-profile/bin` is placed first on
  PATH, so any overlap silently shadows the apt copy. That is why docker had to
  be dropped from the flake.
- **The unfree maze.** terraform and ngrok need `allowUnfree`, which Nix reads
  from three different places (see README), and people lose afternoons to it.
- **Image weight and build time.** The `/nix/store` closure of the toolchain is
  far larger than the upstream release binaries it wraps, and evaluating
  nixpkgs-unstable is slow on a cold builder.
- **Most of the closure is release binaries anyway.** Every tool except
  git/redis/tmux/bash-completion/jq/socat has an official prebuilt release, and
  for many of them nixpkgs fetches that same release (coder, ngrok,
  google-cloud-sdk, roborev). The sha256 values in the manifest match nix's own
  hashes for these.

## What it is

| Piece | Role |
| --- | --- |
| `bootstrap/manifest.tsv` | One row per tool: nix version, upstream version, source kind, per-arch URL **and sha256**, license, install path, verify command. It replaces `toolchainAttrs` in `flake.nix` as the source of truth. |
| `bootstrap/install.sh` | Idempotent installer. apt for distro-packaged tools; pinned + sha256-verified downloads for everything else. |
| `bootstrap/verify.sh` | Runs each `verify_cmd` with nix removed from PATH and diffs the result against the manifest. Exits non-zero on any mismatch. |
| `bootstrap/update-hashes.sh` | The only way a hash enters the manifest. It downloads the bytes, computes sha256 and writes it back. |
| `bootstrap/lib.sh` | Arch detection, a content-addressed download cache, fetch+verify, atomic unpack/link, apt helper. |
| `scripts/render-tool-sources.py` | Regenerates `docs/TOOL-SOURCES.md` from the manifest (`--check` for CI). |

Layout under the prefix (default `~/.local`):

```
~/.local/opt/<tool>/<version>/   unpacked release tree (one dir per version)
~/.local/bin/<name>              symlink into the tree (swapped atomically)
~/.local/share/blesh -> ../opt/blesh/<version>
~/.local/share/nixfree-bootstrap/env.sh   PATH snippet; sourced only if you opt in
~/.cache/nixfree-bootstrap/<sha16>-<file> content-addressed download cache
```

### Alternatives considered

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Manifest + bash (this branch)** | Zero new runtime deps; every byte pinned by sha256; readable in one sitting; apt stays the system layer | We maintain the URL list and bump versions by hand (`update-hashes.sh` makes it a one-liner per tool) | **Chosen** as the smallest step off Nix |
| [mise](https://mise.jdx.dev) | Popular; per-project `.tool-versions`; many backends | Another tool to bootstrap; checksum pinning is opt-in (lockfile) and uneven across backends; installs into `~/.local/share/mise` with shims | Good later if teams want per-repo versions |
| [aqua](https://aquaproj.github.io) | Registry with checksums and sigstore checks; lazy install | Needs the aqua binary plus a registry; not every tool here is in it (ngrok's versioned URLs, blesh nightly, python-build-standalone) | Strong option if we outgrow the manifest |
| Homebrew on Linux | Huge catalog | Pulls its own glibc/toolchain bottles, a slow first run, and a Nix-like second package manager problem | No |
| Devcontainer features | Native to devcontainers | Coder templates aren't devcontainers here; features are mostly `curl \| sh` | No |
| Keep Nix | Already works; reproducible | Every cost listed in "Why" | Stays the fallback path |

## Install order

1. **apt layer**: one batched `apt-get install` of what's missing (git,
   redis-server/redis-tools, tmux, bash-completion, jq; plus socat, websockify
   and novnc for `--layer runtime`). It is skipped entirely when everything is
   already installed. It needs sudo, or run the apt layer in the image build.
2. **Pinned artifacts, in manifest order**: nodejs_22, python311, then poetry
   (a venv built on python311 from the pinned wheel), then google-cloud-sdk,
   terraform, sops, coder, lazydocker, mongosh, railway, stripe-cli, ngrok, gh,
   ripgrep, then extras roborev, blesh, supercronic. Each is downloaded once
   to the cache, sha256-checked, unpacked into a staging dir, renamed into
   `opt/<tool>/<version>` in one step, and only then linked. A failed or
   mismatched download publishes nothing.
3. **env file**: always written. It touches `~/.bashrc` only with `--write-env`,
   and then appends one marked line, once.
4. **verify**: `bootstrap/install.sh --verify-only` (or `bootstrap/verify.sh`).

Re-running is cheap. Present versions are detected, cached downloads are
re-hashed rather than re-fetched, and apt is a no-op.

## Template-image migration

The template today builds an image with Nix, then installs this flake pinned by
`DEVENV_REV`. Steps to move it:

1. **Remove Nix from the image build.** Drop the Nix installer, the
   `nix profile add github:…coder-nix-devenv/${DEVENV_REV}` step,
   `NIX_PATH`, and the `nix.sh` profile hook.
2. **Bake the apt layer into the Dockerfile.** Workspaces may not have sudo at
   runtime:
   ```dockerfile
   RUN apt-get update && apt-get install -y --no-install-recommends \
         git redis-server redis-tools tmux bash-completion jq socat websockify novnc \
         ca-certificates curl xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*
   ```
3. **Pinned artifacts: pick one of two places.**
   - *Image build (recommended).* `git clone` this repo at `DEVENV_REV`, then
     `bootstrap/install.sh --allow-root --prefix /usr/local --layer base,extras,runtime`,
     then `bootstrap/verify.sh --prefix /usr/local --layer all`. This keeps the
     DEVENV_REV reproducibility guarantee and has zero first-boot latency.
   - *First boot.* In the Coder agent `startup_script`, as the workspace
     user: `~/coder-nix-devenv/bootstrap/install.sh --prefix ~/.local`. The
     home volume persists `~/.local/opt` and the cache, so later boots are
     no-ops. The first boot downloads about 640 MB (base 606 + extras 33;
     runtime adds 178) and unpacks to roughly 2.7 GB with runtime included.
4. **PATH changes.** `~/.nix-profile/bin` disappears. Ubuntu's `~/.profile`
   already prepends `~/.local/bin` when it exists; for non-login shells, source
   `~/.local/share/nixfree-bootstrap/env.sh` (or use `--write-env`). With a
   `/usr/local` prefix, nothing changes, because `/usr/local/bin` is already on PATH.
   Update the dotfiles that reference the profile. On this box `~/.bashrc`
   has `export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"` and sources
   `~/.nix-profile/share/bash-completion/bash_completion`. Point that at
   `/usr/share/bash-completion/bash_completion`, and ble.sh at
   `$PREFIX/share/blesh/ble.sh`. (Those dotfiles live in `coder-packages`,
   which this branch deliberately does not touch.)
5. **Replace the image-build verification.** The template re-verifies every
   flake tool and asserts `docker` is `/usr/bin/docker`. Swap the flake check
   for `bootstrap/verify.sh`, and keep the docker assertion.
6. **Replace the runtime binaries** that execute from `/nix/store` today
   (`--layer runtime`: herdr, code-server, socat; websockify is already apt), and
   install the shared browser from Playwright's CDN (`npx playwright install
   chromium`). See [DEAD-URLS.md §5](DEAD-URLS.md#5-binaries-executing-from-nixstore-that-a-nix-free-image-must-replace).

## What breaks without `/nix`, and why you must never `rm -rf /nix` on a live box

On this box, at audit time, these were **executing from `/nix/store`**:

| Process | Store path |
| --- | --- |
| `herdr server`, `herdr remote-client-bridge` | `herdr-0.9.1` |
| the shared workspace browser (CDP :9223, ~10 procs) | `playwright-chromium` |
| Hindsight MCP, mongodb-mcp-server, omp relays (~8–30 procs) | `nodejs-slim-22.23.2` |
| `desktop.py` browser helper | `python3-3.11.15` |
| the tmux server | `tmux-3.7b` |
| the Tailscale-facing `socat` relay on :3080 | `socat-1.8.1.3` |
| (installed, not running) code-server | `code-server-4.115.0` |

Deleting `/nix` under them does not stop them cleanly. Already-mapped pages keep
working until the next `dlopen`, `exec`, or lazily loaded resource, and then the
process crashes. Every new shell also loses `git`, `node`, `gh` and the rest,
because `.nix-profile/bin` is first on PATH and its symlinks would dangle. The
shared browser, herdr sessions and the relay would all go down for everyone
attached.

**Decommission order** for a live box. For new workspaces, just rebuild from
the new template.

1. `bootstrap/install.sh --layer base,extras,runtime`, then `bootstrap/verify.sh --layer all`.
2. Put `~/.local/bin` ahead of `~/.nix-profile/bin` on PATH, in a new shell.
3. Restart each service from its new binary: tmux server, socat relay, herdr,
   then the browser.
4. Confirm nothing still runs from the store:
   `for p in /proc/[0-9]*; do readlink $p/exe; done 2>/dev/null | grep -c ^/nix/store`
   must print `0`.
5. Only then remove the profile line from `~/.bashrc`. Leave `/nix` itself for
   the next rebuild; it costs disk, not correctness.

## Coexistence (transition period)

The bootstrap never reads or writes `/nix`, the nix profile or `NIX_PATH`. Both
can be installed at once, and **PATH order decides who wins**. With today's
`~/.bashrc`, nix wins, because `.nix-profile/bin` comes before `~/.local/bin`.
`verify.sh` therefore drops nix from PATH and also asserts that each pinned tool
resolves inside the prefix, so a tool missing from the prefix can't pass by
resolving to the nix copy.

## Rollback

- **Workspace:** remove the `# nixfree-bootstrap` line from `~/.bashrc` if you
  used `--write-env`, then `rm -rf ~/.local/opt/<tool>` and the matching
  `~/.local/bin` links. The nix profile was never modified, so it is still there.
- **Template:** revert the Dockerfile to the Nix-based build. Nothing in this
  branch changes `flake.nix`, `flake.lock`, or `DEVENV_REV` semantics.

## Known gaps and deltas

- **apt rows are not version-pinned.** apt installs the current Ubuntu 26.04
  candidate. Deltas vs nix: redis 8.0.5 (nix 8.8.1), git 2.53.0 (2.55.0), tmux
  3.6a (3.7b), bash-completion 2.16.0 (2.18.0), jq 1.8.1 (1.8.2), socat
  1.8.1.1 (1.8.1.3). `verify.sh` flags drift as MISMATCH. On this box git is
  2.55.0 from the git-core PPA, so it fails verify against the archive version
  by design. Decide per tool whether to pin (`apt-get install pkg=ver`, which
  needs the version to stay in the archive) or to move to a static binary
  (jq has one).
- **poetry's dependencies are not hash-pinned.** Only the poetry wheel is; its
  deps resolve from PyPI at install time. Fix: a `requirements.txt` with
  `--require-hashes` generated from a lock.
- **arm64 artifacts are downloaded and hashed but not executed.** No arm64
  machine was available. The hashes match upstream checksums, but no arm64
  binary was run.
- **gcloud on arm64** ships without bundled Python and uses the system
  `python3` (3.14 on 26.04).
- **ble.sh** is a rolling `nightly` asset. If upstream prunes old nightlies,
  the URL dies. `update-hashes.sh` will report it, and the fallback is a source
  tarball of the same commit.
- **The playwright-chromium version** moves 149 → 153 if you take Playwright's
  current CDN build. It is pinned by whichever Playwright version the browser
  launcher uses, not by this manifest.
