#!/usr/bin/env bash
# Advanced fallback: create a local Bearer token file.
# Prefer: grok login  (writes ~/.grok/auth.json)
# Never paste tokens into chat.
set -euo pipefail
echo "Preferred auth: install Grok CLI and run:  grok login"
echo "That writes ~/.grok/auth.json for this app to read/refresh."
echo
DIR="${HOME}/.config/grokbot-usage"
FILE="${DIR}/session"
mkdir -p "${DIR}"
chmod 700 "${DIR}"
if [[ -f "${FILE}" ]]; then
  echo "Advanced fallback already exists: ${FILE}"
  exit 0
fi
cat > "${FILE}" <<'EOT'
# ADVANCED: replace with a Bearer access token (or bare token).
# Prefer `grok login` instead of this file.
EOT
chmod 600 "${FILE}"
echo "Created ${FILE}"
echo "Edit it locally only if you are not using grok login, then relaunch the app."
