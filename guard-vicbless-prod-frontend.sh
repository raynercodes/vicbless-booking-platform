#!/usr/bin/env bash
# Vicbless: the PROD frontend deploy now stops, with a clear message, if the prod backend is not deployed yet.
# Run from the REPO ROOT:  bash guard-vicbless-prod-frontend.sh
# Before: it carried on and published a site with no /api route. Now it fails in the plan step, before anything is
# approved or changed. Dev is untouched (it still deploys without a backend).
# It edits deploy-frontend.yml in place (in .github/workflows/, or .github/workflows-paused/), changing ONE spot, and
# stops without changing anything if that spot is not found exactly once. It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -d .github ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and .github)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
python3 - <<'PY'
import sys
from pathlib import Path

OLD = '          echo "API domain: ${DOMAIN:-none yet. Deploy the prod backend first}"\n'
NEW = '          echo "API domain: ${DOMAIN:-none yet. Deploy the prod backend first}"\n          # Prod must never go live without its API: the booking page would load and then nothing would work.\n          if [ -z "$DOMAIN" ]; then\n            echo "::error::The prod backend is not deployed yet (stack vicbless-backend-prod has no ApiDomainName). Run \'Deploy backend\' for prod first, then run this again."\n            exit 1\n          fi\n'
files = [p for p in (Path(".github/workflows/deploy-frontend.yml"), Path(".github/workflows-paused/deploy-frontend.yml")) if p.exists()]
if not files:
    print("Could not find deploy-frontend.yml in .github/workflows/ or .github/workflows-paused/.")
    sys.exit(1)
path = files[0]
text = path.read_text()
# The prod lookup is the one that mentions vicbless-backend-prod; the guard goes right after its echo line.
marker = "vicbless-backend-prod"
if NEW in text:
    print("Already up to date. Nothing to change."); sys.exit(0)
if text.count(OLD) != 1 or marker not in text:
    print(f"Stopped. {path} does not have the prod lookup step exactly once (was it edited?). Nothing was changed.")
    sys.exit(1)
path.write_text(text.replace(OLD, NEW))
print("Updated", path)
PY
