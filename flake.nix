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
          # Required for terraform (BUSL 1.1). Every other package here is free.
          config.allowUnfree = true;
        };

        # The toolchain. Keep this list as the single source of truth —
        # scripts/export-packages.sh regenerates the README table from it.
        toolchain = with pkgs; [
          # Languages & package managers
          nodejs_24
          python311
          poetry

          # Cloud, infra & secrets
          google-cloud-sdk
          terraform
          sops

          # Containers
          docker
          docker-compose
          lazydocker

          # Datastores
          mongosh
          redis

          # Platform CLIs & tunneling
          railway
          stripe-cli
          ngrok

          # Core dev tooling
          git
          gh
          ripgrep
        ];
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
      });
}
