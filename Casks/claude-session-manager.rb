cask "claude-session-manager" do
  version "1.0.0"
  sha256 "2b6322df4360ebd9127c816a738c5d4965015213d7ff243400ee486afd76f7db"

  url "https://github.com/jeromeliu-tomtom/ClaudeSessionManager/releases/download/v#{version}/ClaudeSessionManager-v#{version}.zip",
      verified: "github.com/jeromeliu-tomtom/ClaudeSessionManager/"
  name "Claude Session Manager"
  desc "Browse and manage local Claude Code sessions"
  homepage "https://github.com/jeromeliu-tomtom/ClaudeSessionManager"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "ClaudeSessionManager.app"

  zap trash: [
    "~/Library/Application Support/ClaudeSessionManager",
    "~/Library/Preferences/com.jerome.claudesessionmanager.plist",
    "~/Library/Saved Application State/com.jerome.claudesessionmanager.savedState",
  ]
end
