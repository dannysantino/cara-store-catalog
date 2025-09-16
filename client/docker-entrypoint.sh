#!/bin/sh
set -e

# Write env vars into a JS file for the frontend
cat <<EOF > /usr/share/nginx/html/env.js
window._env_ = {
  VITE_API_URL: "${VITE_API_URL}"
};
EOF

echo "[INFO] Injected runtime config into /usr/share/nginx/html/env.js"

# Run whatever was passed (nginx by default)
exec "$@"