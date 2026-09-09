#!/usr/bin/env bash
# Create a local session file template. Edit it on your Mac — never paste cookies into chat.
set -euo pipefail
DIR="${HOME}/.config/grokbot-usage"
FILE="${DIR}/session"
mkdir -p "${DIR}"
chmod 700 "${DIR}"
if [[ -f "${FILE}" ]]; then
  echo "Already exists: ${FILE}"
  exit 0
fi
cat > "${FILE}" <<'EOT'
# Replace this entire file with your WorkosCursorSessionToken value
# (bare token or WorkosCursorSessionToken=...).
EOT
chmod 600 "${FILE}"
echo "Created ${FILE}"
echo "Edit it locally with your Cursor session cookie, then relaunch GrokBotUsage."
