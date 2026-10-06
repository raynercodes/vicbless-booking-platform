// Mock data layer. This is the ONLY file to replace when the backend exists.
//
//   getBusy(dateKeys)   ->  GET  /availability?from=YYYY-MM-DD&to=YYYY-MM-DD
//   createBooking(data) ->  POST /bookings   (return 409 when the slot is taken)
//
// Keep the same return shapes and the pages will not need to change.
// Until then it fakes busy times per day and stores new bookings in
// localStorage so a booked time disappears from the grid.

import { HOURS, SLOT_MINUTES } from '../config.js'
import { blocksFor, fromKey, slotStarts } from './availability.js'

const STORAGE_KEY = 'vicbless.bookings'
const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export class SlotTakenError extends Error {
  constructor() {
    super('That time was just taken.')
    this.name = 'SlotTakenError'
  }
}

function load() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]')
  } catch {
    return []
  }
}

function save(list) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(list))
  } catch {
    /* storage unavailable, ignore */
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
  for (const s of slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)) {
    if (hash(dateKey + s) % 100 < 30) busy.add(s)
  }
  for (const b of load()) {
    if (b.dateKey !== dateKey) continue
    for (let k = 0; k < blocksFor(b.minutes, SLOT_MINUTES); k++) busy.add(b.start + k * SLOT_MINUTES)
  }
  return [...busy]
}

export async function getBusy(dateKeys) {
  await delay(150)
  return Object.fromEntries(dateKeys.map((k) => [k, busyFor(k)]))
}

export async function createBooking(payload) {
  await delay(500)
  const busy = new Set(busyFor(payload.dateKey))
  for (let k = 0; k < blocksFor(payload.minutes, SLOT_MINUTES); k++) {
    if (busy.has(payload.start + k * SLOT_MINUTES)) throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  const booking = { ...payload, code }
  save([...load(), booking])
  return booking
}
