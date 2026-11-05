{
  description = "IFNH, a lightweight agentic coding harness (prebuilt release binaries)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      artifacts = import ./nix/artifacts.nix;
      forSystems = f: nixpkgs.lib.genAttrs (builtins.attrNames artifacts.platforms)
        (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forSystems (system: pkgs:
        let
          inherit (artifacts) version;
          p = artifacts.platforms.${system};
          ifnh = pkgs.stdenvNoCC.mkDerivation {
            pname = "ifnh";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download/v${version}/ifnh-${version}-${p.suffix}.tar.gz";
              inherit (p) sha256;
            };
            sourceRoot = "ifnh-${version}-${p.suffix}";
            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;
            installPhase = ''
              install -Dm755 ifnh $out/bin/ifnh
              install -Dm644 share/man/man1/ifnh.1 $out/share/man/man1/ifnh.1
              install -Dm644 share/bash-completion/completions/ifnh $out/share/bash-completion/completions/ifnh
              install -Dm644 share/zsh/site-functions/_ifnh $out/share/zsh/site-functions/_ifnh
              install -Dm644 share/fish/vendor_completions.d/ifnh.fish $out/share/fish/vendor_completions.d/ifnh.fish
            '';
            meta = {
              description = "Lightweight agentic coding harness";
              homepage = "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here";
              license = pkgs.lib.licenses.mit;
              mainProgram = "ifnh";
              platforms = [ system ];
              sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
            };
          };
        in
        { inherit ifnh; default = ifnh; });
    };
}
