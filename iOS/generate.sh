#!/bin/bash
# Generate iOS/ClaudeSessions.xcodeproj from project.yml (the project file
# itself isn't committed).
#
# Signing team for device builds: CSM_TEAM_ID, else the team of the first
# "Apple Development" certificate in the login keychain. Simulator builds
# work without one.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }

if [[ -z "${CSM_TEAM_ID:-}" ]]; then
    CSM_TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
export CSM_TEAM_ID
[[ -n "$CSM_TEAM_ID" ]] && echo "Signing team: $CSM_TEAM_ID" || echo "No signing team found (simulator builds only)"
xcodegen generate --spec project.yml
