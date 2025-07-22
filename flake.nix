{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
  inputs.zig2nix = {
    url = "github:Cloudef/zig2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    zig2nix,
    ...
  }: let
    supportedSystems = ["x86_64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    syspkgs = forAllSystems (system: nixpkgs.legacyPackages.${system});
  in {
    formatter = forAllSystems (
      system:
        syspkgs.${system}.alejandra
    );
    devShells = forAllSystems (
      system:
        builtins.mapAttrs (
          shell-name: _: let
            env = zig2nix.zig-env.${system} {};
          in
            env.mkShell {
              nativeBuildInputs = with syspkgs.${system}; [zls screen];
            }
        )
        zig2nix.devShells.${system}
    );
  };
}
