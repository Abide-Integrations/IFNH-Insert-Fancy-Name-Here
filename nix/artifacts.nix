# PLACEHOLDER hashes (all zero): run scripts/bump-nix.sh against a real release before 'nix build'.
{
  version = "0.1.7";
  platforms = {
    x86_64-linux = { suffix = "linux-x86_64-musl"; sha256 = "0000000000000000000000000000000000000000000000000000000000000000"; };
    aarch64-linux = { suffix = "linux-aarch64-musl"; sha256 = "0000000000000000000000000000000000000000000000000000000000000000"; };
    x86_64-darwin = { suffix = "macos-x86_64"; sha256 = "0000000000000000000000000000000000000000000000000000000000000000"; };
    aarch64-darwin = { suffix = "macos-aarch64"; sha256 = "0000000000000000000000000000000000000000000000000000000000000000"; };
  };
}
