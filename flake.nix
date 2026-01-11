{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.zig = {
    url = "github:mitchellh/zig-overlay";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      zig,
      ...
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      syspkgs = forAllSystems (system: nixpkgs.legacyPackages.${system});
    in
    {
      formatter = forAllSystems (system: syspkgs.${system}.nixfmt-tree);
      devShell = forAllSystems (
        system:
        let
          pkgs = syspkgs.${system};
        in
        pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            picocom
            renode
            zls
            gcc-arm-embedded
            zig.outputs.packages.${system}.default
          ];
        }
      );
    };
}
