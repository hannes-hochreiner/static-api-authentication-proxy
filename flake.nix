{
  description = "Nix flake for a static IP authentication proxy service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, rust-overlay, ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };

      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
      };

      rust-bin-custom = pkgs.rust-bin.stable.latest.default.override {
        extensions = [ "rust-src" "rust-analyzer" ];
        targets = [ "x86_64-unknown-linux-gnu" ];
      };

      siap-cargo-toml = (builtins.fromTOML (builtins.readFile ./Cargo.toml));
      hashes-toml = (builtins.fromTOML (builtins.readFile ./hashes.toml));

      siap-deps = derivation {
        inherit system;
        name = "${siap-cargo-toml.package.name}-${hashes-toml.cargo_lock}-deps";
        builder = "${pkgs-unstable.bun}/bin/bun";
        buildInputs = with pkgs; [
          rust-bin-custom
          bash
          coreutils
        ];
        args = [ "run" ./scripts/vendor-cargo.js "--source" ./. ];

        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = hashes-toml.deps;
        # outputHash = pkgs.lib.fakeHash;
      };

      siap-bin = derivation {
          inherit system;
          name = "${siap-cargo-toml.package.name}-v${siap-cargo-toml.package.version}";
          builder = "${pkgs-unstable.bun}/bin/bun";
          buildInputs = with pkgs; [
            gcc_multi
            rust-bin-custom
            coreutils
          ];
          args = [ "run" ./scripts/build-cargo.js "--source" ./. "--dependencies" siap-deps "--package" "static-ip-authentication-proxy" hashes-toml.cargo_config ];
      };
    in {
      packages.${system} = {
        # deps = siap-deps;
        bin = siap-bin;
        default = siap-bin;
      };

      nixosModules.${system}.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.hochreiner.services.snapshot-browser-api;
    
          snapshotRoot = {
            options = {
              path = mkOption {
                type = types.path;
                description = lib.mdDoc "Path to the snapshot root directory";
              };
              suffix = mkOption {
                type = types.str;
                default = "";
                description = lib.mdDoc "Suffix for the snapshot root (e.g. '-snapshots')";
              };
            };
          };

          snapshotRoots = mkOption {
              type = types.attrsOf snapshotRoot;
              default = {};
          };

          configuration_file = pkgs.writeTextFile {
            name = "snapshot-browser-config-api";
            text = (builtins.toJSON cfg.configuration);
          };
        in {
          # https://britter.dev/blog/2025/01/09/nixos-modules/
          options.hochreiner.services.snapshot-browser-api = {
            enable = mkEnableOption "Enables the snapshot-browser service";

            configuration = mkOption {
              type = types.submodule {
                options = {
                  snapshot_roots = mkOption {
                    type = types.attrsOf (types.submodule snapshotRoot);
                  };
                };
              };
              default = { snapshot_roots = {}; };
            };

            log_level = mkOption {
              type = types.enum [ "error" "warn" "info" "debug" "trace" ];
              default = "info";
              description = lib.mdDoc "Log level";
            };

            port = mkOption {
              type = types.port;
              default = 8080;
              description = lib.mdDoc "Port to run the snapshot-browser service on";
            };

            address = mkOption {
              type = types.str;
              default = "0.0.0.0";
              description = lib.mdDoc "Address to bind the snapshot-browser service to";
            };
          };

          config = mkIf cfg.enable {
            systemd.services."hochreiner.snapshot-browser-api" = {
              wantedBy = [ "multi-user.target" ];
              description = "snapshot-browser API service";
              serviceConfig = let
                pkg = self.packages.${system}.default;
              in {
                Type = "simple";
                ExecStart = "${pkg}/bin/snapshot-browser-api";
                Environment = "RUST_LOG=${cfg.log_level} ROCKET_ADDRESS='${cfg.address}' ROCKET_PORT=${builtins.toString cfg.port} SNAPSHOT_CONFIG_PATH='${configuration_file}' PATH=/run/current-system/sw/bin";
              };
            };
          };
        };

      devShells.${system}.default = pkgs.mkShell {
        name = "snapshot-browser-api";

        shellHook = ''
          # exec nu
        '';
        buildInputs = with pkgs; [
          rust-bin-custom
          # busybox
          pkgs-unstable.bun
        ];
      };

      # NixOS configuration for testing
      # https://xeiaso.net/blog/nix-flakes-3-2022-04-07/
      nixosConfigurations = {
        sb-api-test = nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            self.nixosModules.${system}.default
            ({pkgs, ...}: {
              # Only allow this to boot as a container
              boot.isContainer = true;
              networking.hostName = "sb-api-test";

              # Allow nginx through the firewall
              networking.firewall.allowedTCPPorts = [ 80 ];

              # services.nginx.enable = true;
              hochreiner.services.snapshot-browser-api = {
                enable = true;
                configuration.snapshot_roots = {
                  "root1" = {
                    path = "/some/path/1/";
                    suffix = "_suffix_1";
                  };
                  "root2" = {
                    path = "/some/path/2/";
                    suffix = "_suffix_2";
                  };
                };
                address = "10.233.1.2";
                port = 80;
              };

              system.stateVersion = "25.05";
            })
          ];
        };
      };
    };
  
  # Testing
  # https://www.tweag.io/blog/2020-07-31-nixos-flakes/
  # https://github.com/erikarvstedt/extra-container/blob/master/examples/flake/usage.sh
  # https://nixos.wiki/wiki/NixOS_Containers
  # https://nixos.org/manual/nixos/stable/#ch-containers
  # https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html
  # https://github.com/tfc/nixos-integration-test-example/blob/main/flake.nix
  # https://nixcademy.com/posts/nixos-integration-test-on-github/

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://hannes-hochreiner.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "hannes-hochreiner.cachix.org-1:+ljzSuDIM6I+FbA0mdBTSGHcKOcEZSECEtYIEcDA4Hg="
    ];
  };
}