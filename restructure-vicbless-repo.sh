#!/usr/bin/env bash
# Vicbless: split the repo into frontend/ and backend/.
# Run from the repo ROOT (the folder with .git and package.json):  bash restructure-vicbless-repo.sh
# It only moves files and writes three small ones. It runs no git commands; it prints them at the end.
set -euo pipefail

if [ ! -d .git ] || [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and package.json)."
  exit 1
fi
if [ -d frontend ] || [ -d backend ]; then
  echo "frontend/ or backend/ already exists. Nothing to do."
  exit 1
fi

mkdir frontend backend

# The whole current app moves into frontend/. Missing items (like dist) are skipped.
for item in index.html package.json package-lock.json vite.config.js public src README.md node_modules dist; do
  if [ -e "$item" ]; then
    mv "$item" frontend/
  fi
done

cat > .gitignore <<'VICBLESS_EOF'
# Frontend
node_modules
dist

# Backend (Python)
__pycache__/
*.pyc
.venv/
venv/

# Secrets: never commit these
.env
.env.*
!.env.example

# Misc
.DS_Store
*.log
VICBLESS_EOF

cat > README.md <<'VICBLESS_EOF'
# Vicbless Booking Platform

Booking platform for Vicbless Barbershop.

- `frontend/`  React + Vite site: landing page and booking flow. See `frontend/README.md`.
- `backend/`   API for availability and bookings. Not built yet.

## Branches

- `dev`   where all work happens
- `main`  stable. Merge `dev` into `main` when it is ready to ship.

## Run the frontend

```bash
cd frontend
npm install
npm run dev -- --host
```
VICBLESS_EOF

cat > backend/README.md <<'VICBLESS_EOF'
# Backend

Not built yet. This will replace the mock data layer in `frontend/src/lib/api.js`.

The frontend already defines what it needs:

- `GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD` returns the busy time blocks per day
- `POST /bookings` creates a booking, and returns 409 when the time was just taken
VICBLESS_EOF

echo ""
echo "Left in the repo root (should only be dotfiles, README.md, frontend, backend):"
ls -A | grep -v '^\.git$' | sed 's/^/  /'

echo ""
echo "Installing and testing inside frontend/..."
cd frontend
npm install
npm test

echo ""
echo "Done. Now run these yourself:"
echo "  git checkout -b dev"
echo "  git add -A"
echo "  git status          # check: files show as renamed into frontend/, no node_modules or dist"
echo "  git commit -m \"Restructure into frontend/ and backend/\""
echo "  git push -u origin dev"
echo ""
echo "From now on, run update scripts from inside frontend/."
