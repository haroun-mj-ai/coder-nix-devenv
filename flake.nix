{
  description = "Coder workspace dev environment — reproducible toolchain via Nix flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # Required for terraform (BUSL 1.1) and ngrok. Everything else here is
          # free-licensed; see the License column in the README table.
          config.allowUnfree = true;
        };

        # THE source of truth for the toolchain.
        #
        # Keyed by nixpkgs attribute name so the README table can show the exact
        # name you would pass to `nix profile add` — `nodejs_22`, not `nodejs`.
        # Add a package here and nowhere else, then run
        # ./scripts/export-packages.sh to refresh the README.
        toolchainAttrs = {
          # Languages & package managers.
          #
          # nodejs_22 is deliberate: it matches the frontend's production
          # Dockerfile and what CI builds against. Do not bump it just to keep
          # pace with nixpkgs — pin an older nixpkgs revision if you need an
          # older Node, and change this only when production moves.
          inherit (pkgs) nodejs_22 python311 poetry;

          # Cloud, infra & secrets
          inherit (pkgs) google-cloud-sdk terraform sops coder;

          # Containers
          #
          # docker and docker-compose are intentionally absent. The workspace
          # image installs them via pacman so the `docker compose` plugin lands
          # on the path `docker` already searches, and .nix-profile/bin comes
          # first on PATH — a Nix docker would shadow pacman's and break the
          # plugin. lazydocker has no such constraint.
          inherit (pkgs) lazydocker;

          # Datastores
          inherit (pkgs) mongosh redis;

          # Platform CLIs & tunneling
          inherit (pkgs) railway stripe-cli ngrok;

          # Core dev tooling
          inherit (pkgs) git gh ripgrep;
        };

        toolchain = builtins.attrValues toolchainAttrs;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = toolchain;

          shellHook = ''
            echo "dev environment ready"
            echo "  node    $(node --version)"
            echo "  python  $(python3 --version 2>&1 | cut -d' ' -f2)"
            echo "  tf      $(terraform version | head -1 | cut -d'v' -f2)"
          '';
        };

        # Installs the whole toolchain into the user's nix profile:
        #   nix profile add github:haroun-mj-ai/coder-nix-devenv
        packages.default = pkgs.buildEnv {
          name = "coder-devenv";
          paths = toolchain;
        };

        # Expose nixpkgs-with-unfree so callers can pull any single package,
        # unfree included, without needing --impure:
        #   nix shell github:haroun-mj-ai/coder-nix-devenv#terraform
        legacyPackages = pkgs;

        # Machine-readable inventory, consumed by scripts/export-packages.sh to
        # regenerate the README table. Derived from toolchainAttrs so the table
        # and the actual toolchain can never drift.
        toolchainInfo = nixpkgs.lib.mapAttrsToList
          (attr: p: {
            name = attr;
            version = p.version or "";
            unfree = !(p.meta.license.free or true);
          })
          toolchainAttrs;
      });
}
