import { describe, it, expect } from 'vitest'
import { dayGrid, describeRange, findConflicts, rangeFromChoice, startsInRange, wholeDayRange } from './blocks.js'

const at = (h, m = 0) => h * 60 + m
const HOURS = {
  0: null,
  1: [[at(12), at(18)]],
  2: [[at(12), at(18)]],
  3: null,
  4: [[at(11), at(19)]],
  5: [[at(11), at(19)]],
  6: [[at(9), at(12)], [at(12, 35), at(17)]],
}
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const grid = (date) => dayGrid({ date, hours: HOURS })

describe('dayGrid', () => {
  it('lists the day in order, with no break on Saturday and nothing on a closed day', () => {
    expect(grid(TUESDAY)).toHaveLength(10)
    expect(grid(TUESDAY)[0]).toBe(at(12))
    const sat = grid(SATURDAY)
    expect(sat).toHaveLength(12)
    expect(sat).not.toContain(at(12))
    expect([...sat].sort((a, b) => a - b)).toEqual(sat)
    expect(grid(WEDNESDAY)).toEqual([])
  })
})

describe('rangeFromChoice', () => {
  const g = grid(TUESDAY)

  it('one block is from its start to its end', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 35), untilStart: at(12, 35) })).toEqual({ start: at(12, 35), end: at(13, 10) })
  })

  it('several blocks run from the first start to the last end', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 35), untilStart: at(13, 45) })).toEqual({ start: at(12, 35), end: at(14, 20) })
  })

  it('an end before the start is refused with a clear message', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(14, 20), untilStart: at(12) }).error).toBe('The end has to be after the start.')
  })

  it('a time that is not on the grid is refused', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 5), untilStart: at(12, 35) }).error).toBeTruthy()
    expect(rangeFromChoice({ grid: [], fromStart: 1, untilStart: 1 }).error).toBeTruthy()
  })
})

describe('wholeDayRange', () => {
  it('is opening to closing', () => {
    expect(wholeDayRange({ date: TUESDAY, hours: HOURS })).toEqual({ start: at(12), end: at(18) })
  })
  it('covers both windows on Saturday', () => {
    expect(wholeDayRange({ date: SATURDAY, hours: HOURS })).toEqual({ start: at(9), end: at(17) })
  })
  it('is null when closed', () => {
    expect(wholeDayRange({ date: WEDNESDAY, hours: HOURS })).toBeNull()
  })
  it('covers every block of the day', () => {
    for (const date of [TUESDAY, SATURDAY]) {
      const g = grid(date)
      expect(startsInRange(g, wholeDayRange({ date, hours: HOURS }))).toEqual(g)
    }
  })
})

describe('findConflicts', () => {
  const g = grid(TUESDAY)
  const booking = (start, minutes = 35, name = 'A') => ({ start, minutes, name })
  const none = { bookings: [], blocks: [] }

  it('finds nothing on an empty day', () => {
    expect(findConflicts({ range: { start: at(12), end: at(14) }, grid: g, items: [], blocks: [] })).toEqual(none)
  })

  it('finds a booking inside the range, and ignores one outside it', () => {
    const inside = booking(at(12, 35), 35, 'Inside'), outside = booking(at(16, 40), 35, 'Outside')
    const c = findConflicts({ range: { start: at(12), end: at(14) }, grid: g, items: [inside, outside], blocks: [] })
    expect(c.bookings).toEqual([inside])
  })

  it('the edges are exact: a booking right after the range is not a conflict, the first block is', () => {
    const range = { start: at(12), end: at(12, 35) } // exactly one block
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 35))], blocks: [] }).bookings).toEqual([])
    expect(findConflicts({ range, grid: g, items: [booking(at(12))], blocks: [] }).bookings).toHaveLength(1)
  })

  it('a longer booking that reaches into the range counts', () => {
    const long = booking(at(12), 70, 'Long') // takes two blocks
    const range = { start: at(12, 35), end: at(13, 10) }
    expect(findConflicts({ range, grid: g, items: [long], blocks: [] }).bookings).toEqual([long])
  })

  it('finds blocked time that is already there', () => {
    const existing = { id: 'b1', start: at(13, 10), end: at(14, 20) }
    const c = findConflicts({ range: { start: at(12), end: at(13, 45) }, grid: g, items: [], blocks: [existing] })
    expect(c.blocks).toEqual([existing])
    expect(findConflicts({ range: { start: at(12), end: at(13, 10) }, grid: g, items: [], blocks: [existing] }).blocks).toEqual([])
  })

  it('a day off conflicts with any booking that day', () => {
    const range = wholeDayRange({ date: TUESDAY, hours: HOURS })
    expect(findConflicts({ range, grid: g, items: [booking(at(17, 15))], blocks: [] }).bookings).toHaveLength(1)
    expect(findConflicts({ range, grid: g, items: [], blocks: [] })).toEqual(none)
  })

  it('counts a booking from another appointment length that only overlaps the edge', () => {
    const range = { start: at(12), end: at(12, 45) } // one 45 minute block
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 35), 35)], blocks: [] }).bookings).toHaveLength(1)
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 45), 35)], blocks: [] }).bookings).toHaveLength(0)
  })

  it('works across Saturday\'s break', () => {
    const sat = grid(SATURDAY)
    const range = { start: at(11, 20), end: at(13, 10) } // last morning block into the afternoon
    expect(startsInRange(sat, range)).toEqual([at(11, 20), at(12, 35)])
    expect(findConflicts({ range, grid: sat, items: [booking(at(12, 35))], blocks: [] }).bookings).toHaveLength(1)
  })
})

describe('describeRange', () => {
  it('reads like a person would say it', () => {
    expect(describeRange(at(12, 35), at(14, 20))).toBe('12:35 pm to 2:20 pm')
  })
})
