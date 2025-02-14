{
  description = "Finds issues in comments and text files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    zig = {
      url = "github:ziglang/zig";
      flake = false;
    };
    zon2nix = {
      url = "github:MidstallSoftware/zon2nix";
      flake = false;
    };
  };

  outputs = {
    self,
    flake-parts,
    systems,
    zig,
    zon2nix,
    ...
  }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      flake.overlays.default = final: prev: {
        zig_0_14 = (prev.zig_0_13.override {
          llvmPackages = final.llvmPackages_19;
        }).overrideAttrs (f: p: {
          version = "0.14.0-git+${zig.shortRev or "dirty"}";
          src = zig;

          postBuild = ''
            stage3/bin/zig build langref --zig-lib-dir $(pwd)/stage3/lib/zig
          '';
        });

        zon2nix = (prev.zon2nix.override {
          zig_0_11 = final.zig_0_14;
        }).overrideAttrs (f: p: {
          version = "${p.version}-git+${zon2nix.shortRev or "dirty"}";
          src = zon2nix;
        });

        mondai = (final.callPackage ./nix/package.nix {
          zig = final.zig_0_14;
        }).overrideAttrs (f: p: {
          version = "${p.version}-git+${self.shortRev or "dirty"}";
          src = final.lib.cleanSource self;
        });
      };

      perSystem = { config, pkgs, system, ... }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            self.overlays.default
          ];
          config = {};
        };

        legacyPackages = pkgs;

        packages.default = pkgs.mondai;

        devShells.default = pkgs.mkShell {
          inherit (pkgs.mondai) name pname version;

          inputsFrom = [ pkgs.mondai ];

          packages = [
            pkgs.zon2nix
          ];
        };
      };
    };
}
