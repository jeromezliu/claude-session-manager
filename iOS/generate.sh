#!/bin/bash
# Generate iOS/ClaudeSessions.xcodeproj from project.yml (the project file
# itself isn't committed).
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
xcodegen generate --spec project.yml
