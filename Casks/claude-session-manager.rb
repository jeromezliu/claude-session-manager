cask "claude-session-manager" do
  version "1.2.1"
  sha256 "6e53cf65c9609c6cacaa95be7518d65e1f59ce3994d79f6a3222a4aad22b46e6"

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
