import { blocksFor, keyOf, startsForDay } from '../lib/availability.js'

// Vic can move a booking to any open time from today up to a year ahead (the API enforces the same).
export const MOVE_DAYS_AHEAD = 365

// The earliest and latest day the "new day" field accepts, as YYYY-MM-DD.
export function moveDateRange(today = new Date()) {
  const last = new Date(today.getFullYear(), today.getMonth(), today.getDate() + MOVE_DAYS_AHEAD)
  return { min: keyOf(today), max: keyOf(last) }
}

// The block starts a booking holds, e.g. a 70 minute booking at 12:00 holds 12:00 and 12:35.
export function ownStarts(item, slotMinutes) {
  const out = []
  for (let k = 0; k < blocksFor(item.minutes, slotMinutes); k++) out.push(item.start + k * slotMinutes)
  return out
}

// Every start time on the chosen day, each marked so the screen can show it properly:
//   free      can be picked
//   taken     someone else's booking, or time Vic blocked off (greyed out)
//   current   where this booking is now (when the chosen day is its own day)
//   past      already over today
// `busy` is the day's taken blocks. `own` are this booking's own blocks, which do not count against it:
// moving a long booking one block later must not be blocked by itself.
export function moveOptions({ date, hours, slotMinutes, minutes, busy = [], own = [], current = null, nowMinutes = null }) {
  const taken = new Set(busy)
  for (const s of own) taken.delete(s)
  const count = blocksFor(minutes, slotMinutes)

  return startsForDay({ date, minutes, hours, slotMinutes }).map((start) => {
    if (current !== null && start === current) return { start, state: 'current' }
    if (nowMinutes !== null && start <= nowMinutes) return { start, state: 'past' }
    for (let k = 0; k < count; k++) {
      if (taken.has(start + k * slotMinutes)) return { start, state: 'taken' }
    }
    return { start, state: 'free' }
  })
}
