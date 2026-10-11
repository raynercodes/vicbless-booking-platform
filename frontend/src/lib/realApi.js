// The real customer-facing data layer: the same functions as mockApi.js, backed by the API.
//
//   getAvailability(dateKeys) -> GET  /api/availability?from=&to=
//   createBooking(data)       -> POST /api/bookings
//
// Return shapes match the mock exactly, so the pages do not know which one they are talking to.

import { fromKey, keyOf } from './availability.js'
import { ApiError, SlotTakenError } from './errors.js'
import { request } from './http.js'

// The API answers for at most this many days per call (shop.MAX_RANGE_DAYS in the backend).
const MAX_DAYS_PER_CALL = 31

function addDays(dateKey, n) {
  const d = fromKey(dateKey)
  d.setDate(d.getDate() + n)
  return keyOf(d)
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off. One call covers the whole range; a longer range is split so the API never refuses it.
export async function getAvailability(dateKeys) {
  const keys = [...dateKeys].sort()
  const result = {}
  if (keys.length === 0) return result

  let from = keys[0]
  const last = keys[keys.length - 1]
  const calls = []
  while (from <= last) {
    const to = addDays(from, MAX_DAYS_PER_CALL - 1) < last ? addDays(from, MAX_DAYS_PER_CALL - 1) : last
    calls.push(request('GET', `/availability?from=${from}&to=${to}`))
    from = addDays(to, 1)
  }
  for (const part of await Promise.all(calls)) Object.assign(result, part)

  // A day the API says nothing about is treated as completely free, never as an error.
  return Object.fromEntries(keys.map((k) => [k, result[k] || { busy: [], dayOff: false }]))
}

// Just the taken times (the admin mock uses this one; kept so both layers have the same exports).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

// Books the time. Resolves to the booking, which has everything the "You're booked" screen shows.
// The API's answer has no name (it only returns what a stranger could safely be told), so what the
// customer typed is merged back in. The API's code/date/time win, they are what was actually saved.
export async function createBooking(payload) {
  try {
    const saved = await request('POST', '/bookings', {
      body: {
        staffId: payload.staffId,
        serviceId: payload.serviceId,
        dateKey: payload.dateKey,
        start: payload.start,
        name: payload.name,
        phone: payload.phone,
        email: payload.email,
        notes: payload.notes,
        // `minutes` is deliberately not sent: the API looks the length up from the service.
      },
    })
    return { ...payload, ...saved }
  } catch (err) {
    // Both mean "pick another time": taken by somebody else, or no longer bookable (already past, too soon).
    if (err instanceof ApiError && (err.apiCode === 'slot_taken' || err.apiCode === 'slot_unavailable')) {
      throw new SlotTakenError(err.message)
    }
    throw err
  }
}
