import { useEffect, useRef, useState } from 'react'
import { SOCIAL } from '../config.js'
import { useSettings } from '../lib/useSettings.js'
import { InstagramIcon, TikTokIcon } from './Socials.jsx'

const BarsIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M4 7h16M4 12h16M4 17h16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const CloseIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const Chevron = () => (
  <svg className="chev" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

// A whole row you tap to flip a setting on or off.
function Switch({ id, label, hint, checked, onToggle }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-labelledby={`${id}-label`}
      aria-describedby={`${id}-hint`}
      className="setting"
      onClick={onToggle}
    >
      <span className="setting-text">
        <span id={`${id}-label`} className="setting-label">
          {label}
        </span>
        <span id={`${id}-hint`} className="setting-hint">
          {hint}
        </span>
      </span>
      <span className="switch-state" aria-hidden="true">
        {checked ? 'On' : 'Off'}
      </span>
      <span className="switch-track" aria-hidden="true" />
    </button>
  )
}

// `children` are extra rows shown at the bottom of the menu (the dashboard adds View site and Sign out).
// `settingsExtra({ close })` adds rows to the Settings dropdown; only the dashboard passes it, so customers never see them.
export default function SiteMenu({ children, settingsExtra }) {
  const [open, setOpen] = useState(false)
  const [section, setSection] = useState(null) // 'socials' | 'settings' | null, one open at a time
  const wrapRef = useRef(null)
  const buttonRef = useRef(null)
  const { motion, theme, setMotion, setTheme } = useSettings()

  // Escape closes the menu (and returns focus to the button), a tap outside closes it too.
  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape') {
        setOpen(false)
        buttonRef.current?.focus()
      }
    }
    const onPointerDown = (e) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPointerDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPointerDown)
    }
  }, [open])

  // Closing the menu collapses the dropdowns, so it always opens fresh.
  useEffect(() => {
    if (!open) setSection(null)
  }, [open])

  const toggleSection = (name) => setSection((current) => (current === name ? null : name))

  return (
    <div className="site-menu" ref={wrapRef}>
      <button
        ref={buttonRef}
        type="button"
        className="menu-toggle"
        aria-label="Menu"
        aria-expanded={open}
        aria-controls="site-menu-panel"
        onClick={() => setOpen((o) => !o)}
      >
        {open ? <CloseIcon /> : <BarsIcon />}
      </button>

      <div id="site-menu-panel" className="menu-panel" hidden={!open}>
        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'socials'}
            aria-controls="menu-socials"
            onClick={() => toggleSection('socials')}
          >
            Socials
            <Chevron />
          </button>
          <div id="menu-socials" className="menu-sub" hidden={section !== 'socials'}>
            <a className="menu-link" href={SOCIAL.tiktok} target="_blank" rel="noopener noreferrer">
              <TikTokIcon />
              TikTok
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
            <a className="menu-link" href={SOCIAL.instagram} target="_blank" rel="noopener noreferrer">
              <InstagramIcon />
              Instagram
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </div>
        </div>

        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'settings'}
            aria-controls="menu-settings"
            onClick={() => toggleSection('settings')}
          >
            Settings
            <Chevron />
          </button>
          <div id="menu-settings" className="menu-sub" hidden={section !== 'settings'}>
            {settingsExtra && settingsExtra({ close: () => setOpen(false) })}
            <Switch
              id="set-motion"
              label="Motion"
              hint="Parallax, scroll effects and animations"
              checked={motion === 'on'}
              onToggle={() => setMotion(motion === 'on' ? 'off' : 'on')}
            />
            <Switch
              id="set-theme"
              label="Dark mode"
              hint="Switch off for light mode"
              checked={theme === 'dark'}
              onToggle={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
            />
          </div>
        </div>

        {children && <div className="menu-extra">{children}</div>}
      </div>
    </div>
  )
}
