# Dead-URL audit (nix-free bootstrap)

Audit date: **2026-11-25**, from an Ubuntu 26.04 x86_64 Coder workspace.
Every status below comes from an actual `curl` run (redirects followed). Nothing
was inferred from memory. Statuses drift, so re-run the commands at the bottom
before relying on this list.

**Summary**

| Scope | URLs checked | Dead |
| --- | ---: | ---: |
| Artifact URLs in `bootstrap/manifest.tsv` | 36 | 0 |
| URLs rejected while sourcing the table | 4 | 0 dead, 4 rejected (wrong bytes) |
| URLs the bootstrap brief expected to be dead | 7 | **0** (all alive) |
| Every public URL in both repos' tracked files | 2,926 | 17 confirmed dead |

None of the dead URLs is something the toolchain, the flakes or the bootstrap
depend on. One (`starlette.io`) is in a workflow config in `coder-packages`.
All the others are reference links in a vendored skill dataset.

## 1. Artifact URLs in the manifest: 36/36 alive

`bootstrap/update-hashes.sh` downloaded all 36 unique artifact URLs (19 pinned
tools × 2 arches; poetry and blesh are arch-independent) and got HTTP 200 for each.
It computed every sha256 from the downloaded bytes. Each hash was then
cross-checked against a source that is independent of that download:

| Cross-check | Tools |
| --- | --- |
| Upstream checksum file (`SHASUMS256.txt`, `*_SHA256SUMS`, `checksums.txt`, `*.sha256`) | nodejs_22, python311, terraform, sops, coder, lazydocker, stripe-cli, gh, ripgrep, roborev |
| GitHub release asset `digest` (sha256) | mongosh, railway, blesh, herdr, code-server |
| PyPI JSON `digests.sha256` | poetry |
| nix fixed-output hash (`nix eval …src.outputHash`) | google-cloud-sdk, ngrok |
| `coder-packages/pkgs/roborev.nix` | roborev (both arches match) |
| Upstream release notes (SHA1) | supercronic (both arches match) |

## 2. URLs rejected while sourcing the table

None of these is dead. All four returned 200, but the bytes were wrong for the
purpose, so the manifest uses the replacement.

| URL | HTTP | Problem | Replacement used |
| --- | --- | --- | --- |
| `https://bin.ngrok.com/a/58nxNCjvFS5/ngrok-v3-3.39.9-linux-amd64.tgz` | 200 | Not a tarball. It serves the bare ELF binary, so the first real install failed with `gzip: stdin: not in gzip format`. | `https://bin.ngrok.com/a/58nxNCjvFS5/ngrok-v3-3.39.9-linux-amd64` (the URL nixpkgs uses; same sha256 `d26c3fa5…`) |
| `https://bin.ngrok.com/a/7VJKVAoYV2h/ngrok-v3-3.39.9-linux-arm64.tgz` | 200 | Same as above (arm64) | `…/ngrok-v3-3.39.9-linux-arm64` (sha256 `144a59a7…` = nix's) |
| `https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-570.0.0-linux-x86_64.tar.gz` | 200 | Google's current file name, but a **different byte stream** (`479d16af…`) from the archive nixpkgs pins (`b35c621a…`). Same size, different hash. | `…/google-cloud-sdk-570.0.0-linux-x86_64.tar.gz` (sha256 equals nix's fixed-output hash) |
| `https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-570.0.0-linux-arm.tar.gz` | 200 | Same as above (`7f8b57b5…` vs nix's `ca0d6d78…`) | `…/google-cloud-sdk-570.0.0-linux-arm.tar.gz` |

One transient error came from the GitHub REST API (`HTTP 504`) while listing
`astral-sh/python-build-standalone` releases. It worked on retry and is not a
URL in the table.

## 3. URLs the brief expected to be dead: all alive

The brief listed these as dead. On 2026-11-25 none of them is.

| URL | Referenced in | Result |
| --- | --- | --- |
| `https://search.nixos.org/packages` | `coder-nix-devenv/README.md` | **200** |
| `https://roborev.io` | `coder-packages/pkgs/roborev.nix` (`meta.homepage`) | **200** after a redirect to `https://www.roborev.io/` |
| `https://github.com/kenn-io/roborev/releases` | `coder-packages/pkgs/roborev.nix` (`meta.downloadPage`) | **200** |
| `https://github.com/kenn-io/roborev/releases/download/v${version}/…` | `coder-packages/pkgs/roborev.nix` (`src.url`) | **200** for v0.64.0 amd64 + arm64. Hashes match the `.nix` file and upstream `SHA256SUMS`. |
| `https://github.com/haroun-mj-ai/coder-nix-devenv` | `coder-packages/README.md` | **200** (public repo) |
| `https://github.com/haroun-mj-ai/coder-nix-devenv.git` | `coder-nix-devenv/README.md` | **200**. `git ls-remote … HEAD` returns `623b9f3`. |
| `https://github.com/haroun-mj-ai/coder-packages` | flake ref `github:haroun-mj-ai/coder-packages` in `coder-packages/README.md` | **404 anonymously** because the repo is **private** (`gh api` sees it with `private=true`). It is not dead, but an unauthenticated fetch (a fresh image build, for example) gets 404. |

These were in the same pre-scoped list. They are not dead, but one result needs
explaining:

| URL | Referenced in | Result |
| --- | --- | --- |
| `https://gw.lunaroute.com/v1` | `coder-packages/dotfiles/omp/models.yml` | 404 on the bare base path. `…/v1/models` returns **401**, so the API is alive and needs auth. Not dead. |
| `http://localhost:5177`, `http://localhost:8010/api/v1` | `coder-packages/scripts/journeyai-e2e/*` | Local dev servers, out of scope |

## 4. Full sweep of both repos: 17 confirmed dead

Method: extract every `http(s)://` URL from `git ls-files` in both repos. Drop
local or private hosts (localhost, 127/10/100/192.168, `.test`, `.local`,
example.com) and templated strings (`${…}`, `%s`, `*`). That leaves **2,926
unique URLs** (2 in this repo, 2,924 in `coder-packages`). The first pass ran
HEAD, falling back to a ranged GET. 2,765 returned 2xx and 161 were re-checked
one at a time with a full GET and a 40 s timeout.

### Confirmed dead

| HTTP | URL | File (in `coder-packages`) |
| --- | --- | --- |
| DNS fail | `https://www.starlette.io/` | `claude/workflows/helpers/vendors.yml` (Starlette docs moved to `https://starlette.dev/`, 200) |
| DNS fail | `https://www.starlette.io/release-notes/` | `claude/workflows/helpers/vendors.yml` (same move) |
| 404 | `https://github.com/ngneat/spectator` | `claude/skills/ui-ux-pro-max/data/stacks/angular.csv` (`gh api` also 404) |
| 404 | `https://developer.android.com/jetpack/compose/layout/intrinsics` | `…/data/stacks/jetpack-compose.csv` |
| 404 | `https://developer.android.com/jetpack/compose/tooling/preview` | `…/data/stacks/jetpack-compose.csv` |
| 404 | `https://developer.apple.com/documentation/swiftui/view/body-swift.property` | `…/data/stacks/swiftui.csv` |
| 404 | `https://developer.apple.com/documentation/swiftui/view/task(priority:_:)` | `…/data/stacks/swiftui.csv` |
| 404 | `https://mkpaz.github.io/atlantafx/getting-started/` | `…/data/stacks/javafx.csv` |
| 404 | `https://mkpaz.github.io/atlantafx/themes/` | `…/data/stacks/javafx.csv` |
| 404 | `https://mkpaz.github.io/atlantafx/theming/` | `…/data/stacks/javafx.csv` |
| 404 | `https://nuxt.com/docs/4.x/api/composables/on-mounted` | `…/data/stacks/nuxtjs.csv` |
| 404 | `https://nuxt.com/docs/4.x/api/utils/next-tick` | `…/data/stacks/nuxtjs.csv` |
| 404 | `https://openjfx.io/javadoc/26/javafx.graphics/javafx/robot/Robot.html` | `…/data/stacks/javafx.csv` |
| 404 | `https://s2.spectrum.adobe.com/index.html` | `…/data/data-provenance.json` |
| 404 | `https://svelte.dev/docs/svelte/legacy-compiler-options` | `…/data/stacks/svelte.csv` |
| 404 | `https://threejs.org/manual/en/color-management.html` | `…/data/stacks/threejs.csv` |
| 404 | `https://threejs.org/manual/en/installation.html` | `…/data/stacks/threejs.csv` |

### Failed the sweep, but not dead

| Count | What | Why it is not dead |
| ---: | --- | --- |
| 124 | `learn.microsoft.com/…` (uno/uwp/winui/wpf CSVs) | 429 rate limit under parallel load. Spot checks one at a time return 301 then 200. |
| 2 | `www.npmjs.com/package/gsap`, `…/three/v/0.185.1` | 403 from the npm bot wall; the pages exist in a browser |
| 1 | `journeyai-backend-staging.up.railway.app/api/v1/auth/login` | 405: a POST-only endpoint answering a GET |
| 1 | `https://api.inaccord.com` | 404 on the bare API base; `www.inaccord.com` is 200. An API base with no GET route at `/` is not evidence of death. |
| 7 | `fonts.googleapis.com/css2?family=…:ital` | Extraction artifact: the real URL continues `ital,wght@…`, and the full URL returns 200 |
| 3 | `developer.apple.com/…(_` and `gsap.com/…gsap.to(` | Extraction artifact (cut at `)`). Full URLs return 200, except `task(priority:_:)`, listed above as dead. |
| 3 | `schemas.microsoft.com/…`, `http://javafx.com/fxml` | XML namespace identifiers, never meant to be fetched |
| 1 | `https://x.dev/a` | Test fixture in `claude/workflows/helpers/test/research.test.mjs` |
| 1 | `https://dev.azure.com/.extraheader=…` | Fragment of a git config key in `debate-review/scripts/lib/forge.mjs` |

## 5. Binaries executing from `/nix/store` that a nix-free image must replace

Taken from `readlink /proc/*/exe` on the live box. Store hashes are elided.
**None of these was stopped or swapped.** Replacements were installed only into
scratch prefixes.

| Binary (live) | What uses it | Nix-free replacement | Verification status |
| --- | --- | --- | --- |
| `/nix/store/*-herdr-0.9.1/bin/herdr` (2 procs: `herdr server`, `remote-client-bridge`) | Agent/terminal multiplexer | `https://github.com/herdrdev/herdr/releases/download/v0.9.1/herdr-linux-{x86_64,aarch64}` (Apache-2.0). Manifest row `herdr`, layer `runtime`. | **Verified**: sha256 equals the GitHub asset digest; `herdr --version` prints `herdr 0.9.1` (x86_64, scratch prefix). Upstream has v0.9.5; pinned to what runs. |
| `/nix/store/*-code-server-4.115.0/bin/code-server` (via `~/.nix-profile/bin`; not running at audit time) | Browser IDE | `https://github.com/coder/code-server/releases/download/v4.115.0/code-server-4.115.0-linux-{amd64,arm64}.tar.gz` (MIT). Manifest row `code-server`. | **Verified**: sha256 equals the GitHub asset digest; `code-server --version` prints `4.115.0 1c6fb2dc… with Code 1.115.0`. |
| `/nix/store/*-socat-1.8.1.3/bin/socat1` (`socat TCP-LISTEN:3080,bind=100.88.37.32,… TCP:127.0.0.1:3080`) | Tailscale-facing port relay next to the VNC stack | apt `socat` 1.8.1.1 (Ubuntu 26.04). Manifest row `socat`. | **Dry-run only**: the apt candidate exists (`1.8.1.1-1ubuntu0.1`), but it is not installed here, and the brief forbids a real `apt-get install`. |
| `/usr/bin/websockify` (2 procs, noVNC on :6080) | VNC → websocket bridge | Already apt (`websockify 0.13.0+dfsg1-2ubuntu1`, `novnc 1:1.6.0-2`). **Not a nix dependency.** pip alternative: `websockify` on PyPI. | **Verified**: `verify.sh` PASS (dpkg version 0.13.0). |
| `x11vnc` | VNC server | Already apt (`0.9.17-2`). Not nix. | n/a |
| `/nix/store/*-playwright-chromium/chrome-linux64/.chrome-wrapped` (10 procs) | **The shared workspace browser** (CDP port 9223), Chrome for Testing 149.0.7827.55 | Playwright's own CDN build, installed with `npx playwright install chromium` into `~/.cache/ms-playwright`. The coder-packages `browser-mcp` Playwright (1.63.0-alpha) resolves `https://cdn.playwright.dev/builds/cft/153.0.8010.12/linux64/chrome-linux64.zip` (HEAD 200). `~/.cache/ms-playwright/chromium-1208`, `-1237` already exist on this box. | **URL alive, not installed or run.** The version would move 149 → 153. Not in the manifest, because the browser launcher picks the binary. |
| `/nix/store/*-nodejs-slim-22.23.2/bin/node` (8 procs at first sample, ~30 later) | Hindsight MCP server, `mongodb-mcp-server` via `npm exec`, omp-delegate `relay.mjs` | Manifest `nodejs_22` (same 22.23.2) | **Verified** (e2e run below) |
| `/nix/store/*-python3-3.11.15/bin/python3.11` (1 proc) | `~/deepseek-harness/integration/browser/desktop.py` | Manifest `python311` (same 3.11.15) | **Verified**: `Python 3.11.15` |
| `/nix/store/*-tmux-3.7b/bin/tmux` (1 proc: `tmux start-server`, launched via `~/.nix-profile/bin/tmux`) | Persistent tmux server (autopilot / supercronic substrate) | apt `tmux` 3.6a (**Δ** vs 3.7b) | **Dry-run only** (not installed). Running sessions keep the old binary until restarted. |

## Reproduce

```bash
# Manifest artifacts: download, hash, and write back (prints status per URL)
BOOTSTRAP_CACHE=/path/to/cache bootstrap/update-hashes.sh --audit /tmp/audit.tsv

# Live /nix/store executables
for p in /proc/[0-9]*; do readlink "$p/exe"; done 2>/dev/null | grep '^/nix/store' | sort | uniq -c

# Repo sweep (sketch): extract, filter local/templated, then per URL
curl -sS -o /dev/null -I -L --max-time 20 -w '%{http_code}\t%{url_effective}\n' "$url"
```
