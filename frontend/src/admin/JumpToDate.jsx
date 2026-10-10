import { useRef } from 'react'

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

// "Pick a date": a big pill button that opens the phone's own date picker.
// The real date field sits invisibly on top of the whole button, so a tap lands on the field itself.
// That is what makes it reliable on iPhones and Android, where the native picker opens on a direct tap.
export default function JumpToDate({ value, onPick }) {
  const inputRef = useRef(null)

  return (
    <label className="admin-jump">
      <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
        <rect x="3.5" y="5" width="17" height="15.5" rx="3" fill="none" stroke="currentColor" strokeWidth="2" />
        <path d="M3.5 10h17M8 3v4M16 3v4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
      <span>Pick a date</span>
      <input
        ref={inputRef}
        type="date"
        value={value}
        aria-label="Pick a date to jump to"
        onChange={(e) => {
          if (DATE_PATTERN.test(e.target.value)) onPick(e.target.value) // clearing the field does nothing
        }}
        onClick={() => {
          try {
            inputRef.current?.showPicker?.() // opens it on desktop browsers too
          } catch {
            /* the browser already opened it, or cannot: nothing to do */
          }
        }}
      />
    </label>
  )
}
