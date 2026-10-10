import { describe, it, expect } from 'vitest'
import { buildDayRows } from './schedule.js'

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
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const build = (date, items = []) => buildDayRows({ date, hours: HOURS, items })

describe('buildDayRows', () => {
  it('a closed day has no rows', () => {
    const v = build(WEDNESDAY)
    expect(v.closed).toBe(true)
    expect(v.groups).toEqual([])
    expect(v.booked + v.open).toBe(0)
  })

  it('an empty open day is every block open', () => {
    const v = build(TUESDAY)
    expect(v.closed).toBe(false)
    expect(v.groups).toHaveLength(1)
    expect(v.groups[0].rows).toHaveLength(10)
    expect(v.open).toBe(10)
    expect(v.booked).toBe(0)
    expect(v.groups[0].rows[0].start).toBe(at(12))
    expect(v.groups[0].rows[1].start).toBe(at(12, 35))
  })

  it('puts each booking on its own block and counts booked and open', () => {
    const v = build(TUESDAY, [
      { start: at(12), minutes: 35, name: 'A' },
      { start: at(13, 10), minutes: 35, name: 'B' },
    ])
    const rows = v.groups[0].rows
    expect(rows[0].kind).toBe('booking')
    expect(rows[0].item.name).toBe('A')
    expect(rows[1].kind).toBe('open')
    expect(rows[2].kind).toBe('booking')
    expect(v.booked).toBe(2)
    expect(v.open).toBe(8)
  })

  it('a longer booking takes several blocks, shown as a booking plus continuations', () => {
    const v = build(TUESDAY, [{ start: at(12, 35), minutes: 70, name: 'Long' }])
    const rows = v.groups[0].rows
    expect(rows[1].kind).toBe('booking')
    expect(rows[2].kind).toBe('continues')
    expect(rows[2].item.name).toBe('Long')
    expect(rows[3].kind).toBe('open')
    expect(v.booked).toBe(2)
  })

  it('Saturday is two groups, each on its own grid', () => {
    const v = build(SATURDAY)
    expect(v.groups).toHaveLength(2)
    expect(v.groups[0].rows[0].start).toBe(at(9))
    expect(v.groups[1].rows[0].start).toBe(at(12, 35))
    expect(v.groups[0].close).toBe(at(12))
    expect(v.groups[1].open).toBe(at(12, 35))
  })

  it('never hides a booking that is not on the grid', () => {
    const odd = { start: at(14, 5), minutes: 35, name: 'Off grid' }
    const v = build(TUESDAY, [odd])
    expect(v.unmatched).toEqual([odd])
    expect(v.booked).toBe(0)
  })

  it('a booking on a day the shop is closed is not lost either', () => {
    const v = build(WEDNESDAY, [{ start: at(13), minutes: 35, name: 'Closed day' }])
    expect(v.closed).toBe(true)
  })

  it('a booking on the very last block is placed', () => {
    const v = build(TUESDAY, [{ start: at(12) + 9 * 35, minutes: 35, name: 'Last' }])
    expect(v.groups[0].rows.at(-1).kind).toBe('booking')
    expect(v.unmatched).toEqual([])
  })
})

describe('blocked time', () => {
  const block = (start, end, extra = {}) => ({ id: 'b', start, end, note: '', ...extra })

  it('fills the rows it covers: the first is blocked, the rest are still blocked', () => {
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [block(at(12, 35), at(14, 20))] })
    const rows = v.groups[0].rows
    expect(rows.map((r) => r.kind).slice(0, 6)).toEqual(['open', 'blocked', 'blocked-continues', 'blocked-continues', 'open', 'open'])
    expect(rows[1].block.id).toBe('b')
    expect(v.blocked).toBe(3)
    expect(v.open).toBe(7)
    expect(v.booked).toBe(0)
  })

  it('counts booked, blocked and open so they always add up to the day', () => {
    const v = buildDayRows({
      date: TUESDAY, hours: HOURS,
      items: [{ start: at(12), minutes: 35, name: 'A' }],
      blocks: [block(at(13, 10), at(14, 20))],
    })
    expect(v.booked + v.blocked + v.open).toBe(10)
    expect([v.booked, v.blocked, v.open]).toEqual([1, 2, 7])
  })

  it('a day off blocks every row', () => {
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [block(at(12), at(18), { whole: true })] })
    expect(v.groups[0].rows.every((r) => r.kind === 'blocked' || r.kind === 'blocked-continues')).toBe(true)
    expect(v.open).toBe(0)
  })

  it('a block runs across the Saturday break, each window keeping its own rows', () => {
    const v = buildDayRows({ date: SATURDAY, hours: HOURS, items: [], blocks: [block(at(11, 20), at(13, 10))] })
    expect(v.groups[0].rows.at(-1).kind).toBe('blocked')
    expect(v.groups[1].rows[0].kind).toBe('blocked-continues')
    expect(v.groups[1].rows[1].kind).toBe('open')
  })

  it('a booking always wins over a block, and is never hidden', () => {
    const v = buildDayRows({
      date: TUESDAY, hours: HOURS,
      items: [{ start: at(12, 35), minutes: 35, name: 'Booked' }],
      blocks: [block(at(12), at(14, 20))],
    })
    const rows = v.groups[0].rows
    expect(rows[1].kind).toBe('booking')
    expect(rows[0].kind).toBe('blocked')
    expect(rows[2].kind).toBe('blocked-continues')
  })

  it('a block with no free row to sit on is not lost', () => {
    const lonely = block(at(12), at(12, 35))
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [{ start: at(12), minutes: 35, name: 'Booked' }], blocks: [lonely] })
    expect(v.unmatchedBlocks).toEqual([lonely])
    const offGrid = block(at(3), at(4))
    expect(buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [offGrid] }).unmatchedBlocks).toEqual([offGrid])
  })

  it('a closed day has no blocked rows', () => {
    expect(buildDayRows({ date: WEDNESDAY, hours: HOURS, items: [], blocks: [block(at(12), at(18))] }).closed).toBe(true)
  })
})
