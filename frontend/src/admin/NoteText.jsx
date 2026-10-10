import { useId, useState } from 'react'
import { isLongNote } from './notes.js'

const Chevron = ({ open }) => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false" className={open ? 'admin-chevron open' : 'admin-chevron'}>
    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

// A customer's note on Vic's schedule. Short notes show in full. A long one (up to 500 characters) shows
// the first few lines with a "Show more" button, and "Show less" folds it back so the day stays easy to scan.
// The text wraps inside the card, so there is never any side-to-side scrolling.
export default function NoteText({ text, who }) {
  const [open, setOpen] = useState(false)
  const id = useId()
  const long = isLongNote(text)

  return (
    <div className="admin-notes-wrap">
      <p id={id} className={long && !open ? 'admin-notes admin-notes-folded' : 'admin-notes'}>
        {text}
      </p>
      {long && (
        <button
          type="button"
          className="admin-notes-toggle"
          aria-expanded={open}
          aria-controls={id}
          aria-label={`${open ? 'Show less' : 'Show more'} of ${who}'s note`}
          onClick={() => setOpen((v) => !v)}
        >
          <Chevron open={open} />
          {open ? 'Show less' : 'Show more'}
        </button>
      )}
    </div>
  )
}
