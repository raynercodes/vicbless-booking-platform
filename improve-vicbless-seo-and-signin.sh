#!/usr/bin/env bash
# Vicbless: an eye button on Vic's sign-in password, plus the search-engine basics (build 2026-10-11 a).
# Run from the REPO ROOT:  bash improve-vicbless-seo-and-signin.sh
#
#   frontend/src/admin/PasswordInput.jsx + .css   ADDED  a password box with a show/hide eye (hidden by default)
#   frontend/src/admin/SignIn.jsx                 EDITED two spots, to use that box
#   frontend/index.html                           EDITED better title and description, canonical address, "index, follow",
#                                                 structured data about the shop (name, address, hours), and a no-JavaScript fallback
#   frontend/public/robots.txt, sitemap.xml       ADDED (a file that already exists and differs is left alone and reported)
#   frontend/src/lib/seo.test.js                  ADDED a test that keeps the structured data identical to config.js
#
# Vic's dashboard is already kept out of search: it lives at /#/vic and search engines ignore everything after the "#",
# so it can never be listed as a page, and nothing on the public site links to it. This script changes nothing there.
# Every edit is checked BEFORE anything is written: if a spot is not found exactly once, nothing changes and it says which.
# It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -f frontend/index.html ] || [ ! -f frontend/src/admin/SignIn.jsx ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and frontend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$(dirname 'src/admin/PasswordInput.jsx')"
cat > "$STAGE/src/admin/PasswordInput.jsx" <<'VICBLESS_EOF'
import { useState } from 'react'
import './PasswordInput.css'

// A password box with an eye button that shows or hides what was typed, so Vic can check it before he signs in.
// It is a normal controlled input: the parent keeps the value. Hidden by default, and hidden again after sign-in
// because this component unmounts with the sign-in screen.
//
// Accessibility: the button says what it will DO ("Show password" / "Hide password"), aria-pressed says whether the
// password is visible right now, and it can be reached with the keyboard like any other button.
// When the text is visible, the phone's autocorrect, auto-capital and spell check are switched off so it does not
// change what he typed.

const EyeOpen = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
    <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z" />
    <circle cx="12" cy="12" r="3" />
  </svg>
)

const EyeOff = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
    <path d="M9.9 5.2A10.5 10.5 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4.1M6.6 6.6A17 17 0 0 0 2 12s3.6 7 10 7a10.4 10.4 0 0 0 4.2-.9" />
    <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
    <path d="M3 3l18 18" />
  </svg>
)

export default function PasswordInput({ id, value, onChange, invalid = false, describedBy, autoComplete = 'current-password' }) {
  const [visible, setVisible] = useState(false)
  return (
    <div className="password-input">
      <input
        id={id}
        type={visible ? 'text' : 'password'}
        autoComplete={autoComplete}
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        value={value}
        onChange={onChange}
        aria-invalid={invalid}
        aria-describedby={describedBy}
      />
      <button
        type="button"
        className="password-toggle"
        onClick={() => setVisible((v) => !v)}
        aria-pressed={visible}
        aria-label={visible ? 'Hide password' : 'Show password'}
      >
        {visible ? <EyeOff /> : <EyeOpen />}
      </button>
    </div>
  )
}
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'src/admin/PasswordInput.css')"
cat > "$STAGE/src/admin/PasswordInput.css" <<'VICBLESS_EOF'
/* The password box with its show/hide eye. The button sits inside the right edge of the box. */
.password-input {
  position: relative;
}

/* Room on the right so long passwords never run underneath the eye. */
.password-input input {
  width: 100%;
  padding-right: 52px;
}

.password-toggle {
  position: absolute;
  top: 50%;
  right: 4px;
  transform: translateY(-50%);
  display: grid;
  place-items: center;
  width: 44px; /* a finger-sized target */
  height: 44px;
  padding: 0;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--muted);
  cursor: pointer;
}

.password-toggle:hover,
.password-toggle[aria-pressed='true'] {
  color: var(--accent);
}
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'src/lib/seo.test.js')"
cat > "$STAGE/src/lib/seo.test.js" <<'VICBLESS_EOF'
// Keeps the search-engine data in index.html honest: the structured data Google reads about the shop must say the
// same thing as config.js (address, hours, social links), so changing one without the other fails here.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { BUSINESS, HOURS, SOCIAL } from '../config.js'

const html = readFileSync(new URL('../../index.html', import.meta.url), 'utf8')
const jsonLd = () => {
  const match = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)
  expect(match, 'index.html has no application/ld+json block').toBeTruthy()
  return JSON.parse(match[1])
}

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const hhmm = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`

describe('structured data (JSON-LD)', () => {
  it('describes a barber shop with the name and the address from config.js', () => {
    const data = jsonLd()
    expect(data['@type']).toBe('BarberShop')
    expect(data.name).toBe(BUSINESS.name)
    const [street, cityLine] = BUSINESS.address
    const [city, rest] = cityLine.split(', ')
    const [region, zip] = rest.split(' ')
    expect(data.address).toMatchObject({ '@type': 'PostalAddress', streetAddress: street, addressLocality: city, addressRegion: region, postalCode: zip, addressCountry: 'US' })
  })

  it('lists exactly the opening hours in config.js', () => {
    const expected = []
    for (const [day, windows] of Object.entries(HOURS)) {
      for (const [open, close] of windows || []) expected.push(`${DAY_NAMES[day]} ${hhmm(open)}-${hhmm(close)}`)
    }
    const listed = []
    for (const spec of jsonLd().openingHoursSpecification) {
      for (const day of [].concat(spec.dayOfWeek)) listed.push(`${day} ${spec.opens}-${spec.closes}`)
    }
    expect(listed.sort()).toEqual(expected.sort())
  })

  it('links the social profiles from config.js', () => {
    expect([...jsonLd().sameAs].sort()).toEqual(Object.values(SOCIAL).sort())
  })

  it('does not publish the placeholder phone number', () => {
    // BUSINESS.phone is still a placeholder. Add "telephone" to the JSON-LD only once it is Vic's real number.
    if (/PLACEHOLDER|\(555\)/.test(BUSINESS.phone)) expect(jsonLd()).not.toHaveProperty('telephone')
  })
})

describe('page head', () => {
  it('has one title, a description, a canonical address, and allows indexing', () => {
    expect(html.match(/<title>/g)).toHaveLength(1)
    expect(html).toMatch(/<meta name="description" content="[^"]{50,170}"/)
    expect(html).toContain('<link rel="canonical" href="https://vicbless.com/" />')
    expect(html).toMatch(/<meta name="robots" content="index, follow/)
  })
})
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'public/robots.txt')"
cat > "$STAGE/public/robots.txt" <<'VICBLESS_EOF'
# Vicbless Barbershop. Everything public may be crawled. The API is data, not pages.
# Vic's dashboard lives behind a "#" address (/#/vic). Search engines never see anything after the "#",
# so it cannot be listed as a page of its own, and nothing on the public site links to it.
User-agent: *
Disallow: /api/

Sitemap: https://vicbless.com/sitemap.xml
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'public/sitemap.xml')"
cat > "$STAGE/public/sitemap.xml" <<'VICBLESS_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <!-- One page: the booking screen is part of the same page (an address with a "#"), so it is not listed separately. -->
  <url>
    <loc>https://vicbless.com/</loc>
  </url>
</urlset>
VICBLESS_EOF
export STAGE
python3 - <<'PY'
import json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"]); fe = Path("frontend")
NEW = json.loads('{"src/admin/PasswordInput.jsx": true, "src/admin/PasswordInput.css": true, "src/lib/seo.test.js": true, "public/robots.txt": false, "public/sitemap.xml": false}')
PATCHES = json.loads('[["index.html", "    <title>Vicbless Barbershop</title>\\n", "    <title>Vicbless Barbershop | Barber in Baxley, GA</title>\\n", false], ["index.html", "    <meta name=\\"description\\" content=\\"Book a haircut at Vicbless Barbershop in Baxley, GA. Pick a service, choose a time, done.\\" />\\n", "    <meta name=\\"description\\" content=\\"Vicbless Barbershop in Baxley, GA. Men\'s haircuts, designs, beard and eyebrow work, and kids cuts. Book your time online.\\" />\\n    <link rel=\\"canonical\\" href=\\"https://vicbless.com/\\" />\\n    <meta name=\\"robots\\" content=\\"index, follow, max-image-preview:large\\" />\\n", false], ["index.html", "  </head>\\n", "    <!-- What Google reads to understand the business (name, address, hours). src/lib/seo.test.js checks it against config.js. -->\\n    <script type=\\"application/ld+json\\">\\n      {\\n        \\"@context\\": \\"https://schema.org\\",\\n        \\"@type\\": \\"BarberShop\\",\\n        \\"name\\": \\"Vicbless Barbershop\\",\\n        \\"url\\": \\"https://vicbless.com/\\",\\n        \\"image\\": \\"https://vicbless.com/og-image.png\\",\\n        \\"logo\\": \\"https://vicbless.com/icon-512.png\\",\\n        \\"description\\": \\"Barbershop in Baxley, GA. Men\'s haircuts, designs, beard and eyebrow work, and kids cuts. Book online.\\",\\n        \\"address\\": {\\n          \\"@type\\": \\"PostalAddress\\",\\n          \\"streetAddress\\": \\"656 S Main St, Suite C\\",\\n          \\"addressLocality\\": \\"Baxley\\",\\n          \\"addressRegion\\": \\"GA\\",\\n          \\"postalCode\\": \\"31513\\",\\n          \\"addressCountry\\": \\"US\\"\\n        },\\n        \\"openingHoursSpecification\\": [\\n          { \\"@type\\": \\"OpeningHoursSpecification\\", \\"dayOfWeek\\": [\\"Monday\\", \\"Tuesday\\"], \\"opens\\": \\"12:00\\", \\"closes\\": \\"18:00\\" },\\n          { \\"@type\\": \\"OpeningHoursSpecification\\", \\"dayOfWeek\\": [\\"Thursday\\", \\"Friday\\"], \\"opens\\": \\"11:00\\", \\"closes\\": \\"19:00\\" },\\n          { \\"@type\\": \\"OpeningHoursSpecification\\", \\"dayOfWeek\\": \\"Saturday\\", \\"opens\\": \\"09:00\\", \\"closes\\": \\"12:00\\" },\\n          { \\"@type\\": \\"OpeningHoursSpecification\\", \\"dayOfWeek\\": \\"Saturday\\", \\"opens\\": \\"12:35\\", \\"closes\\": \\"17:00\\" }\\n        ],\\n        \\"sameAs\\": [\\"https://www.tiktok.com/@vicblesss\\", \\"https://www.instagram.com/vicblessss\\"]\\n      }\\n    </script>\\n  </head>\\n", true], ["index.html", "    <div id=\\"root\\"></div>\\n", "    <div id=\\"root\\"></div>\\n    <noscript>\\n      <h1>Vicbless Barbershop, Baxley, GA</h1>\\n      <p>Men\'s haircuts, designs, beard and eyebrow work, and kids cuts. 656 S Main St, Suite C, Baxley, GA 31513.</p>\\n      <p>Booking needs JavaScript. Turn it on to book a time online.</p>\\n    </noscript>\\n", true], ["src/admin/SignIn.jsx", "import Greeting from \'./Greeting.jsx\'\\n", "import Greeting from \'./Greeting.jsx\'\\nimport PasswordInput from \'./PasswordInput.jsx\'\\n", true], ["src/admin/SignIn.jsx", "          <input\\n            id=\\"admin-password\\"\\n            type=\\"password\\"\\n            autoComplete=\\"current-password\\"\\n            value={password}\\n            onChange={(e) => setPassword(e.target.value)}\\n            aria-invalid={!!error}\\n            aria-describedby=\\"admin-password-error\\"\\n          />\\n", "          <PasswordInput\\n            id=\\"admin-password\\"\\n            value={password}\\n            onChange={(e) => setPassword(e.target.value)}\\n            invalid={!!error}\\n            describedBy=\\"admin-password-error\\"\\n          />\\n", true]]')
writes = {}
notes = []

# 1. edits to existing files, all checked before anything is written
for rel, old, new, required in PATCHES:
    path = fe / rel
    if not path.exists():
        print(f"Stopped. {path} does not exist. Nothing was changed."); sys.exit(1)
    text = writes.get(path, path.read_text())
    if new in text:
        continue
    if text.count(old) != 1:
        if required:
            print(f"Stopped. {path} does not have the spot I need to edit exactly once (found {text.count(old)}). Was it edited?")
            print("Nothing was changed. Tell me what differs."); sys.exit(1)
        notes.append(f"Left alone (optional wording edit, spot not found): {path}")
        continue
    writes[path] = text.replace(old, new)

# 2. new files
for rel, overwrite_ok in NEW.items():
    path = fe / rel
    new_text = (stage / rel).read_text().rstrip("\n") + "\n"
    if not path.exists():
        writes[path] = new_text
    elif path.read_text() == new_text:
        continue
    elif overwrite_ok:
        writes[path] = new_text
    else:
        notes.append(f"Left alone (it already exists and differs): {path}")

for path, text in writes.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
if writes:
    print("Wrote:")
    for path in sorted(writes): print("  -", path)
else:
    print("Already up to date. Nothing to change.")
for n in notes: print("Note:", n)
PY
echo
echo "Next:  cd frontend && npm test"
echo "Then:  git add -A && git commit, push to dev (dev deploys), look at the sign-in screen, then merge to main."
echo "After prod is live: add vicbless.com in Google Search Console, submit https://vicbless.com/sitemap.xml,"
echo "and click Request indexing on the home page."
