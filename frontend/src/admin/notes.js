// Long notes on Vic's schedule: when to fold them up behind "Show more". Pure, so it is easy to test.

export const NOTE_PREVIEW_CHARS = 140 // a note longer than this is folded
export const NOTE_PREVIEW_LINES = 3 // so is one with more line breaks than this

// True when a note is long enough that the card should show a short preview with "Show more".
// Short notes are always shown in full, so there is never a button with nothing behind it.
export function isLongNote(text) {
  const note = String(text ?? '')
  return note.length > NOTE_PREVIEW_CHARS || note.split('\n').length > NOTE_PREVIEW_LINES
}
