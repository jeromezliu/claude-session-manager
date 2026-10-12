cask "claude-session-manager" do
  version "1.5.0"
  sha256 "8f3d5e4a439d5babfb22a4bfc0c5e74039130386b8b13cd2d9f78b99693bc018"

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
