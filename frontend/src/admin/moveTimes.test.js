import { describe, expect, it } from 'vitest'
import { HOURS } from '../config.js'
import { moveDateRange, moveOptions, ownStarts } from './moveTimes.js'

const TUESDAY = new Date(2026, 9, 13) // Oct 13 2026: open 12:00 pm to 6:00 pm
const base = { date: TUESDAY, hours: HOURS, slotMinutes: 35, minutes: 35 }
const states = (options) => Object.fromEntries(options.map((o) => [o.start, o.state]))

describe('moveOptions', () => {
  it('lists the whole day and marks taken times', () => {
    const options = moveOptions({ ...base, busy: [755] })
    expect(options[0]).toEqual({ start: 720, state: 'free' })
    expect(states(options)[755]).toBe('taken')
    expect(options.length).toBeGreaterThan(5)
  })

  it('marks where the booking is now, on its own day', () => {
    expect(states(moveOptions({ ...base, busy: [720], own: [720], current: 720 }))[720]).toBe('current')
  })

  it('does not let a long booking block itself when it moves one block later', () => {
    // a 70 minute booking holds 12:00 and 12:35; moving it to 12:35 needs 12:35 and 1:10
    const s = states(moveOptions({ ...base, minutes: 70, busy: [720, 755], own: [720, 755], current: 720 }))
    expect(s[755]).toBe('free')
    expect(s[720]).toBe('current')
  })

  it('refuses a long booking when the second block is taken', () => {
    const s = states(moveOptions({ ...base, minutes: 70, busy: [790] }))
    expect(s[755]).toBe('taken')
    expect(s[720]).toBe('free')
  })

  it('marks times that already passed today, including the current minute', () => {
    const s = states(moveOptions({ ...base, nowMinutes: 755 }))
    expect(s[720]).toBe('past')
    expect(s[755]).toBe('past')
    expect(s[790]).toBe('free')
  })

  it('has no times on a closed day', () => {
    expect(moveOptions({ ...base, date: new Date(2026, 9, 14) })).toEqual([]) // Wednesday
  })
})

describe('ownStarts', () => {
  const grid35 = [720, 755, 790, 825]
  const grid45 = [720, 765, 810, 855]

  it('lists the grid times a booking overlaps', () => {
    expect(ownStarts({ start: 720, minutes: 35 }, 35, grid35)).toEqual([720])
    expect(ownStarts({ start: 720, minutes: 70 }, 35, grid35)).toEqual([720, 755])
    expect(ownStarts({ start: 755, minutes: 35 }, 35, grid35)).toEqual([755])
  })

  it('also finds the times of a different appointment length', () => {
    // a 35 minute booking at 12:35 to 1:10 touches both 12:00-12:45 and 12:45-1:30
    expect(ownStarts({ start: 755, minutes: 35 }, 45, grid45)).toEqual([720, 765])
  })
})

describe('moveDateRange', () => {
  it('runs from today to a year ahead', () => {
    expect(moveDateRange(new Date(2026, 9, 12))).toEqual({ min: '2026-10-12', max: '2027-10-12' })
  })
})
