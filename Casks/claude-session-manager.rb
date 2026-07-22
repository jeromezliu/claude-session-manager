cask "claude-session-manager" do
  version "1.2.0"
  sha256 "94f43f11898bccad081924ffa0e7b70c2c9e12d1ad80bbe2c5e735f893371b9e"

  url "https://github.com/jeromezliu/claude-session-manager/releases/download/v#{version}/ClaudeSessionManager-v#{version}.zip",
      verified: "github.com/jeromezliu/claude-session-manager/"
  name "Claude Session Manager"
  desc "Browse and manage local Claude Code sessions"
  homepage "https://github.com/jeromezliu/claude-session-manager"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "ClaudeSessionManager.app"

  zap trash: [
    "~/Library/Application Support/ClaudeSessionManager",
    "~/Library/Preferences/com.jerome.claudesessionmanager.plist",
    "~/Library/Saved Application State/com.jerome.claudesessionmanager.savedState",
  ]
end
