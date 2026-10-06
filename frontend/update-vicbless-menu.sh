#!/usr/bin/env bash
# Vicbless: three-line menu (Socials and Settings dropdowns), Motion switch, Dark/Light mode switch.
# Run from inside frontend/:  bash update-vicbless-menu.sh
# Replaces these files with full new versions. If you edited any of them locally, tell me first.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json || [ ! -f src/components/Statement.jsx ]; then
  echo "Run this from inside the frontend/ folder (with the earlier updates applied)."
  exit 1
fi

mkdir -p src/lib src/components src/pages

cat > index.html <<'VICBLESS_EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#0A0612" />
    <script>
      // Applies the saved theme and motion choice before the page paints, so there is no flash.
      // Keep in step with src/lib/settings.js.
      try {
        var saved = JSON.parse(localStorage.getItem('vicbless.settings') || '{}')
        var root = document.documentElement
        var osReduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
        root.dataset.theme = saved.theme === 'light' ? 'light' : 'dark'
        root.dataset.motion = saved.motion === 'on' || saved.motion === 'off' ? saved.motion : osReduce ? 'off' : 'on'
      } catch (e) {}
    </script>
    <title>Vicbless Barbershop</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,100..900&display=swap" rel="stylesheet" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
VICBLESS_EOF

cat > src/lib/settings.js <<'VICBLESS_EOF'
// Site settings: motion (on or off) and theme (dark or light).
// Pure logic with injected storage so it can be tested without a browser.

export const SETTINGS_KEY = 'vicbless.settings'

const CHOICES = { motion: ['on', 'off'], theme: ['dark', 'light'] }
const pick = (key, value) => (CHOICES[key].includes(value) ? value : undefined)

// storage            anything with getItem/setItem (localStorage), or null
// osReducedMotion    returns true when the visitor's system asks for less motion
// onChange           called with the new settings after every real change
//
// Only choices the visitor actually made are saved. Until they choose, motion follows
// their system setting and the theme is dark.
export function createSettingsStore({ storage = null, osReducedMotion = () => false, onChange = () => {} } = {}) {
  let chosen = {}
  try {
    const raw = JSON.parse(storage?.getItem(SETTINGS_KEY) || '{}') || {}
    chosen = { motion: pick('motion', raw.motion), theme: pick('theme', raw.theme) }
  } catch {
    chosen = {}
  }

  const resolve = () => ({
    motion: chosen.motion ?? (osReducedMotion() ? 'off' : 'on'),
    theme: chosen.theme ?? 'dark',
  })

  let state = resolve()
  const listeners = new Set()

  return {
    get: () => state,

    subscribe(fn) {
      listeners.add(fn)
      return () => listeners.delete(fn)
    },

    set(patch) {
      const next = {}
      for (const key of Object.keys(CHOICES)) {
        const value = pick(key, patch[key])
        if (value !== undefined) next[key] = value
      }
      if (Object.keys(next).length === 0) return

      chosen = { ...chosen, ...next }
      try {
        storage?.setItem(SETTINGS_KEY, JSON.stringify(chosen))
      } catch {
        /* storage full or blocked, the setting still applies for this visit */
      }

      const resolved = resolve()
      if (resolved.motion === state.motion && resolved.theme === state.theme) return
      state = resolved
      onChange(state)
      listeners.forEach((fn) => fn())
    },
  }
}

// Writes the settings onto <html> so the stylesheet can react to them.
export function applySettingsToDocument(settings, doc = document) {
  const root = doc.documentElement
  root.dataset.theme = settings.theme
  root.dataset.motion = settings.motion
  const meta = doc.querySelector('meta[name="theme-color"]')
  if (meta) meta.setAttribute('content', settings.theme === 'light' ? '#F8F4FD' : '#0A0612')
}
VICBLESS_EOF

cat > src/lib/settings.test.js <<'VICBLESS_EOF'
import { describe, it, expect, vi } from 'vitest'
import { createSettingsStore, SETTINGS_KEY } from './settings.js'

const fakeStorage = (initial = {}) => {
  const data = { ...initial }
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => {
      data[k] = v
    },
  }
}

describe('defaults', () => {
  it('starts dark with motion on', () => {
    const s = createSettingsStore({ storage: fakeStorage() })
    expect(s.get()).toEqual({ motion: 'on', theme: 'dark' })
  })

  it('starts with motion off when the system asks for less motion', () => {
    const s = createSettingsStore({ storage: fakeStorage(), osReducedMotion: () => true })
    expect(s.get().motion).toBe('off')
  })

  it('works with no storage at all', () => {
    const s = createSettingsStore({ storage: null })
    s.set({ theme: 'light' })
    expect(s.get().theme).toBe('light')
  })
})

describe('saved choices', () => {
  it('a saved choice beats the system setting', () => {
    const storage = fakeStorage({ [SETTINGS_KEY]: JSON.stringify({ motion: 'on', theme: 'light' }) })
    const s = createSettingsStore({ storage, osReducedMotion: () => true })
    expect(s.get()).toEqual({ motion: 'on', theme: 'light' })
  })

  it('ignores invalid or corrupt saved values', () => {
    const bad = fakeStorage({ [SETTINGS_KEY]: JSON.stringify({ motion: 'fast', theme: 7 }) })
    expect(createSettingsStore({ storage: bad }).get()).toEqual({ motion: 'on', theme: 'dark' })
    const junk = fakeStorage({ [SETTINGS_KEY]: '{not json' })
    expect(createSettingsStore({ storage: junk }).get()).toEqual({ motion: 'on', theme: 'dark' })
  })

  it('saves only what the visitor chose, so motion keeps following the system until they choose it', () => {
    const storage = fakeStorage()
    const s = createSettingsStore({ storage, osReducedMotion: () => true })
    s.set({ theme: 'light' })
    expect(JSON.parse(storage.data[SETTINGS_KEY])).toEqual({ theme: 'light' })
    expect(s.get()).toEqual({ motion: 'off', theme: 'light' })
  })

  it('a new store reads back what was saved', () => {
    const storage = fakeStorage()
    createSettingsStore({ storage }).set({ motion: 'off', theme: 'light' })
    expect(createSettingsStore({ storage }).get()).toEqual({ motion: 'off', theme: 'light' })
  })
})

describe('changing settings', () => {
  it('notifies subscribers and onChange, and stops after unsubscribe', () => {
    const onChange = vi.fn()
    const s = createSettingsStore({ storage: fakeStorage(), onChange })
    const listener = vi.fn()
    const off = s.subscribe(listener)
    s.set({ motion: 'off' })
    expect(listener).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenCalledWith({ motion: 'off', theme: 'dark' })
    off()
    s.set({ motion: 'on' })
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('does not notify when nothing really changed', () => {
    const listener = vi.fn()
    const s = createSettingsStore({ storage: fakeStorage() })
    s.subscribe(listener)
    s.set({ motion: 'on', theme: 'dark' })
    expect(listener).not.toHaveBeenCalled()
  })

  it('returns the same object until something changes (needed by React)', () => {
    const s = createSettingsStore({ storage: fakeStorage() })
    const first = s.get()
    expect(s.get()).toBe(first)
    s.set({ theme: 'light' })
    expect(s.get()).not.toBe(first)
  })

  it('ignores invalid values', () => {
    const s = createSettingsStore({ storage: fakeStorage() })
    s.set({ motion: 'sideways', theme: 'neon', other: 1 })
    expect(s.get()).toEqual({ motion: 'on', theme: 'dark' })
  })

  it('still applies the setting when saving fails', () => {
    const storage = { getItem: () => null, setItem: () => { throw new Error('quota') } }
    const s = createSettingsStore({ storage })
    expect(() => s.set({ theme: 'light' })).not.toThrow()
    expect(s.get().theme).toBe('light')
  })
})
VICBLESS_EOF

cat > src/lib/useSettings.js <<'VICBLESS_EOF'
import { useSyncExternalStore } from 'react'
import { applySettingsToDocument, createSettingsStore } from './settings.js'

const hasWindow = typeof window !== 'undefined'

function getStorage() {
  try {
    return hasWindow ? window.localStorage : null
  } catch {
    return null
  }
}

const store = createSettingsStore({
  storage: getStorage(),
  osReducedMotion: () => (hasWindow && window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches) || false,
  onChange: (settings) => applySettingsToDocument(settings),
})

if (typeof document !== 'undefined') applySettingsToDocument(store.get())

// For code outside React (the logo's scroll-to-top, tests).
export const getSettings = store.get
export const setSettings = store.set

export function useSettings() {
  const settings = useSyncExternalStore(store.subscribe, store.get, store.get)
  return {
    motion: settings.motion,
    theme: settings.theme,
    setMotion: (motion) => store.set({ motion }),
    setTheme: (theme) => store.set({ theme }),
  }
}
VICBLESS_EOF

cat > src/components/Socials.jsx <<'VICBLESS_EOF'
import { SOCIAL } from '../config.js'

export function TikTokIcon() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
      <path
        fill="currentColor"
        d="M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11 1.04-1.36 1.75-.21.51-.15 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01-4.03-.01-8.05.02-12.07z"
      />
    </svg>
  )
}

export function InstagramIcon() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
      <rect x="3" y="3" width="18" height="18" rx="5" fill="none" stroke="currentColor" strokeWidth="2" />
      <circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" strokeWidth="2" />
      <circle cx="17.3" cy="6.7" r="1.2" fill="currentColor" />
    </svg>
  )
}

export default function Socials() {
  return (
    <div className="socials">
      <a
        className="social"
        href={SOCIAL.tiktok}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Vicbless on TikTok (opens in a new tab)"
      >
        <TikTokIcon />
      </a>
      <a
        className="social"
        href={SOCIAL.instagram}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Vicbless on Instagram (opens in a new tab)"
      >
        <InstagramIcon />
      </a>
    </div>
  )
}
VICBLESS_EOF

cat > src/components/SiteMenu.jsx <<'VICBLESS_EOF'
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

export default function SiteMenu() {
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
      </div>
    </div>
  )
}
VICBLESS_EOF

cat > src/components/SiteHeader.jsx <<'VICBLESS_EOF'
import Logo from './Logo.jsx'
import SiteMenu from './SiteMenu.jsx'
import Socials from './Socials.jsx'
import { getSettings } from '../lib/useSettings.js'

// Stays pinned to the top while the page scrolls (see .brand in styles.css).
// Menu on the left, logo in the middle, social links on the right.
// The logo scrolls back to the top of the page (jumps instead of gliding when motion is off).
function goToTop(e) {
  e.preventDefault()
  window.scrollTo({ top: 0, behavior: getSettings().motion === 'off' ? 'auto' : 'smooth' })
}

export default function SiteHeader() {
  return (
    <header className="brand">
      <SiteMenu />
      <Logo onClick={goToTop} />
      <Socials />
    </header>
  )
}
VICBLESS_EOF

cat > src/components/Reveal.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import { getSettings } from '../lib/useSettings.js'

// Fades and moves its content in once it scrolls into view.
//   from="below" (default) lifts up into place, from="above" drops down into place.
// Shows immediately when the browser has no IntersectionObserver or Motion is off in the
// settings (which starts from the visitor's system setting), so nothing is left hidden.
export default function Reveal({ as: Tag = 'div', from = 'below', delay = 0, className = '', children, ...rest }) {
  const ref = useRef(null)
  const [shown, setShown] = useState(
    () => typeof window === 'undefined' || !('IntersectionObserver' in window) || getSettings().motion === 'off',
  )

  useEffect(() => {
    if (shown) return undefined
    const el = ref.current
    if (!el) return undefined
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setShown(true)
          io.disconnect()
        }
      },
      { threshold: 0.15, rootMargin: '0px 0px -8% 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [shown])

  const classes = ['reveal', from === 'above' ? 'reveal-down' : '', shown ? 'in' : '', className]
    .filter(Boolean)
    .join(' ')

  return (
    <Tag ref={ref} className={classes} style={{ '--d': `${delay}ms` }} {...rest}>
      {children}
    </Tag>
  )
}
VICBLESS_EOF

cat > src/components/Statement.jsx <<'VICBLESS_EOF'
import { useEffect, useRef } from 'react'
import Reveal from './Reveal.jsx'
import { STATEMENT } from '../config.js'
import { useSettings } from '../lib/useSettings.js'

// Photo section with its own parallax. --pan goes 0 to 1 as the section travels from
// entering the bottom of the screen to leaving the top, and slides the (taller) photo
// through the section. Skipped when Motion is off, which leaves the photo centred.
export default function Statement() {
  const ref = useRef(null)
  const { motion } = useSettings()

  useEffect(() => {
    const el = ref.current
    if (!el || motion === 'off') return undefined

    let frame = 0
    const update = () => {
      frame = 0
      const rect = el.getBoundingClientRect()
      const vh = window.innerHeight
      const p = Math.min(1, Math.max(0, (vh - rect.top) / (vh + rect.height)))
      el.style.setProperty('--pan', p.toFixed(3))
    }
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update)
    }

    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (frame) window.cancelAnimationFrame(frame)
      el.style.removeProperty('--pan')
    }
  }, [motion])

  const last = STATEMENT.words.length - 1

  return (
    <section ref={ref} className="statement" aria-labelledby="statement-title">
      <img
        className="statement-img"
        src="/media/vicbless-cutting-hair.jpg"
        alt="A barber trimming a customer's hair at Vicbless Barbershop"
        loading="lazy"
        decoding="async"
      />

      <div className="statement-inner">
        <div className="statement-top">
          <Reveal as="h2" id="statement-title">
            {STATEMENT.headline}
          </Reveal>
          <Reveal as="p" delay={120}>
            {STATEMENT.body}
          </Reveal>
        </div>

        <ul className="statement-words">
          {STATEMENT.words.map((word, i) => (
            <Reveal as="li" from="above" delay={i * 180} key={word} className={i === last ? 'statement-place' : ''}>
              {word}
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  )
}
VICBLESS_EOF

cat > src/pages/Home.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import SiteHeader from '../components/SiteHeader.jsx'
import SiteFooter from '../components/SiteFooter.jsx'
import ShopInfo from '../components/ShopInfo.jsx'
import Statement from '../components/Statement.jsx'
import { useSettings } from '../lib/useSettings.js'
import Socials from '../components/Socials.jsx'
import { CTA_TEXT } from '../config.js'

const PlayIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M8 5v14l11-7z" fill="currentColor" />
  </svg>
)

const PauseIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor" />
  </svg>
)

// The pan finishes after the visitor has scrolled 85% of the video's height,
// so the movement reads as stronger and faster.
const PAN_DISTANCE = 0.85

export default function Home() {
  const reduceMotion = useSettings().motion === 'off'
  const heroRef = useRef(null)
  const videoRef = useRef(null)
  const [playing, setPlaying] = useState(false)

  // Keep the button in step with the real video state (autoplay can be blocked).
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    const sync = () => setPlaying(!v.paused)
    v.addEventListener('play', sync)
    v.addEventListener('pause', sync)
    sync()
    return () => {
      v.removeEventListener('play', sync)
      v.removeEventListener('pause', sync)
    }
  }, [])

  // Autoplay, including on iPhone. React does not write the muted attribute that iOS
  // wants before it will autoplay, so set it on the element and call play() ourselves.
  // If the phone still blocks it (Low Power Mode, for example), the first touch or
  // scroll starts it. The pause/play button is left alone so it never fights itself.
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    v.muted = true
    v.defaultMuted = true
    v.setAttribute('muted', '')

    const events = ['touchstart', 'pointerdown', 'scroll', 'keydown']
    const stopWaiting = () => events.forEach((name) => window.removeEventListener(name, onGesture))
    const attempt = () => {
      const result = v.play()
      if (result && typeof result.then === 'function') result.then(stopWaiting).catch(() => {})
      else stopWaiting()
    }
    function onGesture(e) {
      if (e.target instanceof Element && e.target.closest('.hero-toggle')) return
      attempt()
    }

    events.forEach((name) => window.addEventListener(name, onGesture, { passive: true }))
    attempt()
    return stopWaiting
  }, [])

  // Pan: as the page scrolls, the footage slides from its top to its bottom
  // (--pan goes 0 to 1 over the first 85% of the hero's height of scrolling). Skipped when Motion is off.
  useEffect(() => {
    if (reduceMotion) return undefined
    const hero = heroRef.current
    if (!hero) return undefined
    let frame = 0
    const update = () => {
      frame = 0
      const h = hero.offsetHeight || 1
      const p = Math.min(1, Math.max(0, window.scrollY / (h * PAN_DISTANCE)))
      hero.style.setProperty('--pan', p.toFixed(3))
    }
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (frame) window.cancelAnimationFrame(frame)
      hero.style.removeProperty('--pan')
    }
  }, [reduceMotion])

  function toggle() {
    const v = videoRef.current
    if (!v) return
    if (v.paused) v.play().catch(() => {})
    else v.pause()
  }

  return (
    <>
      <SiteHeader />

      <main>
        <section ref={heroRef} className="hero" aria-label="Vicbless presentation">
          <img className="hero-backdrop" src="/media/vicbless-poster.jpg" alt="" aria-hidden="true" />
          <video
            ref={videoRef}
            className="hero-video"
            src="/media/vicbless-presentation.mp4"
            poster="/media/vicbless-poster.jpg"
            muted
            loop
            playsInline
            preload="auto"
            autoPlay
            aria-label="Vicbless presentation video"
          />

          <div className="hero-cta">
            <a className="btn btn-primary book-now" href="#/book">
              {CTA_TEXT}
            </a>
          </div>

          <div className="hero-socials">
            <Socials />
          </div>

          <button
            type="button"
            className="hero-toggle"
            onClick={toggle}
            aria-label={playing ? 'Pause video' : 'Play video'}
          >
            {playing ? <PauseIcon /> : <PlayIcon />}
          </button>
        </section>

        <Statement />

        <ShopInfo />
      </main>

      <SiteFooter />
    </>
  )
}
VICBLESS_EOF

cat > src/styles.css <<'VICBLESS_EOF'
/* Vicbless: dark purple-black ground, light lavender ink, small purple accents. */
:root {
  --bg: #0a0612;
  --surface: #130c21;
  --ink: #f6efff;
  --muted: #b3a5c9;
  --line: #2f2347;
  --purple: #a855f7;
  --accent: #c084fc;
  --on-accent: #0a0612;
  --danger: #ff8aa0;
  --header-bg: rgba(10, 6, 18, 0.92);
  /* Text and accent that sit on top of photos and video. Always light, in either theme. */
  --on-media: #f6efff;
  --accent-media: #c084fc;
  --font: 'Archivo', 'Arial Narrow', system-ui, -apple-system, 'Segoe UI', sans-serif;
  color-scheme: dark;
}

/* Light theme. Switched with the Dark mode setting (see src/lib/settings.js). */
html[data-theme='light'] {
  --bg: #f8f4fd;
  --surface: #ffffff;
  --ink: #1b1030;
  --muted: #5a4a73;
  --line: #ddd0ee;
  --purple: #7e22ce;
  --accent: #7c3aed;
  --on-accent: #ffffff;
  --danger: #b3123b;
  --header-bg: rgba(248, 244, 253, 0.92);
  color-scheme: light;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font);
  font-size: 1rem;
  line-height: 1.5;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

button,
input,
textarea {
  font: inherit;
  color: inherit;
}

button {
  cursor: pointer;
}

:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- Home: pinned logo bar, video hero, shop info, footer ---------- */
:root {
  --brand-h: calc(84px + env(safe-area-inset-top, 0px));
}

/* Logo bar. Sticky, so it follows the page while scrolling. The logo sits in the
   middle column and the social links on the right. */
.brand {
  position: sticky;
  top: 0;
  z-index: 10;
  height: var(--brand-h);
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  padding: env(safe-area-inset-top, 0px) 16px 0;
  background: var(--header-bg);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}

.logo {
  margin: 0;
  width: min(100%, 880px);
}

.brand .logo {
  grid-column: 2;
  width: auto;
  height: 60px;
}

.logo svg {
  display: block;
  width: 100%;
  height: auto;
  filter: drop-shadow(0 0 3px var(--purple));
}

.brand .logo svg {
  width: auto;
  height: 100%;
}

.logo-link {
  display: block;
  height: 100%;
  color: inherit;
  border-radius: 6px;
}

.logo path {
  fill: var(--ink);
  stroke: var(--purple);
  stroke-width: 6;
  stroke-linejoin: round;
  paint-order: stroke;
}

.brand .socials {
  grid-column: 3;
  justify-self: end;
}

.socials {
  display: flex;
  align-items: center;
  gap: 2px;
}

.social {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  color: var(--ink);
  border-radius: 50%;
}

.social:hover {
  color: var(--accent);
}

/* The hero fills whatever is left of the first screen under the pinned bar. */
.hero {
  position: relative;
  height: calc(100vh - var(--brand-h));
  height: calc(100svh - var(--brand-h));
  min-height: 440px;
  overflow: hidden;
  background: var(--bg);
}

/* Blurred, dimmed poster fills the sides when the screen is wider than the video. */
.hero-backdrop {
  position: absolute;
  top: -48px;
  left: -48px;
  width: calc(100% + 96px);
  height: calc(100% + 96px);
  object-fit: cover;
  filter: blur(36px) brightness(0.5) saturate(1.2);
}

.hero-video {
  position: absolute;
  top: 0;
  left: 50%;
  /* Much taller than the window (165%): --pan (0 to 1, set while scrolling) slides the
     footage up through the extra 65% (that is 39.4% of the video's own height), so the
     view travels from the top of the video to the bottom. */
  transform: translate3d(-50%, calc(var(--pan, 0) * -39.4%), 0);
  will-change: transform;
  height: 165%;
  width: auto;
  max-width: 100%;
  aspect-ratio: 720 / 1084;
  object-fit: cover;
  background: var(--surface);
}

/* Soft shade behind the button so it reads over any frame of the video. */
.hero::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse 60% 40% at 50% 50%, rgba(10, 6, 18, 0.55), rgba(10, 6, 18, 0) 70%);
}

.hero-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  pointer-events: none;
}

.hero .book-now {
  pointer-events: auto;
  max-width: min(88vw, 460px);
  padding: 20px 44px;
  font-size: clamp(1.15rem, 4.6vw, 1.5rem);
  line-height: 1.15;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  animation: ring 2.8s ease-out infinite;
}

@keyframes ring {
  0% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  }
  70%,
  100% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 22px rgba(192, 132, 252, 0);
  }
}

.hero-toggle {
  position: absolute;
  right: 14px;
  bottom: 14px;
  z-index: 2;
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--on-media);
  background: rgba(10, 6, 18, 0.6);
  border: 2px solid rgba(246, 239, 255, 0.7);
  border-radius: 50%;
}

.hero-toggle:hover {
  border-color: var(--on-media);
}

.info {
  max-width: 960px;
  margin: 0 auto;
  padding: 72px 20px 48px;
}

.info-grid {
  display: grid;
  grid-template-columns: 1.2fr 1fr;
  gap: 48px;
}

.info h2 {
  margin: 0 0 14px;
  font-size: 1.5rem;
  font-weight: 800;
  font-variation-settings: 'wdth' 85;
}

.menu,
.hours {
  margin: 0 0 32px;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.menu li {
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
}

.menu-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.menu-name {
  font-weight: 700;
}

.menu-leader {
  flex: 1;
  min-width: 12px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.menu-price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.menu-meta {
  margin: 2px 0 0;
  font-size: 0.9rem;
  color: var(--muted);
}

.hours li {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
}

.hours li span:last-child {
  text-align: right;
}

.hours .closed {
  color: var(--muted);
}

.info address {
  font-style: normal;
  color: var(--muted);
}

.info-cta {
  display: flex;
  justify-content: center;
  margin-top: 40px;
}

.site-foot {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 32px 20px calc(36px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.9rem;
}

.site-foot .copy {
  margin: 0;
  font-weight: 700;
  letter-spacing: 0.04em;
}

/* Social links along the bottom of the video. */
.hero-socials {
  position: absolute;
  left: 50%;
  bottom: 14px;
  z-index: 2;
  transform: translateX(-50%);
}

.hero-socials .socials {
  padding: 2px 8px;
  background: rgba(10, 6, 18, 0.6);
  border: 1px solid rgba(246, 239, 255, 0.25);
  border-radius: 999px;
}

.hero-socials .social {
  color: var(--on-media);
}

.hero-socials .social:hover {
  color: var(--accent-media);
}

/* Scroll reveal: content below the video fades up as it enters the screen. */
.reveal {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0.7, 0.2, 1);
  transition-delay: var(--d, 0ms);
}

.reveal.in {
  opacity: 1;
  transform: none;
}

/* Branded CTA on each haircut type: a purple box, matching the other booking buttons. */
.svc-cta {
  display: inline-block;
  margin-top: 12px;
  padding: 12px 24px;
  font-weight: 800;
  text-align: center;
  color: var(--on-accent);
  text-decoration: none;
  background: var(--accent);
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.svc-cta:hover {
  filter: brightness(1.08);
}

/* Menu: three-line button on the left of the pinned bar, opens a panel under it. */
.brand .site-menu {
  grid-column: 1;
  justify-self: start;
}

.menu-toggle {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--ink);
  background: none;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.menu-toggle:hover {
  border-color: var(--accent);
}

/* The bar is the positioned parent, so the panel hangs just under it. */
.menu-panel {
  position: absolute;
  top: calc(100% + 6px);
  left: 12px;
  z-index: 20;
  width: min(330px, calc(100vw - 24px));
  max-height: calc(100vh - var(--brand-h) - 24px);
  max-height: calc(100svh - var(--brand-h) - 24px);
  padding: 8px;
  overflow-y: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.45);
}

.menu-group + .menu-group {
  margin-top: 4px;
}

.menu-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  font-size: 1.05rem;
  font-weight: 800;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.menu-head:hover {
  background: var(--bg);
}

.menu-head .chev {
  transition: transform 0.2s ease;
}

.menu-head[aria-expanded='true'] .chev {
  transform: rotate(180deg);
}

.menu-sub {
  padding: 2px 4px 8px;
}

.menu-link {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 48px;
  padding: 10px 12px;
  font-weight: 600;
  color: var(--ink);
  text-decoration: none;
  border-radius: 8px;
}

.menu-link:hover {
  color: var(--accent);
  background: var(--bg);
}

.setting {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  min-height: 56px;
  padding: 8px 12px;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.setting:hover {
  background: var(--bg);
}

.setting-text {
  display: flex;
  flex: 1;
  flex-direction: column;
}

.setting-label {
  font-weight: 700;
}

.setting-hint {
  font-size: 0.82rem;
  color: var(--muted);
}

.switch-state {
  min-width: 2em;
  font-size: 0.9rem;
  font-weight: 700;
  text-align: right;
  color: var(--muted);
}

.switch-track {
  position: relative;
  flex: none;
  width: 46px;
  height: 26px;
  background: var(--line);
  border: 2px solid var(--line);
  border-radius: 999px;
  transition: background 0.2s ease, border-color 0.2s ease;
}

.switch-track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 18px;
  height: 18px;
  background: var(--ink);
  border-radius: 50%;
  transition: transform 0.2s ease;
}

.setting[aria-checked='true'] .switch-track {
  background: var(--accent);
  border-color: var(--accent);
}

.setting[aria-checked='true'] .switch-track::after {
  background: var(--on-accent);
  transform: translateX(20px);
}

/* Words that drop down into place instead of lifting up. */
.reveal-down {
  transform: translateY(-28px);
}

/* Photo section under the video. The photo is 130% of the section's height and slides
   through it with --pan (see Statement.jsx), so it has its own parallax. The headline sits
   at the top and the stacked words at the bottom, which keeps the faces clear in the middle. */
.statement {
  position: relative;
  color: var(--on-media);
  display: flex;
  min-height: 780px;
  min-height: max(780px, 100svh);
  padding: 56px 20px 48px;
  overflow: hidden;
  background: var(--bg);
}

.statement-img {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 130%;
  object-fit: cover;
  object-position: 20% 50%;
  transform: translate3d(0, calc(var(--pan, 0.5) * -23.1%), 0);
  will-change: transform;
}

/* Darkens the top and bottom where the text sits, leaves the middle (the faces) clear. */
.statement::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(
    to bottom,
    rgba(10, 6, 18, 0.78) 0%,
    rgba(10, 6, 18, 0.35) 28%,
    rgba(10, 6, 18, 0) 45%,
    rgba(10, 6, 18, 0) 55%,
    rgba(10, 6, 18, 0.55) 72%,
    rgba(10, 6, 18, 0.9) 100%
  );
}

.statement-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 32px;
  width: 100%;
  max-width: 1100px;
  margin: 0 auto;
}

.statement h2 {
  max-width: 18ch;
  margin: 0 0 14px;
  font-size: clamp(1.5rem, 5.2vw, 2.6rem);
  font-weight: 900;
  line-height: 1.08;
  letter-spacing: 0.01em;
  font-variation-settings: 'wdth' 85;
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.6);
}

.statement p {
  max-width: 44ch;
  margin: 0;
  font-size: clamp(1rem, 2.6vw, 1.2rem);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.7);
}

.statement-words {
  margin: 0;
  padding: 0;
  list-style: none;
}

.statement-words li {
  font-size: clamp(2.7rem, 13vw, 6.8rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-shadow: 0 4px 24px rgba(0, 0, 0, 0.55);
}

.statement-words .statement-place {
  color: var(--accent-media);
}

@media (min-width: 900px) {
  .statement {
    min-height: max(720px, 90svh);
  }

  /* On wide screens the words sit on the left, so shade the left side as well. */
  .statement::after {
    background: linear-gradient(90deg, rgba(10, 6, 18, 0.75) 0%, rgba(10, 6, 18, 0.4) 40%, rgba(10, 6, 18, 0) 70%),
      linear-gradient(
        to bottom,
        rgba(10, 6, 18, 0.6) 0%,
        rgba(10, 6, 18, 0) 30%,
        rgba(10, 6, 18, 0) 60%,
        rgba(10, 6, 18, 0.7) 100%
      );
  }
}

@media (max-width: 760px) {
  .info-grid {
    grid-template-columns: 1fr;
    gap: 36px;
  }
}

@media (max-width: 520px) {
  .hero .book-now {
    padding: 16px 32px;
  }
}

/* Motion off: the Motion setting (which starts from the visitor's system setting). */
html[data-motion='off'] .hero .book-now {
  animation: none;
}

html[data-motion='off'] .reveal,
html[data-motion='off'] .reveal-down {
  opacity: 1;
  transform: none;
  transition: none;
}

html[data-motion='off'] .chev,
html[data-motion='off'] .switch-track,
html[data-motion='off'] .switch-track::after {
  transition: none;
}

/* ---------- Buttons ---------- */
.btn {
  display: inline-block;
  padding: 13px 24px;
  border: 2px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--ink);
  font-weight: 700;
  text-align: center;
  text-decoration: none;
}

.btn:not(:disabled):hover {
  border-color: var(--accent);
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.btn-primary:not(:disabled):hover {
  filter: brightness(1.08);
}

.book-now {
  padding: 18px 64px;
  border-radius: 999px;
  font-size: 1.35rem;
  font-weight: 800;
  letter-spacing: 0.01em;
}

/* ---------- Booking ---------- */
.book {
  max-width: 640px;
  margin: 0 auto;
  padding: calc(24px + env(safe-area-inset-top, 0px)) 20px 72px;
}

.back {
  display: inline-block;
  margin-bottom: 8px;
  color: var(--muted);
  text-decoration: none;
  padding: 6px 0;
}

.back:hover {
  color: var(--ink);
}

.book-title {
  margin: 0 0 20px;
  font-size: clamp(2rem, 7vw, 2.8rem);
  font-weight: 900;
  line-height: 1.05;
  font-variation-settings: 'wdth' 85;
}

.steps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.steps button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: none;
  border: 2px solid var(--line);
  border-radius: 999px;
  color: var(--muted);
  font-weight: 600;
  font-size: 0.92rem;
}

.steps button[aria-current='step'] {
  border-color: var(--accent);
  color: var(--ink);
}

.steps button.done {
  color: var(--ink);
}

.steps button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.steps .n {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--line);
  font-size: 0.8rem;
}

.steps [aria-current='step'] .n {
  background: var(--accent);
  color: var(--on-accent);
}

.panel {
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
  padding: 22px;
}

.panel h2 {
  margin: 0 0 16px;
  font-size: 1.4rem;
  font-weight: 800;
}

.opt {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  width: 100%;
  margin-bottom: 10px;
  padding: 14px;
  text-align: left;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.opt:hover {
  border-color: var(--accent);
}

.opt[aria-pressed='true'] {
  border-color: var(--accent);
  box-shadow: inset 4px 0 0 var(--accent);
}

.opt .name {
  font-weight: 700;
}

.opt .meta {
  color: var(--muted);
  font-size: 0.9rem;
}

.opt .leader {
  flex: 1;
  min-width: 16px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.opt .price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.opt .note {
  flex-basis: 100%;
  margin-top: 2px;
  font-size: 0.88rem;
  font-weight: 400;
  color: var(--muted);
}

.days {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 2px 2px 12px;
  overflow-x: auto;
}

.day {
  flex: none;
  width: 72px;
  padding: 10px 6px;
  text-align: center;
  line-height: 1.2;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.day .dow {
  display: block;
  font-size: 0.85rem;
  color: var(--muted);
}

.day .dom {
  display: block;
  font-size: 1.4rem;
  font-weight: 800;
}

.day .tag {
  display: block;
  min-height: 1em;
  font-size: 0.75rem;
  color: var(--muted);
}

.day[aria-pressed='true'] {
  border-color: var(--accent);
}

.day:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(98px, 1fr));
  gap: 8px;
  margin: 12px 0 4px;
}

.time {
  padding: 10px 6px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.time:hover {
  border-color: var(--accent);
}

.time[aria-pressed='true'] {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.empty {
  padding: 18px;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

.summary {
  margin: 0 0 20px;
  padding: 14px 16px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.summary div + div {
  margin-top: 10px;
}

.summary dt {
  font-size: 0.85rem;
  color: var(--muted);
}

.summary dd {
  margin: 0;
  font-weight: 600;
}

.field {
  margin-bottom: 14px;
}

.field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}

.field input,
.field textarea {
  width: 100%;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.field input:focus,
.field textarea:focus {
  border-color: var(--accent);
}

.field input[aria-invalid='true'] {
  border-color: var(--danger);
}

.hint {
  font-weight: 400;
  font-size: 0.85rem;
  color: var(--muted);
}

.err {
  min-height: 1.3em;
  margin: 4px 0 0;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--danger);
}

.notice {
  margin: 0 0 16px;
  padding: 12px 14px;
  font-weight: 600;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.muted {
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 20px;
}

.done {
  padding-top: 24px;
}

.done p {
  margin: 0 0 8px;
}

.code {
  display: inline-block;
  margin: 4px 0 16px !important;
  padding: 6px 14px;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.done .btn {
  margin-top: 16px;
}

@media (max-width: 520px) {
  .book-now {
    padding: 16px 48px;
  }
  .panel {
    padding: 16px;
  }
}

html[data-motion='off'] {
  scroll-behavior: auto;
}
VICBLESS_EOF

echo ""
echo "Files updated. Running tests..."
npm test
echo ""
echo "Next: npm run dev -- --host"
echo ""
echo "Git commands (not run for you):"
echo "  git add -A"
echo "  git commit -m \"Add menu with socials and settings, motion and dark/light mode toggles\""
echo "  git push"
