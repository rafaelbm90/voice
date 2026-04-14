# LOCAL TEST CASK — points at dist/Voice-*.dmg on this machine.
# Do NOT publish. Used only to validate Cask install flow before tagging a release.
# Install: brew install --cask /absolute/path/to/this/file

cask "voice-local" do
  version "0.1.0"
  sha256 :no_check

  url "file:///Users/rafaelbm/Dev/AI/Voice/dist/Voice-#{version}.dmg"
  name "Voice"
  desc "Local-first dictation menu-bar app (LOCAL TEST)"
  homepage "https://github.com/rafaelbm/Voice"

  depends_on formula: "whisper-cpp"
  depends_on formula: "llama.cpp"
  depends_on macos: ">= :sonoma"

  app "Voice.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Voice.app"],
                   sudo: false
  end

  uninstall quit: "dev.rafaelbm.voice"

  zap trash: [
    "~/Library/Preferences/dev.rafaelbm.voice.plist",
    "~/Library/Application Support/Voice",
  ]
end
