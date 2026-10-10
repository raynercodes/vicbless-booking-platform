#!/usr/bin/env bash
# Vicbless booking page: notes counter ("0/500"), name and notes length limits, friendlier email message.
# Run from inside frontend/ :  bash update-vicbless-notes-counter.sh
#
# What it changes (and nothing else):
#   src/config.js                 adds LIMITS = { name: 50, notes: 500 }  (the API enforces the same numbers)
#   src/pages/Book.jsx            name box stops at 50 characters; notes box stops at 500 and shows a live counter
#   src/lib/format.js (+ test)    countLabel() and nearLimit(), small functions with tests
#   src/styles.css                how the counter looks (turns red at 90% of the limit)
#   src/admin/mockAdminApi.js     sign-in message worded like the real API's
# It checks every file first and writes nothing unless ALL the changes can be made. Safe to run twice.
# It runs the frontend tests at the end and prints the git commands; it never runs git.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless package.json || [ ! -f src/pages/Book.jsx ]; then
  echo "Run this from inside the frontend/ folder of the vicbless-booking-platform repo."
  exit 1
fi

PATCH="${TMPDIR:-/tmp}/vicbless_notes_counter_patch.py"
cat > "$PATCH" <<'VICBLESS_EOF'
"""Adds the notes counter (0/500), the name/notes length limits, and the friendlier email message.
Run from inside frontend/. Nothing is written unless EVERY change can be made, so it never half-applies."""

import re
import sys
from pathlib import Path

root = Path(".")
files = {
    "config": root / "src/config.js",
    "book": root / "src/pages/Book.jsx",
    "format": root / "src/lib/format.js",
    "format_test": root / "src/lib/format.test.js",
    "styles": root / "src/styles.css",
    "mock": root / "src/admin/mockAdminApi.js",
}
missing = [str(p) for k, p in files.items() if k != "mock" and not p.exists()]
if missing:
    sys.exit("Cannot find: " + ", ".join(missing) + "\nRun this from inside the frontend/ folder.")

text = {k: p.read_text() for k, p in files.items() if p.exists()}
new = dict(text)
notes = []


def add_names_to_import(src: str, module: str, names: list[str], label: str) -> str:
    """Adds names to an existing `import { ... } from '<module>'` line (keeps it sorted)."""
    m = re.search(r"import \{([^}]*)\} from '" + re.escape(module) + r"'", src)
    if not m:
        sys.exit(f"Cannot find the import from {module} in {label}. Nothing was changed.")
    have = [n.strip() for n in m.group(1).split(",") if n.strip()]
    for n in names:
        if n not in have:
            have.append(n)
    return src[: m.start()] + "import { " + ", ".join(sorted(have)) + " } from '" + module + "'" + src[m.end() :]


# 1. config.js: the limits, in one place. The backend has a test that checks these match its own.
if "export const LIMITS" not in new["config"]:
    new["config"] = (
        new["config"].rstrip("\n")
        + """

// The most a customer may type. The booking form enforces these and shows the notes counter; the API
// enforces the same numbers, and a backend test fails if the two ever differ.
export const LIMITS = { name: 50, notes: 500 }
"""
    )
    notes.append("config.js: added LIMITS (name 50, notes 500)")

# 2. format.js: the counter text and the "getting close" check, as small functions that are easy to test.
if "countLabel" not in new["format"]:
    new["format"] = (
        new["format"].rstrip("\n")
        + """

// "37/500". Shown under the notes box and updated on every keystroke.
export const countLabel = (used, max) => `${used}/${max}`

// True once 90% of the limit is used, so the counter can warn before the box stops accepting text.
export const nearLimit = (used, max) => used >= Math.floor(max * 0.9)
"""
    )
    notes.append("format.js: added countLabel and nearLimit")

# 3. format.test.js: tests for those two functions.
if "countLabel" not in new["format_test"]:
    new["format_test"] = add_names_to_import(new["format_test"], "./format.js", ["countLabel", "nearLimit"], "format.test.js")
    new["format_test"] = (
        new["format_test"].rstrip("\n")
        + """

describe('countLabel', () => {
  it('shows used over the limit', () => {
    expect(countLabel(0, 500)).toBe('0/500')
    expect(countLabel(37, 500)).toBe('37/500')
    expect(countLabel(500, 500)).toBe('500/500')
  })
})

describe('nearLimit', () => {
  it('turns on at 90% of the limit and stays on', () => {
    expect(nearLimit(0, 500)).toBe(false)
    expect(nearLimit(449, 500)).toBe(false)
    expect(nearLimit(450, 500)).toBe(true)
    expect(nearLimit(500, 500)).toBe(true)
  })
})
"""
    )
    notes.append("format.test.js: added tests for the counter")

# 4. Book.jsx: limits on the name box, the notes box with its counter, and the friendlier email message.
book = new["book"]
if "LIMITS" not in book:
    book = add_names_to_import(book, "../config.js", ["LIMITS"], "Book.jsx")
    book = add_names_to_import(book, "../lib/format.js", ["countLabel", "nearLimit"], "Book.jsx")

    name_input = '<input id="f-name" name="name"'
    if name_input not in book:
        sys.exit("Cannot find the name field in Book.jsx. Nothing was changed.")
    book = book.replace(name_input, '<input id="f-name" name="name" maxLength={LIMITS.name}', 1)

    textarea = '<textarea id="f-notes" name="notes" rows={3} value={form.notes} onChange={updateField} />'
    if textarea not in book:
        sys.exit("Cannot find the notes box in Book.jsx. Nothing was changed.")
    counter_line = (
        '<textarea id="f-notes" name="notes" rows={3} maxLength={LIMITS.notes} value={form.notes} onChange={updateField} aria-describedby="notes-count" />\n'
        "              <p\n"
        '                id="notes-count"\n'
        "                className={nearLimit(form.notes.length, LIMITS.notes) ? 'counter counter-near' : 'counter'}\n"
        "              >\n"
        "                {countLabel(form.notes.length, LIMITS.notes)}\n"
        "              </p>"
    )
    book = book.replace(textarea, counter_line, 1)
    notes.append("Book.jsx: name limit, notes limit, and the live notes counter")

# The new sentence has an apostrophe, so it goes in a double-quoted JavaScript string.
old_email = "'Enter a valid email, or leave it blank.'"
new_email = '"That email doesn\'t look right. Use something like name@example.com, or leave it blank."'
if old_email in book:
    book = book.replace(old_email, new_email)
    notes.append("Book.jsx: friendlier email message (same wording as the API)")
new["book"] = book

# 5. styles.css: how the counter looks.
if ".counter" not in new["styles"]:
    new["styles"] = (
        new["styles"].rstrip("\n")
        + """

/* The "0/500" under the notes box. Quiet until the person is close to the limit. */
.counter {
  margin: 4px 0 0;
  text-align: right;
  font-size: 0.85rem;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}

.counter-near {
  color: var(--danger);
  font-weight: 600;
}
"""
    )
    notes.append("styles.css: counter style")

# 6. The sample sign-in screen's message, worded like the API's.
if "mock" in new and "throw new Error('Enter your password.')" in new["mock"]:
    new["mock"] = new["mock"].replace("throw new Error('Enter your password.')", "throw new Error('Please enter your password.')")
    notes.append("mockAdminApi.js: sign-in message worded like the API's")

changed = [k for k in new if new[k] != text.get(k)]
for k in changed:
    files[k].write_text(new[k])
if not changed:
    print("Already up to date. Nothing to change.")
else:
    print("Changed:")
    for n in notes:
        print("  -", n)
VICBLESS_EOF
python3 "$PATCH"
rm -f "$PATCH"

if [ -d node_modules ]; then
  echo ""
  echo "Running the frontend tests..."
  npm test
else
  echo ""
  echo "node_modules is missing, so the tests were not run. Run npm install, then npm test."
fi

echo ""
echo "Done. Try it: npm run dev -- --host, open the booking page, pick a time, and type in the notes box."
echo "Then run these yourself:"
echo "  git status"
echo "  git add -A"
echo "  git commit -m \"Booking form: notes counter and length limits\""
echo "  git push origin dev"
