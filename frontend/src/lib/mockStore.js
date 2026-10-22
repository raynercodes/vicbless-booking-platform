// MOCK storage shared by the customer-facing mock (lib/api.js) and the admin mock.
// It exists so that cancelling or blocking time in the dashboard changes what customers see.
// It goes away when the real backend exists.

import { fromKey, slotStarts } from './availability.js'
import { DEFAULT_SHOP_SETTINGS, fromApi, hoursFor, slotFor } from './shopSettings.js'

const KEYS = {
  bookings: 'vicbless.bookings', // bookings made through the site
  blocks: 'vicbless.blocks', // time Vic blocked off
  cancelledSamples: 'vicbless.cancelledSamples', // sample bookings Vic cancelled in the dashboard
  shopSettings: 'vicbless.shopSettings', // services, prices and appointment lengths Vic saved (API shape)
}

function read(key) {
  try {
    const list = JSON.parse(localStorage.getItem(key) || '[]')
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

function write(key, list) {
  try {
    localStorage.setItem(key, JSON.stringify(list))
  } catch {
    /* storage blocked: the change just will not survive a reload */
  }
}

export const readBookings = () => read(KEYS.bookings)
export const writeBookings = (list) => write(KEYS.bookings, list)
export const readBlocks = () => read(KEYS.blocks)
export const writeBlocks = (list) => write(KEYS.blocks, list)
export const readCancelledSamples = () => read(KEYS.cancelledSamples)
export const writeCancelledSamples = (list) => write(KEYS.cancelledSamples, list)

// The shop settings Vic saved in this browser (the services and the appointment lengths), or the starting ones.
export function readShopSettings() {
  try {
    return fromApi(JSON.parse(localStorage.getItem(KEYS.shopSettings) || 'null')) || DEFAULT_SHOP_SETTINGS
  } catch {
    return DEFAULT_SHOP_SETTINGS
  }
}

// `body` is the API shape ({ services, slotMinutes: { mon: 45 ... } }).
export function writeShopSettings(body) {
  try {
    localStorage.setItem(KEYS.shopSettings, JSON.stringify(body))
  } catch {
    /* storage blocked: the change just will not survive a reload */
  }
}

// How long an appointment is on `dateKey` right now.
export const slotMinutesOn = (dateKey) => slotFor(readShopSettings(), fromKey(dateKey))

// The opening windows right now, late appointments included (they depend on the saved settings).
export const hoursNow = () => hoursFor(readShopSettings())

// True when the times [aStart, aEnd) and [bStart, bEnd) share any minute.
export const overlaps = (aStart, aEnd, bStart, bEnd) => aStart < bEnd && bStart < aEnd

// The appointment starts on `dateKey` that touch blocked-off time.
export function blockedStartsFor(dateKey) {
  const blocks = readBlocks().filter((b) => b.dateKey === dateKey)
  const out = new Set()
  if (blocks.length === 0) return out
  const slot = slotMinutesOn(dateKey)
  for (const s of slotStarts(fromKey(dateKey), hoursNow(), slot)) {
    if (blocks.some((b) => overlaps(s, s + slot, b.start, b.end))) out.add(s)
  }
  return out
}

// True when Vic has taken the whole day off. Customers see such a day as Closed, not Full.
export function isDayOff(dateKey) {
  return readBlocks().some((b) => b.dateKey === dateKey && b.whole)
}
