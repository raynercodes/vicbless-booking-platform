// Mock data layer. This is the ONLY file to replace when the backend exists.
//
//   getAvailability(dateKeys) -> GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD
//        { '2026-10-09': { busy: [660, 695], dayOff: false }, ... }  taken times, and whether the day is off
//   createBooking(data) ->  POST /bookings   (return 409 when the slot is taken)
//
// Keep the same return shapes and the pages will not need to change.
// Until then it fakes busy times per day and keeps bookings, blocked time and cancelled
// sample bookings in localStorage (through mockStore.js), so a booked, blocked or freed time
// shows up on the customer grid and in Vic's dashboard alike.

import { HOURS, SLOT_MINUTES } from '../config.js'
import { blocksFor, fromKey, slotStarts } from './availability.js'
import { blockedStartsFor, isDayOff, readBookings, readCancelledSamples, writeBookings } from './mockStore.js'

const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export class SlotTakenError extends Error {
  constructor() {
    super('That time was just taken.')
    this.name = 'SlotTakenError'
  }
}

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

  // pretend-busy blocks, unless Vic cancelled them in the dashboard
  const cancelled = new Set(readCancelledSamples().filter((c) => c.dateKey === dateKey).map((c) => c.start))
  for (const s of slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)) {
    if (hash(dateKey + s) % 100 < 30 && !cancelled.has(s)) busy.add(s)
  }

  // real bookings made through the site
  for (const b of readBookings()) {
    if (b.dateKey !== dateKey) continue
    for (let k = 0; k < blocksFor(b.minutes, SLOT_MINUTES); k++) busy.add(b.start + k * SLOT_MINUTES)
  }

  // time Vic blocked off
  for (const s of blockedStartsFor(dateKey)) busy.add(s)

  return [...busy]
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off (shown to customers as "Closed" instead of "Full").
export async function getAvailability(dateKeys) {
  await delay(150)
  return Object.fromEntries(dateKeys.map((k) => [k, { busy: busyFor(k), dayOff: isDayOff(k) }]))
}

// Just the taken times, for code that does not care about days off (the admin mock).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

export async function createBooking(payload) {
  await delay(500)
  const busy = new Set(busyFor(payload.dateKey))
  for (let k = 0; k < blocksFor(payload.minutes, SLOT_MINUTES); k++) {
    if (busy.has(payload.start + k * SLOT_MINUTES)) throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  const booking = { ...payload, code }
  writeBookings([...readBookings(), booking])
  return booking
}
