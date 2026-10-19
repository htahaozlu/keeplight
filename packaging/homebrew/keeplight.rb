# Template for Casks/keeplight.rb in the tap github.com/htahaozlu/homebrew-keeplight
# (`brew install --cask htahaozlu/keeplight/keeplight`). scripts/release.sh writes dist/keeplight.rb
# from this file with __VERSION__ and __SHA256__ filled in for the DMG it just built, notarized and
# checked; copy that file into the tap, not this one.
cask "keeplight" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/htahaozlu/keeplight/releases/download/v#{version}/Keeplight.dmg"
  name "Keeplight"
  desc "Brightness and resolution for every display, menu bar app and CLI"
  homepage "https://github.com/htahaozlu/keeplight"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "Keeplight.app"
  binary "#{appdir}/Keeplight.app/Contents/Helpers/keeplight"

  uninstall quit: "io.github.htahaozlu.Keeplight"

  zap trash: [
    "~/Library/Application Support/Keeplight",
    "~/Library/Preferences/io.github.htahaozlu.Keeplight.plist",
  ]
end
