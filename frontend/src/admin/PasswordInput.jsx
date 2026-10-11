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
