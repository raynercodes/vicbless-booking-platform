import { useEffect, useRef } from 'react'

// A small "are you sure?" panel that opens inside a card. Focus lands on the safe choice (keep),
// so a stray Enter or tap cannot undo anything.
export default function ConfirmBox({ label, children, keepLabel, yesLabel, workingLabel, working, onKeep, onYes }) {
  const keepRef = useRef(null)
  useEffect(() => {
    keepRef.current?.focus()
  }, [])

  return (
    <div className="admin-confirm" role="group" aria-label={label}>
      <p className="admin-confirm-text">{children}</p>
      <div className="admin-confirm-actions">
        <button type="button" className="btn" ref={keepRef} onClick={onKeep} disabled={working}>
          {keepLabel}
        </button>
        <button type="button" className="btn admin-danger" onClick={onYes} disabled={working}>
          {working ? workingLabel : yesLabel}
        </button>
      </div>
    </div>
  )
}
