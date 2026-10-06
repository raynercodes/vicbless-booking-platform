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
