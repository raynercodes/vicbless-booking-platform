// MOCK customer data layer, used by npm run dev and the tests (see api.js and mode.js). The real one is realApi.js.
//
//   getAvailability(dateKeys) -> GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD
//        { '2026-10-09': { busy: [660, 695], dayOff: false }, ... }  taken times, and whether the day is off
//   getShopSettings()   -> GET /settings   { services, slotMinutes: { mon: 45, ... } }
//   createBooking(data) ->  POST /bookings   (return 409 when the slot is taken)
//
// Keep the same return shapes and the pages will not need to change.
// Until then it fakes busy times per day and keeps bookings, blocked time and cancelled
// sample bookings in localStorage (through mockStore.js), so a booked, blocked or freed time
// shows up on the customer grid and in Vic's dashboard alike.

import { HOURS } from '../config.js'
import { SlotTakenError } from './errors.js'
import { DAY_KEYS } from './shopSettings.js'
import { fromKey, slotStarts } from './availability.js'
import {
  blockedStartsFor,
  isDayOff,
  overlaps,
  readBookings,
  readCancelledSamples,
  readShopSettings,
  slotMinutesOn,
  writeBookings,
} from './mockStore.js'

const delay = (ms) => new Promise((r) => setTimeout(r, ms))

// SlotTakenError lives in errors.js, shared with the real data layer.

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

function busyFor(dateKey) {
  const busy = new Set()
  const slot = slotMinutesOn(dateKey) // how long an appointment is on this day right now

  // pretend-busy blocks, unless Vic cancelled them in the dashboard
  const cancelled = new Set(readCancelledSamples().filter((c) => c.dateKey === dateKey).map((c) => c.start))
  for (const s of slotStarts(fromKey(dateKey), HOURS, slot)) {
    if (hash(dateKey + s) % 100 < 30 && !cancelled.has(s)) busy.add(s)
  }

  // real bookings made through the site: every appointment start they overlap is taken, whatever length they had
  const bookings = readBookings().filter((b) => b.dateKey === dateKey)
  for (const s of slotStarts(fromKey(dateKey), HOURS, slot)) {
    if (bookings.some((b) => overlaps(s, s + slot, b.start, b.start + b.minutes))) busy.add(s)
  }

  // time Vic blocked off
  for (const s of blockedStartsFor(dateKey)) busy.add(s)

  return [...busy]
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off (shown to customers as "Closed" instead of "Full").
export async function getAvailability(dateKeys) {
  await delay(150)
  return Object.fromEntries(dateKeys.map((k) => [k, { busy: busyFor(k), dayOff: isDayOff(k), slotMinutes: slotMinutesOn(k) }]))
}

// Just the taken times, for code that does not care about days off (the admin mock).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

// The services and appointment lengths, in the API's shape. In the mock they are kept in this browser.
export async function getShopSettings() {
  await delay(100)
  const settings = readShopSettings()
  return {
    services: settings.services.map((s) => ({ id: s.id, name: s.name, price: s.price, from: s.from, note: s.note })),
    slotMinutes: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.slotMinutes[day]])),
    reminderHours: settings.reminderHours,
  }
}

export async function createBooking(payload) {
  await delay(500)
  const slot = slotMinutesOn(payload.dateKey)
  if (busyFor(payload.dateKey).includes(payload.start) || !slotStarts(fromKey(payload.dateKey), HOURS, slot).includes(payload.start)) {
    throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  // The service's name is kept with the booking, like the real backend does, so a later rename does not change it.
  const service = readShopSettings().services.find((s) => s.id === payload.serviceId)
  const booking = { ...payload, minutes: slot, serviceName: service ? service.name : '', code }
  writeBookings([...readBookings(), booking])
  return booking
}
