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
      path = builtins.concatStringsSep ":" (builtins.map (p: p + "/bin") (with pkgs; [gcc_multi rust-bin-custom coreutils]));

      siap-deps = derivation {
        inherit system;
        name = "${siap-cargo-toml.package.name}-${hashes-toml.cargo_lock}-deps";
        builder = "${pkgs-unstable.bun}/bin/bun";
        PATH = path;
        args = [ "run" ./scripts/vendor-cargo.js "--source" ./. ];

        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = hashes-toml.deps;
      };

      siap-bin = derivation {
          inherit system;
          name = "${siap-cargo-toml.package.name}-v${siap-cargo-toml.package.version}";
          builder = "${pkgs-unstable.bun}/bin/bun";
          PATH = path;
          args = [ "run" ./scripts/build-cargo.js "--source" ./. "--dependencies" siap-deps "--package" "static-ip-authentication-proxy" hashes-toml.cargo_config ];
      };
    in {
      packages.${system} = {
        deps = siap-deps;
        bin = siap-bin;
        default = siap-bin;
      };

      nixosModules.${system}.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.hochreiner.services.static-ip-authentication-proxy;
    
          ipMapping = {
            options = {
              user = mkOption {
                type = types.str;
                description = lib.mdDoc "Username to assign to the IP address";
              };
              roles = mkOption {
                type = types.listOf types.str;
                description = lib.mdDoc "Roles to assign to the user";
              };
            };
          };

          configuration_file = pkgs.writeTextFile {
            name = "static-ip-auth-proxy-configuration.json";
            text = (builtins.toJSON cfg.configuration);
          };
        in {
          # https://britter.dev/blog/2025/01/09/nixos-modules/
          options.hochreiner.services.static-ip-authentication-proxy = {
            enable = mkEnableOption "Enables the static ip authentication proxy service";

            configuration = mkOption {
              type = types.submodule {
                options = {
                  ip_mapping = mkOption {
                    type = types.attrsOf (types.submodule ipMapping);
                  };
                  user_header = mkOption {
                    type = types.str;
                    default = "X-Auth-Username";
                    description = lib.mdDoc "HTTP header to set the authenticated user in";
                  };
                  roles_header = mkOption {
                    type = types.str;
                    default = "X-Auth-Roles";
                    description = lib.mdDoc "HTTP header to set the authenticated user's roles in (comma-separated list)";
                  };
                  token_header = mkOption {
                    type = types.str;
                    default = "X-Auth-Token";
                    description = lib.mdDoc "HTTP header to set the authenticated user's token in (SHA256 HMAC of username and secret key)";
                  };
                  secret_file = mkOption {
                    type = types.path;
                    description = lib.mdDoc "Path to the secret key file used for HMAC token generation";
                  };
                };
              };
              default = { ip_mapping = {}; };
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
            systemd.services."hochreiner.static-ip-authentication-proxy" = {
              wantedBy = [ "multi-user.target" ];
              description = "static ip authentication proxy service";
              serviceConfig = let
                pkg = self.packages.${system}.default;
              in {
                Type = "simple";
                ExecStart = "${pkg}/bin/static-ip-authentication-proxy";
                Environment = "RUST_LOG=${cfg.log_level} ROCKET_ADDRESS='${cfg.address}' ROCKET_PORT=${builtins.toString cfg.port} CONFIG_PATH='${configuration_file}' PATH=/run/current-system/sw/bin";
              };
            };
          };
        };

      devShells.${system}.default = pkgs.mkShell {
        name = "siap";

        shellHook = ''
          # exec nu
        '';
        buildInputs = with pkgs; [
          rust-bin-custom
          pkgs-unstable.bun
        ];
      };

      # NixOS configuration for testing
      # https://xeiaso.net/blog/nix-flakes-3-2022-04-07/
      nixosConfigurations = {
        siap-test = nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            self.nixosModules.${system}.default
            ({pkgs, ...}: let 
              key_file = pkgs.writeTextFile {
                name = "key";
                text = "the_secret";
              };
            in {
              # Only allow this to boot as a container
              boot.isContainer = true;
              networking.hostName = "siap-test";

              # Allow nginx through the firewall
              networking.firewall.allowedTCPPorts = [ 80 ];

              # services.nginx.enable = true;
              hochreiner.services.static-ip-authentication-proxy = {
                enable = true;
                configuration = {
                  ip_mapping = {
                    "192.168.0.1" = {
                      user = "alice";
                      roles = [ "admin" "user" ];
                    };
                    "192.168.0.2" = {
                      user = "bob";
                      roles = [ "user" ];
                    };
                    "192.168.0.3" = {
                      user = "foo";
                      roles = [ "viewer" "user" ];
                    };
                  };
                  user_header = "X-Auth-CouchDB-Username";
                  roles_header = "X-Auth-CouchDB-Roles";
                  token_header = "X-Auth-CouchDB-Token";
                  secret_file = "${key_file}";
                };
                log_level = "debug";
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