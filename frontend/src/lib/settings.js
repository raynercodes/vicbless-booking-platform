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
