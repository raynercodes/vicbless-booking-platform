import { fmtTime, slotStarts } from '../lib/availability.js'

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
// Anything that shares even a minute with the range counts, whatever appointment length it was made with
// (a booking made on an older 35 minute schedule can sit across the edge of today's 45 minute times).
export function findConflicts({ range, items, blocks }) {
  const touches = (start, end) => start < range.end && range.start < end
  return {
    bookings: items.filter((item) => touches(item.start, item.start + item.minutes)),
    blocks: blocks.filter((b) => touches(b.start, b.end)),
  }
}

export const describeRange = (start, end) => `${fmtTime(start)} to ${fmtTime(end)}`
