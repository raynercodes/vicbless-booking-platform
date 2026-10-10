import { blocksFor } from '../lib/availability.js'

// Turns one day's bookings and blocked time into the rows of the schedule. Pure, so it is easy to test.
//   hours    map of dayIndex -> [[open, close], ...] | null   (minutes after midnight)
//   items    bookings for that day: { start, minutes, ...details }
//   blocks   time Vic blocked off: { start, end, ...details }
//
// Every 35 minute block in the open windows becomes a row: a booking, the continuation of a longer
// booking, blocked, still blocked, or open. Nothing is ever hidden: a booking that does not land on
// the grid (for example if the hours were changed after it was made) comes back in `unmatched`, and a
// block with no free row to sit on comes back in `unmatchedBlocks`. A booking always wins over a block.
export function buildDayRows({ date, hours, items, blocks = [], slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) {
    return { closed: true, groups: [], unmatched: [], unmatchedBlocks: [], booked: 0, blocked: 0, open: 0 }
  }

  const byStart = new Map()
  for (const item of items) {
    const count = blocksFor(item.minutes, slotMinutes)
    for (let k = 0; k < count; k++) {
      byStart.set(item.start + k * slotMinutes, k === 0 ? { kind: 'booking', item } : { kind: 'continues', item })
    }
  }

  const shown = new Set()
  const groups = windows.map(([open, close]) => {
    const rows = []
    for (let start = open; start + slotMinutes <= close; start += slotMinutes) {
      const hit = byStart.get(start)
      if (hit) shown.add(hit.item)
      rows.push({ start, ...(hit || { kind: 'open' }) })
    }
    return { open, close, rows }
  })

  const allRows = groups.flatMap((g) => g.rows)
  const placed = new Set()
  for (const block of blocks) {
    let first = true
    for (const row of allRows) {
      if (row.kind === 'open' && row.start >= block.start && row.start < block.end) {
        row.kind = first ? 'blocked' : 'blocked-continues'
        row.block = block
        first = false
        placed.add(block)
      }
    }
  }

  return {
    closed: false,
    groups,
    unmatched: items.filter((item) => !shown.has(item)),
    unmatchedBlocks: blocks.filter((block) => !placed.has(block)),
    booked: allRows.filter((r) => r.kind === 'booking' || r.kind === 'continues').length,
    blocked: allRows.filter((r) => r.kind === 'blocked' || r.kind === 'blocked-continues').length,
    open: allRows.filter((r) => r.kind === 'open').length,
  }
}
