#!/usr/bin/env bash
# Vicbless: TEST showing Vic's photo section BEFORE the video on the home page (build 2026-10-12 d).
# Run from the REPO ROOT:  bash photo-before-video-vicbless.sh
#
#   frontend/src/config.js        EDITED adds one switch:  HOME_ORDER = 'photo-first'  (or 'video-first' for the old look)
#   frontend/src/pages/Home.jsx   EDITED five small spots: the photo section is drawn before the video, and the video's
#                                 scroll pan now starts when the video reaches the top instead of the top of the page
#
# Nothing else is touched: the photo keeps its own see-through "Book Now to get blessed" box and the video keeps its
# glowing booking button, exactly as they are. Statement.jsx is NOT edited.
# To go back to how it was: change that one word in config.js to 'video-first', commit and push.
# Every edit is checked BEFORE anything is written: if a spot is not found exactly once, nothing changes and it says which.
# It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -f frontend/src/pages/Home.jsx ] || [ ! -f frontend/src/config.js ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and frontend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
python3 - <<'PY'
import json, sys
from pathlib import Path

home = Path("frontend") / json.loads("\"src/pages/Home.jsx\"")
cfg = Path("frontend/src/config.js")
CONFIG_BLOCK = json.loads("\"\\n// Which comes first on the home page, a TEST for Vic (change this one word to compare the two looks):\\n//   'photo-first'  the photo section (headline, paragraph, stacked words) is the first thing under the logo, then the video\\n//   'video-first'  the video first, then the photo section (how it was)\\nexport const HOME_ORDER = 'photo-first'\\n\"")
PATCHES = json.loads("[[\"import { CTA_TEXT, HOME_TAGLINE } from '../config.js'\\n\", \"import { CTA_TEXT, HOME_ORDER, HOME_TAGLINE } from '../config.js'\\n\"], [\"// The pan finishes after the visitor has scrolled 85% of the video's height,\\n\", \"// Which comes first: the photo section or the video (HOME_ORDER in config.js).\\nconst PHOTO_FIRST = HOME_ORDER === 'photo-first'\\n\\n// The pan finishes after the visitor has scrolled 85% of the video's height,\\n\"], [\"      const p = Math.min(1, Math.max(0, window.scrollY / (h * PAN_DISTANCE)))\\n\", \"      // The pan starts once the video has scrolled up to where it rests under the logo bar. With the video first\\n      // that is the very top of the page (start = 0); with the photo first it is the height of the photo section.\\n      const main = hero.parentElement\\n      const start = main ? hero.getBoundingClientRect().top - main.getBoundingClientRect().top : 0\\n      const p = Math.min(1, Math.max(0, (window.scrollY - start) / (h * PAN_DISTANCE)))\\n\"], [\"      <main>\\n        <section ref={heroRef}\", \"      <main>\\n        {PHOTO_FIRST && <Statement />}\\n\\n        <section ref={heroRef}\"], [\"        <Statement />\\n\\n        <ShopInfo />\", \"        {!PHOTO_FIRST && <Statement />}\\n\\n        <ShopInfo />\"]]")

text = home.read_text()
# a leftover from an earlier test build of this script ("<Statement showBook />") goes back to the plain tag
text = text.replace("<Statement showBook />", "<Statement />")
for old, new in PATCHES:
    if new in text:
        continue  # already applied
    if text.count(old) != 1:
        print(f"Stopped. {home} does not have the spot I need to edit exactly once (found {text.count(old)}):")
        print("   " + old.strip().splitlines()[0])
        print("Nothing was changed. Tell me what differs."); sys.exit(1)
    text = text.replace(old, new)

cfg_text = cfg.read_text()
cfg_new = cfg_text if "HOME_ORDER" in cfg_text else cfg_text.rstrip("\n") + "\n" + CONFIG_BLOCK

# everything checked, now write
home.write_text(text)
cfg.write_text(cfg_new)
print("Done. The home page now shows the photo section first, then the video.")
print("To go back: set HOME_ORDER = 'video-first' in frontend/src/config.js.")
PY
