import { describe, it, expect } from 'vitest'
import { slotsForDay, slotStarts, startsForDay, blocksFor, fmtTime, keyOf, fromKey, shopNow } from './availability.js'

const at = (h, m = 0) => h * 60 + m
const HOURS = {
  0: null,
  1: [[at(12), at(18)]],
  2: [[at(12), at(18)]],
  3: null,
  4: [[at(11), at(19)]],
  5: [[at(11), at(19)]],
  6: [
    [at(9), at(12)],
    [at(12, 35), at(17)],
  ],
}
const SLOT = 35
const SUNDAY = new Date(2026, 9, 4)
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const EARLIER = new Date(2026, 9, 1, 8, 0)

const run = (date, minutes, extra = {}) =>
  slotsForDay({ date, minutes, hours: HOURS, now: EARLIER, slotMinutes: SLOT, ...extra })

describe('slotsForDay', () => {
  it('returns nothing on closed days', () => {
    expect(run(SUNDAY, 35)).toEqual([])
    expect(run(WEDNESDAY, 35)).toEqual([])
  })

  it('runs a 35 minute grid from opening time', () => {
    const slots = run(TUESDAY, 35)
    expect(slots[0]).toBe(at(12))
    expect(slots[1]).toBe(at(12, 35))
    expect(slots).toHaveLength(10)
    expect(slots[slots.length - 1]).toBe(at(12) + 9 * 35)
  })

  it('keeps 30 minute services on the same grid', () => {
    expect(run(TUESDAY, 30)).toEqual(run(TUESDAY, 35))
  })

  it('never runs past closing time', () => {
    for (const s of run(TUESDAY, 35)) expect(s + 35).toBeLessThanOrEqual(at(18))
  })

  it('handles Saturday as two separate windows', () => {
    const slots = run(SATURDAY, 35)
    expect(slots[0]).toBe(at(9))
    expect(slots).toContain(at(12, 35))
    expect(slots).not.toContain(at(12)) // lunch gap
    for (const s of slots) {
      const inMorning = s >= at(9) && s + 35 <= at(12)
      const inAfternoon = s >= at(12, 35) && s + 35 <= at(17)
      expect(inMorning || inAfternoon).toBe(true)
    }
  })

  it('excludes a block that is already busy', () => {
    const slots = run(TUESDAY, 35, { busy: [at(12, 35)] })
    expect(slots).not.toContain(at(12, 35))
    expect(slots).toContain(at(12))
    expect(slots).toContain(at(13, 10))
  })

  it('needs every block free for a longer service', () => {
    const slots = run(TUESDAY, 70, { busy: [at(12, 35)] })
    expect(slots).not.toContain(at(12)) // second block is busy
    expect(slots).not.toContain(at(12, 35))
    expect(slots).toContain(at(13, 10))
  })

  it('hides times that already passed today', () => {
    const now = new Date(2026, 9, 6, 13, 0)
    const slots = run(TUESDAY, 35, { now })
    expect(slots[0]).toBe(at(13, 45)) // 13:10 is within 30 min of 13:00
  })
})

describe('helpers', () => {
  it('lists block starts per window', () => {
    const starts = slotStarts(SATURDAY, HOURS, SLOT)
    expect(starts[0]).toBe(at(9))
    expect(starts).toContain(at(12, 35))
  })

  it('counts blocks', () => {
    expect(blocksFor(30, SLOT)).toBe(1)
    expect(blocksFor(35, SLOT)).toBe(1)
    expect(blocksFor(70, SLOT)).toBe(2)
  })

  it('formats times', () => {
    expect(fmtTime(0)).toBe('12:00 am')
    expect(fmtTime(at(12))).toBe('12:00 pm')
    expect(fmtTime(at(12, 35))).toBe('12:35 pm')
  })

  it('round-trips date keys', () => {
    expect(keyOf(fromKey('2026-10-06'))).toBe('2026-10-06')
  })
})

describe('startsForDay (the whole day, free or not)', () => {
  const all = (date, minutes) => startsForDay({ date, minutes, hours: HOURS, slotMinutes: SLOT })

  it('lists every start in the open windows, including times that are taken or already past', () => {
    const open = run(TUESDAY, 35, { busy: [at(12, 35), at(14, 20)] })
    const every = all(TUESDAY, 35)
    expect(every).toHaveLength(10)
    expect(open).toHaveLength(8)
    for (const s of open) expect(every).toContain(s)
    expect(every).toContain(at(12, 35)) // taken, but still part of the day
  })

  it('is empty on closed days', () => {
    expect(all(SUNDAY, 35)).toEqual([])
    expect(all(WEDNESDAY, 35)).toEqual([])
  })

  it('follows each window on a split day', () => {
    const every = all(SATURDAY, 35)
    expect(every[0]).toBe(at(9))
    expect(every).toContain(at(12, 35))
    expect(every).not.toContain(at(12))
  })

  it('leaves out starts where a longer service would run past closing', () => {
    expect(all(TUESDAY, 70).at(-1)).toBeLessThan(all(TUESDAY, 35).at(-1))
    for (const s of all(TUESDAY, 70)) expect(s + 70).toBeLessThanOrEqual(at(18))
  })

  it('never lists a start that slotsForDay offers but startsForDay does not', () => {
    const open = run(TUESDAY, 35)
    const every = all(TUESDAY, 35)
    for (const s of open) expect(every).toContain(s)
  })
})

describe('the shop clock (Eastern time)', () => {
  it('reads Eastern wall time whatever the customer\'s timezone is', () => {
    const summer = shopNow(new Date('2026-10-22T18:00:00Z')) // EDT, UTC-4
    expect([keyOf(summer), summer.getHours(), summer.getMinutes()]).toEqual(['2026-10-22', 14, 0])
    const winter = shopNow(new Date('2026-12-01T18:00:00Z')) // EST, UTC-5
    expect([keyOf(winter), winter.getHours()]).toEqual(['2026-12-01', 13])
  })

  it('uses the Eastern date, even when it is already tomorrow in UTC', () => {
    const late = shopNow(new Date('2026-10-23T02:30:00Z'))
    expect([keyOf(late), late.getHours(), late.getMinutes()]).toEqual(['2026-10-22', 22, 30])
  })

  it('hides 11 am on a day it is already 2 pm in Eastern time', () => {
    const thursday = new Date(2026, 9, 22)
    const now = shopNow(new Date('2026-10-22T18:00:00Z'))
    const slots = slotsForDay({ date: thursday, minutes: 35, hours: HOURS, now, slotMinutes: SLOT })
    expect(slots[0]).toBeGreaterThan(at(14, 30)) // more than 30 minutes from 2 pm
    expect(slots).not.toContain(at(11))
  })
})
