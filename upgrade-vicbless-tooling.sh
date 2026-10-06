#!/usr/bin/env bash
# Vicbless: upgrade the build and test tooling to clear the npm audit findings.
# Run from inside frontend/:  bash upgrade-vicbless-tooling.sh
# Changes package.json, package-lock.json (through npm) and vite.config.js.
# The vite.config.js change keeps the site working on older iPhones (iOS 14+), see the comment inside it.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json || [ ! -f vite.config.js ]; then
  echo "Run this from inside the frontend/ folder."
  exit 1
fi

# vitest 5 needs Node 22.12 or newer (22.x from 22.12, 24.x, or 26+). Vite 8 needs 20.19+ or 22.12+.
node_ok() {
  node -e 'const [maj, min] = process.argv[1].split(".").map(Number);
           process.exit((maj === 22 && min >= 12) || maj === 24 || maj >= 26 ? 0 : 1)' "$1"
}

NODE_V="$(node -p 'process.versions.node')"
if ! node_ok "$NODE_V"; then
  echo "Your Node is $NODE_V. This upgrade needs Node 22.12 or newer (or 24+)."
  echo "Update Node first (for example with nvm: nvm install 24), then run this again."
  exit 1
fi

echo "Node $NODE_V is fine. Upgrading vite, @vitejs/plugin-react and vitest..."
npm install -D vite@^8.3.2 @vitejs/plugin-react@^6.1.2 vitest@^5.0.3

cat > vite.config.js <<'VICBLESS_EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    // Keep the browser reach the site had before the Vite 8 upgrade (iOS 14 and up).
    // Vite 8's own default needs Safari 16.4+, which gives older iPhones a blank page.
    target: ['es2020', 'safari14', 'chrome87', 'firefox78', 'edge88'],
  },
  test: { environment: 'node' },
})
VICBLESS_EOF

echo ""
echo "Audit result:"
npm audit || true

echo ""
echo "Running tests..."
npm test

echo ""
echo "Production build..."
npm run build

echo ""
if grep -qE '\|\|=|&&=|\?\?=' dist/assets/*.js; then
  echo "WARNING: the build contains newer JavaScript than iOS 14 understands. Tell Claude."
else
  echo "Compatibility check passed: the build has no syntax newer than iOS 14 understands."
fi

echo ""
echo "Done. Check it in the browser too:  npm run dev -- --host"
echo ""
echo "Git commands (not run for you):"
echo "  git add package.json package-lock.json vite.config.js"
echo "  git commit -m \"Upgrade vite, vitest and plugin-react, keep iOS 14+ build target\""
echo "  git push"
