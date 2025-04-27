{
  description = "PowerShell environment for publishing posts";

  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = {
    self,
    nixpkgs-unstable,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-darwin"
    ];

    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

    pkgsFor = system: import nixpkgs {inherit system;};
    pkgsUnstableFor = system: import nixpkgs-unstable {inherit system;};
  in {
    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);
    devShell = forAllSystems (
      system: let
        pkgs = pkgsFor system;
        pkgs-unstable = pkgsUnstableFor system;
      in
        pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.powershell
          ];

          shellHook = ''
            exec pwsh -NoLogo
          '';
        }
    );
  };
}
