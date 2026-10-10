#!/usr/bin/env bash
# Pause (or resume) the GitHub Actions workflows, so a commit or push runs nothing and nothing reaches AWS.
# Run from the repo ROOT:
#   bash pause-vicbless-workflows.sh          moves .github/workflows/* into .github/workflows-paused/
#   bash pause-vicbless-workflows.sh resume   moves them back
# GitHub only runs files inside .github/workflows/, so a paused file cannot trigger. Nothing is deleted or edited.
# It runs no git commands.
set -euo pipefail

if [ ! -d .git ] || [ ! -d .github ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and .github)."
  exit 1
fi

LIVE=.github/workflows
PAUSED=.github/workflows-paused
mode="${1:-pause}"

move_all() {
  local from="$1" to="$2" count=0
  mkdir -p "$to"
  shopt -s nullglob
  for f in "$from"/*.yml "$from"/*.yaml; do
    if [ -e "$to/$(basename "$f")" ]; then
      echo "Skipped $f: $to/$(basename "$f") already exists."
      continue
    fi
    mv "$f" "$to/"
    echo "  moved $(basename "$f")"
    count=$((count + 1))
  done
  echo "$count file(s) moved."
}

case "$mode" in
  pause)
    [ -d "$LIVE" ] || { echo "No $LIVE folder, nothing to pause."; exit 0; }
    echo "Pausing workflows..."
    move_all "$LIVE" "$PAUSED"
    rmdir "$LIVE" 2>/dev/null || true
    echo ""
    echo "Done. Commits and pushes now run nothing on GitHub. To turn them back on:  bash pause-vicbless-workflows.sh resume"
    ;;
  resume)
    [ -d "$PAUSED" ] || { echo "Nothing is paused ($PAUSED does not exist)."; exit 0; }
    echo "Resuming workflows..."
    mkdir -p "$LIVE"
    move_all "$PAUSED" "$LIVE"
    rmdir "$PAUSED" 2>/dev/null || true
    echo ""
    echo "Done. The next push that matches a workflow's paths will run it again."
    ;;
  *)
    echo "Usage: bash pause-vicbless-workflows.sh [pause|resume]"
    exit 1
    ;;
esac
