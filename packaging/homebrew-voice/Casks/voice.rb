# Homebrew Cask template for Voice.
# Copy this file to a separate tap repo: `rafaelbm/homebrew-voice`
# so users can install via `brew tap rafaelbm/voice && brew install --cask voice`.
#
# Update `version` and `sha256` on every release.
# Since the app is ad-hoc signed (not notarized), `brew install --cask` strips
# the quarantine xattr on install, so users do NOT see a Gatekeeper warning.

cask "voice" do
  version "0.1.0"
  sha256 :no_check # replace with real sha after first release: shasum -a 256 Voice-x.y.z.dmg

  url "https://github.com/rafaelbm/Voice/releases/download/v#{version}/Voice-#{version}.dmg"
  name "Voice"
  desc "Local-first dictation menu-bar app (whisper.cpp + llama.cpp)"
  homepage "https://github.com/rafaelbm/Voice"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"
  depends_on formula: "whisper-cpp"
  depends_on formula: "llama.cpp"

  app "Voice.app"

  # Voice is ad-hoc signed (no Apple Developer ID). Stripping the quarantine xattr
  # prevents Gatekeeper's AppTranslocation from launching the app from a read-only
  # randomized path, which would break future Sparkle auto-updates and app-relative
  # file access. Safe because the user is explicitly opting into this tap.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Voice.app"],
                   sudo: false
  end

  uninstall quit: "dev.rafaelbm.voice"

  zap trash: [
    "~/Library/Preferences/dev.rafaelbm.voice.plist",
    "~/Library/Application Support/Voice",
    "~/Library/Caches/dev.rafaelbm.voice",
    "~/Library/Saved Application State/dev.rafaelbm.voice.savedState",
  ]

  caveats <<~EOS
    Voice requires Microphone and Accessibility permissions on first run.
    Grant both in System Settings → Privacy & Security.

    whisper.cpp and llama.cpp binaries are installed via Homebrew and
    auto-discovered. Pick a Whisper model from the app's Settings pane.
  EOS
end
