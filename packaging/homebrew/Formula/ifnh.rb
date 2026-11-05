# Template for the Abide-Integrations/homebrew-ifnh tap (ACTIVE_PLAN F-05).
# The @...@ tokens are filled by scripts/bump-homebrew.sh from the published
# release .sha256 files; do not hand-edit hashes here.
class Ifnh < Formula
  desc "Lightweight agentic coding harness"
  homepage "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download/v#{version}/ifnh-#{version}-macos-aarch64.tar.gz"
      sha256 "@SHA_MACOS_AARCH64@"
    end
    on_intel do
      url "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download/v#{version}/ifnh-#{version}-macos-x86_64.tar.gz"
      sha256 "@SHA_MACOS_X86_64@"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download/v#{version}/ifnh-#{version}-linux-aarch64-musl.tar.gz"
      sha256 "@SHA_LINUX_AARCH64@"
    end
    on_intel do
      url "https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download/v#{version}/ifnh-#{version}-linux-x86_64-musl.tar.gz"
      sha256 "@SHA_LINUX_X86_64@"
    end
  end

  def install
    bin.install "ifnh"
    man1.install "share/man/man1/ifnh.1"
    bash_completion.install "share/bash-completion/completions/ifnh"
    zsh_completion.install "share/zsh/site-functions/_ifnh"
    fish_completion.install "share/fish/vendor_completions.d/ifnh.fish"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ifnh version")
  end
end
