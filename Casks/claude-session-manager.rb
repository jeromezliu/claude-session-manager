cask "claude-session-manager" do
  version "1.1.0"
  sha256 "470246cf97338ba2ee48f6e1450bdea49859e52092aa029e0f24f404be24d4fc"

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
