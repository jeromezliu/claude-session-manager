cask "claude-session-manager" do
  version "1.4.0"
  sha256 "30c764f44f3f355d1f189836903c74b40463fac5bbd23689e46ce36df2f62ff6"

  url "https://github.com/jeromezliu/claude-session-manager/releases/download/v#{version}/ClaudeSessionManager-v#{version}.zip"
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
