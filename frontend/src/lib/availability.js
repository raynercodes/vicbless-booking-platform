// Pure scheduling logic. No browser or network access, so it is easy to test.

export const pad = (n) => String(n).padStart(2, '0')

export const keyOf = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`

export const fromKey = (k) => {
  const [y, m, d] = k.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export const fmtTime = (minutes) => {
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return `${h % 12 || 12}:${pad(m)} ${h >= 12 ? 'pm' : 'am'}`
}

// How many grid blocks a service occupies.
export const blocksFor = (minutes, slotMinutes) => Math.max(1, Math.ceil(minutes / slotMinutes))

// Every block start on a day. Each opening window runs its own grid from its
// opening time, so Saturday's afternoon grid starts at 12:35, not 12:00.
export function slotStarts(date, hours, slotMinutes) {
  const windows = hours[date.getDay()]
  if (!windows) return []
  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + slotMinutes <= close; s += slotMinutes) out.push(s)
  }
  return out
}

// Start times (minutes after midnight) a service of `minutes` can begin on `date`.
//   hours   map of dayIndex -> [[open, close], ...] | null   (minutes after midnight)
//   busy    array of busy block starts
//   now     current time, used to hide times that already passed
export function slotsForDay({ date, minutes, hours, busy = [], now = new Date(), slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) return []

  const busySet = new Set(busy)
  const blocks = blocksFor(minutes, slotMinutes)
  const isToday = keyOf(date) === keyOf(now)
  const nowMinutes = now.getHours() * 60 + now.getMinutes()

  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + minutes <= close; s += slotMinutes) {
      if (isToday && s <= nowMinutes + 30) continue
      let free = true
      for (let k = 0; k < blocks; k++) {
        if (busySet.has(s + k * slotMinutes)) {
          free = false
          break
        }
      }
      if (free) out.push(s)
    }
  }
  return out
}

// Every start time a service of `minutes` could begin on `date`, whether or not it is free.
// Used to show the whole day with the unavailable times greyed out instead of hidden.
export function startsForDay({ date, minutes, hours, slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) return []
  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + minutes <= close; s += slotMinutes) out.push(s)
  }
  return out
}
