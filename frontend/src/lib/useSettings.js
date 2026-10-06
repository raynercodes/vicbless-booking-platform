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
