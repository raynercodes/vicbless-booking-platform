// Vic's shop settings: the services with their prices, and how long an appointment is on each weekday.
//
// The real values live in the database (Vic edits them in his dashboard). This file holds the pure helpers that
// turn what the API sends into what the screens use, check what Vic typed, and a tiny shared store so every page
// sees the same settings. Nothing here talks to the network except loadShopSettings().
//
// Shape used by the screens ("settings"):
//   { services: [{ id, name, price, from, note }], slotMinutes: { 0: 35, 1: 45, ... 6: 35 }, reminderHours: [24, 2] }
//   (0 = Sunday; reminderHours = how many hours before an appointment a reminder goes out, biggest first)
// The API uses weekday names instead of numbers ({ mon: 45 }); fromApi / toApi convert.

import {
  MAX_SERVICES,
  REMINDER_CHOICES,
  REMINDER_HOURS_DEFAULT,
  SERVICES,
  SLOT_MAX,
  SLOT_MIN,
  SLOT_MINUTES_BY_DAY,
  SLOT_STEP,
} from '../config.js'

// Index = JavaScript's Date.getDay() (0 is Sunday). The API uses these same short names.
export const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']
export const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

// Limits Vic's typing is checked against. The API enforces the same ones (a backend test compares them).
export const NAME_MIN = 2
export const NAME_MAX = 60
export const NOTE_MAX = 120
export const PRICE_MAX = 999

// The shop's starting values: used until the API answers, and if it never does.
export const DEFAULT_SHOP_SETTINGS = Object.freeze({
  services: SERVICES.map((s) => ({ id: s.id, name: s.name, price: s.price, from: !!s.from, note: s.note || '' })),
  slotMinutes: { ...SLOT_MINUTES_BY_DAY },
  reminderHours: [...REMINDER_HOURS_DEFAULT],
})

// Reminder times, biggest first, only ones Vic is allowed to pick, each once.
const cleanHours = (list) => [...new Set(list)].filter((h) => REMINDER_CHOICES.includes(h)).sort((a, b) => b - a)

const isLength = (n) => Number.isInteger(n) && n >= SLOT_MIN && n <= SLOT_MAX && n % SLOT_STEP === 0

// What the API sent -> what the screens use. Anything malformed gives null (the caller keeps what it had).
export function fromApi(raw) {
  if (!raw || !Array.isArray(raw.services) || !raw.slotMinutes || typeof raw.slotMinutes !== 'object') return null
  const services = []
  for (const s of raw.services) {
    if (!s || typeof s.id !== 'string' || typeof s.name !== 'string' || !Number.isInteger(s.price)) return null
    services.push({ id: s.id, name: s.name, price: s.price, from: !!s.from, note: typeof s.note === 'string' ? s.note : '' })
  }
  if (services.length === 0) return null
  const slotMinutes = {}
  for (let day = 0; day < 7; day++) {
    const minutes = raw.slotMinutes[DAY_KEYS[day]]
    if (!isLength(minutes)) return null
    slotMinutes[day] = minutes
  }
  // An answer from before reminders existed has no list: keep the starting one.
  let reminderHours = [...REMINDER_HOURS_DEFAULT]
  if (raw.reminderHours !== undefined) {
    if (!Array.isArray(raw.reminderHours) || !raw.reminderHours.every((h) => REMINDER_CHOICES.includes(h))) return null
    reminderHours = cleanHours(raw.reminderHours)
  }
  return { services, slotMinutes, reminderHours }
}

// What the screens hold -> what the API wants. A service without an id (a new one) is sent without it.
export function toApi(settings) {
  return {
    services: settings.services.map((s) => ({
      ...(s.id ? { id: s.id } : {}),
      name: s.name,
      price: s.price,
      from: !!s.from,
      note: s.note || '',
    })),
    slotMinutes: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.slotMinutes[day]])),
    reminderHours: cleanHours(settings.reminderHours),
  }
}

// How long an appointment is on `date` (a Date).
export const slotFor = (settings, date) => settings.slotMinutes[date.getDay()]

export const findService = (settings, id) => settings.services.find((s) => s.id === id) || null

// ---- the editor's draft: what Vic is typing, before it is saved ------------------------------------------------

let draftCounter = 0

// A draft keeps prices and lengths as TEXT (that is what an input holds) and gives every service row a key that
// never changes, so the row stays put while its name is edited. New rows have no id until they are saved.
export function draftFrom(settings) {
  return {
    services: settings.services.map((s) => ({
      key: s.id,
      id: s.id,
      name: s.name,
      price: String(s.price),
      from: !!s.from,
      note: s.note || '',
    })),
    slots: Object.fromEntries(Object.entries(settings.slotMinutes).map(([day, minutes]) => [day, String(minutes)])),
    reminders: cleanHours(settings.reminderHours),
  }
}

export function newDraftService() {
  draftCounter += 1
  return { key: `new-${draftCounter}`, id: '', name: '', price: '', from: false, note: '' }
}

// Switches one reminder time on or off in a draft, keeping the list biggest first.
export const toggleReminder = (draft, hours) => ({
  ...draft,
  reminders: cleanHours(draft.reminders.includes(hours) ? draft.reminders.filter((h) => h !== hours) : [...draft.reminders, hours]),
})

// Checks the draft the way the API will. Returns { ok: true, settings } or { ok: false, errors } where errors is
//   { general, services: { [key]: { name?, price?, note? } }, slots: { [day]: message } }
export function checkDraft(draft) {
  const errors = { general: '', services: {}, slots: {} }
  const services = []

  if (draft.services.length < 1 || draft.services.length > MAX_SERVICES) {
    errors.general = `List between 1 and ${MAX_SERVICES} services.`
  }

  const seen = new Set()
  for (const row of draft.services) {
    const problems = {}
    const name = row.name.trim().replace(/\s+/g, ' ')
    if (name.length < NAME_MIN || name.length > NAME_MAX) {
      problems.name = `Needs a name, ${NAME_MIN} to ${NAME_MAX} characters.`
    } else if (seen.has(name.toLowerCase())) {
      problems.name = 'Another service already has this name.'
    }
    seen.add(name.toLowerCase())

    const priceText = row.price.trim()
    const price = /^\d{1,3}$/.test(priceText) ? Number(priceText) : NaN
    if (!(price >= 0 && price <= PRICE_MAX)) problems.price = `Whole dollars, 0 to ${PRICE_MAX}.`

    if (row.note.length > NOTE_MAX) problems.note = `Up to ${NOTE_MAX} characters.`

    if (Object.keys(problems).length) errors.services[row.key] = problems
    services.push({ id: row.id, name, price, from: row.from, note: row.note.trim() })
  }

  const slotMinutes = {}
  for (let day = 0; day < 7; day++) {
    const text = String(draft.slots[day] ?? '').trim()
    const minutes = /^\d{1,3}$/.test(text) ? Number(text) : NaN
    if (!isLength(minutes)) errors.slots[day] = `${SLOT_MIN} to ${SLOT_MAX} minutes, in steps of ${SLOT_STEP}.`
    slotMinutes[day] = minutes
  }

  const bad = errors.general || Object.keys(errors.services).length || Object.keys(errors.slots).length
  return bad ? { ok: false, errors } : { ok: true, settings: { services, slotMinutes, reminderHours: cleanHours(draft.reminders) } }
}

// True when the draft differs from the saved settings (enables the Save button).
export function isChanged(draft, saved) {
  return JSON.stringify(draft) !== JSON.stringify(draftFrom(saved))
}

// ---- a tiny shared store so every page sees the same settings -------------------------------------------------

let current = DEFAULT_SHOP_SETTINGS
let loading = null
const listeners = new Set()

export const getShopSettingsNow = () => current
export const subscribeShopSettings = (fn) => {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

// Puts new settings into the store (after loading them, or after Vic saved) and tells every screen.
export function setShopSettings(settings) {
  current = settings
  for (const fn of listeners) fn()
}

// Asks the API once. `fetcher` returns the API's JSON. A failure keeps the starting values, never an error screen.
export function loadShopSettings(fetcher) {
  if (!loading) {
    loading = Promise.resolve()
      .then(fetcher)
      .then((raw) => {
        const parsed = fromApi(raw)
        if (parsed) setShopSettings(parsed)
      })
      .catch(() => {})
  }
  return loading
}

// For tests: back to the starting values.
export function resetShopSettings() {
  current = DEFAULT_SHOP_SETTINGS
  loading = null
  listeners.clear()
}
