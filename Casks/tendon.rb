cask "tendon" do
  version "0.0.2"
  sha256 "10f5f134c3342a45d0bbea6b5d842bbb74bb621478610a21402106655ed733e6"

  url "https://github.com/inabajunmr/tako/releases/download/v#{version}/Tendon-#{version}-macos-arm64.zip"
  name "Tendon"
  desc "Small macOS launcher"
  homepage "https://github.com/inabajunmr/tako"

  depends_on arch: :arm64

  app "Tendon.app"

  uninstall quit: "com.juninaba.Tendon"

  zap trash: [
    "~/Library/Application Support/Tendon",
    "~/Library/Preferences/com.juninaba.Tendon.plist",
  ]
end
