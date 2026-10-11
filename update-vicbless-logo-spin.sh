#!/usr/bin/env bash
# Vicbless: the logo in the home page's top bar idles for 2.5 s, spins like a coin (two turns, 3 s) and stands
# straight again, forever. Run from the REPO ROOT:  bash update-vicbless-logo-spin.sh
#   frontend/src/components/Logo.jsx   REPLACED (only if it is still the version I gave you; FORCE=1 overwrites)
#   frontend/src/styles.css            the "Logo coin spin" block is ADDED at the end (or UPDATED, if you ran the first version)
# The letters, outline and glow are not touched, and neither are Vic's dashboard and sign-in logos. With Motion off
# in the site menu, the logo stays still. It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -f frontend/src/components/Logo.jsx ] || [ ! -f frontend/src/styles.css ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and frontend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/Logo.jsx" <<'VICBLESS_EOF'
import { LOGO_PATH, LOGO_VIEWBOX } from './logoPath.js'

// The Vicbless wordmark.
//   onClick  makes it a link back to the top of the page (used in the public site's header). That one also
//            does the coin spin (see "Logo coin spin" at the end of styles.css): it stands still for a couple of
//            seconds, spins like a coin, and stands straight again. Both faces are the same logo, so the
//            writing never reads backwards.
//   as       'h1' (default) makes it the page heading. Anything else makes it a plain picture,
//            for screens that have their own heading (Vic's dashboard).
export default function Logo({ onClick, as = 'h1' }) {
  const art = (
    <svg viewBox={LOGO_VIEWBOX} aria-hidden="true" focusable="false">
      <path d={LOGO_PATH} />
    </svg>
  )

  if (as !== 'h1') {
    return (
      <div className="logo" role="img" aria-label="Vicbless Barbershop">
        {art}
      </div>
    )
  }

  // The coin: a front face, and a back face turned around behind it (hidden until the coin is turned).
  // The back one is only for looks, so screen readers skip it.
  const coin = (
    <span className="logo-coin">
      <span className="logo-face">{art}</span>
      <span className="logo-face logo-face-back" aria-hidden="true">
        {art}
      </span>
    </span>
  )

  return (
    <h1 className="logo">
      {onClick ? (
        <a className="logo-link" href="/" onClick={onClick}>
          {coin}
          <span className="sr-only">Vicbless Barbershop, back to top</span>
        </a>
      ) : (
        <>
          {art}
          <span className="sr-only">Vicbless Barbershop</span>
        </>
      )}
    </h1>
  )
}
VICBLESS_EOF
cat > "$STAGE/coin.css" <<'VICBLESS_EOF'
/* ---------- Logo coin spin (the logo in the home page's top bar) ----------
   Stands still for 2.5 s, then turns around its upright middle line like a coin spinning on a table: two full
   turns over 3 s, a little quicker at first and slowing down, then it is standing straight again. Repeats forever.
   Nothing about the letters changes. Only the whole logo is turned.
   To change it: the 5.5s (whole cycle = standing still + spinning) and the 45.45% (the share of the cycle spent
   standing still: 2.5 / 5.5) below. The spin lasts the rest, 3 s. 720deg is two turns; 360deg is one. */
.brand .logo {
  perspective: 700px; /* gives the turn some depth: the near edge looks bigger as it comes round */
}

.logo-coin {
  display: block;
  position: relative;
  height: 100%;
  transform-style: preserve-3d;
  animation: logo-coin 5.5s infinite;
}

.logo-face {
  display: block;
  height: 100%;
  -webkit-backface-visibility: hidden;
  backface-visibility: hidden;
}

/* The back face sits on top of the front one, turned around, so it shows when the coin is turned. */
.logo-face-back {
  position: absolute;
  inset: 0;
  transform: rotateY(180deg);
}

@keyframes logo-coin {
  0%,
  45.45% {
    transform: rotateY(0deg);
    animation-timing-function: cubic-bezier(0.3, 0.45, 0.3, 1); /* gentle start, slow settle */
  }
  100% {
    transform: rotateY(720deg);
  }
}

/* Motion off in the menu (which starts from the visitor's system setting): the logo just stays still. */
html[data-motion='off'] .logo-coin {
  animation: none;
}
VICBLESS_EOF
export STAGE
python3 - <<'PY'
import hashlib, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"]); force = os.environ.get("FORCE") == "1"
sha = lambda text: hashlib.sha256(text.encode()).hexdigest()
KNOWN_OLD_LOGO = ['0612a1daf4d0313fae4b0b2ab1f9992c1c692d1ceb567295e132bd72b1f8f288', '0e3d1a23366a1fc10386bd48458ad9db36e8ccc07e7ced59efd6f48d96b3eb99']

logo = Path("frontend/src/components/Logo.jsx")
css = Path("frontend/src/styles.css")
new_logo = (stage / "Logo.jsx").read_text().rstrip("\n") + "\n"
block = (stage / "coin.css").read_text().strip("\n") + "\n"
MARK = "Logo coin spin"

current = logo.read_text()
if sha(current) == sha(new_logo):
    logo_action = None
elif sha(current) in KNOWN_OLD_LOGO or force:
    logo_action = new_logo
else:
    print("Stopped. frontend/src/components/Logo.jsx is not the version this script expects (was it edited?).")
    print("Nothing was changed. Tell me what differs, or run with FORCE=1 to overwrite it.")
    sys.exit(1)

css_text = css.read_text()
# The block runs from its heading comment to the end of its last rule. An earlier version of it is replaced in place.
import re
span = re.search(r"/\* -{10} Logo coin spin.*?html\[data-motion='off'\] \.logo-coin \{\n  animation: none;\n\}\n?", css_text, re.S)
if span and span.group(0).strip() == block.strip():
    add_css = False
elif span:
    css_text = css_text[:span.start()] + block + css_text[span.end():]
    add_css = True
    replaced_block = True
else:
    css_text = css_text.rstrip("\n") + "\n\n" + block
    add_css = True

if logo_action is not None:
    logo.write_text(logo_action)
if add_css:
    css.write_text(css_text)
print("Wrote:" if (logo_action is not None or add_css) else "Already up to date. Nothing to change.")
if logo_action is not None: print("  -", logo)
if add_css: print("  -", css, "(coin spin block added or updated)")
PY
echo
echo "Next: cd frontend && npm run dev and look at the logo on the home page (wait about 2.5 s). Then:  git add -A && git commit"
