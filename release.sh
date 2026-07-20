#!/bin/bash
#
# Cut a new release end-to-end:
#   1. build + zip the .app
#   2. bump the Homebrew cask (version + sha256)
#   3. push the app repo and publish a GitHub release with the zip
#   4. update the Homebrew tap
#
# Usage:  ./release.sh <version>          e.g.  ./release.sh 1.1.0
#
# Config via env (defaults suit this project):
#   PUBLIC_REPO, PUBLIC_REMOTE, TAP_REPO, TAP_DIR, RELEASE_ACCT
#   SYNC_PRIVATE_REMOTE  — if set (e.g. "origin"), also push there
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   (e.g. ./release.sh 1.1.0)}"
TAG="v${VERSION}"

PUBLIC_REPO="${PUBLIC_REPO:-jeromezliu/claude-session-manager}"
PUBLIC_REMOTE="${PUBLIC_REMOTE:-public}"
TAP_REPO="${TAP_REPO:-jeromezliu/homebrew-tap}"
TAP_DIR="${TAP_DIR:-$HOME/Workspace/homebrew-tap}"
RELEASE_ACCT="${RELEASE_ACCT:-jeromezliu}"
CASK="Casks/claude-session-manager.rb"
APP="ClaudeSessionManager"
ZIP="build/${APP}-${TAG}.zip"

# Use the account that owns the public repo + tap; restore the previous one after.
PREV_ACCT="$(gh api user -q .login 2>/dev/null || true)"
restore_acct() { [[ -n "$PREV_ACCT" ]] && gh auth switch --user "$PREV_ACCT" >/dev/null 2>&1 || true; }
trap restore_acct EXIT
gh auth switch --user "$RELEASE_ACCT" >/dev/null 2>&1 || true

echo "▶ Building ${TAG}…"
./build.sh >/dev/null
( cd build && rm -f "${APP}-${TAG}.zip" \
  && ditto -c -k --sequesterRsrc --keepParent "${APP}.app" "${APP}-${TAG}.zip" )
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "  packaged ${ZIP}"
echo "  sha256   ${SHA}"

echo "▶ Bumping cask → ${VERSION}"
sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$CASK"
sed -i '' -E "s/^  sha256 \"[0-9a-f]*\"/  sha256 \"${SHA}\"/" "$CASK"
git add "$CASK"
git commit -m "Release ${TAG}" >/dev/null 2>&1 || echo "  (cask already current)"
git push "$PUBLIC_REMOTE" HEAD:main

echo "▶ Publishing GitHub release on ${PUBLIC_REPO}"
NOTES="$(cat <<'EOF'
### Install
```sh
brew tap jeromezliu/tap
brew install --cask claude-session-manager
```
Or download the zip below and unzip (right-click → Open on first launch; macOS 13+).
EOF
)"
gh release create "$TAG" --repo "$PUBLIC_REPO" --target main \
  --title "${TAG} — Claude Session Manager" --notes "$NOTES" "$ZIP"

echo "▶ Updating tap ${TAP_REPO}"
mkdir -p "${TAP_DIR}/Casks"
cp "$CASK" "${TAP_DIR}/Casks/"
git -C "$TAP_DIR" add -A
if ! git -C "$TAP_DIR" diff --cached --quiet; then
  git -C "$TAP_DIR" -c user.email="jeromezliu@users.noreply.github.com" -c user.name="jeromezliu" \
      commit -m "claude-session-manager ${VERSION}"
  git -C "$TAP_DIR" push origin HEAD:main
else
  echo "  (tap already current)"
fi

if [[ -n "${SYNC_PRIVATE_REMOTE:-}" ]]; then
  echo "▶ Syncing to ${SYNC_PRIVATE_REMOTE}"
  restore_acct
  git push "$SYNC_PRIVATE_REMOTE" HEAD:main || echo "  (private sync failed)"
fi

echo "✓ Released ${TAG}"
echo "  users update with:  brew update && brew upgrade --cask claude-session-manager"
