import { blocksFor, fmtTime, slotStarts } from '../lib/availability.js'

// The rules behind "Block off time". Pure, so they are easy to test.
// A block is { dateKey, start, end, note, whole }: it covers every time block that starts at or
// after `start` and before `end` (minutes after midnight).

// The day's time blocks in order, across all opening windows (so Saturday's break is not in it).
export function dayGrid({ date, hours, slotMinutes = 35 }) {
  return slotStarts(date, hours, slotMinutes)
}

// Turns "from this block until the end of that block" into a range, or says what is wrong.
export function rangeFromChoice({ grid, fromStart, untilStart, slotMinutes = 35 }) {
  const a = grid.indexOf(fromStart)
  const b = grid.indexOf(untilStart)
  if (a === -1 || b === -1) return { error: 'Pick a start and an end.' }
  if (b < a) return { error: 'The end has to be after the start.' }
  return { start: grid[a], end: grid[b] + slotMinutes }
}

// From opening to closing, for a day off. null when the shop is closed that day.
export function wholeDayRange({ date, hours }) {
  const windows = hours[date.getDay()]
  if (!windows) return null
  return { start: windows[0][0], end: windows[windows.length - 1][1] }
}

export function startsInRange(grid, { start, end }) {
  return grid.filter((s) => s >= start && s < end)
}

// What a new block would run into: bookings inside it, and blocked time that is already there.
export function findConflicts({ range, grid, items, blocks, slotMinutes = 35 }) {
  const wanted = new Set(startsInRange(grid, range))
  const bookings = items.filter((item) => {
    for (let k = 0; k < blocksFor(item.minutes, slotMinutes); k++) {
      if (wanted.has(item.start + k * slotMinutes)) return true
    }
    return false
  })
  const alreadyBlocked = blocks.filter((b) => startsInRange(grid, b).some((s) => wanted.has(s)))
  return { bookings, blocks: alreadyBlocked }
}

export const describeRange = (start, end) => `${fmtTime(start)} to ${fmtTime(end)}`
