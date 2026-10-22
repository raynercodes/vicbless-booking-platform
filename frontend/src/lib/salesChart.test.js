import { describe, expect, it } from 'vitest'
import { PERIODS, addDays, axisLabel, buildSeries, comparisonRange, niceScale, periodRange } from './salesChart.js'

const TODAY = '2026-10-22' // a Thursday
const sale = (dateKey, amountCents = 5500) => ({ dateKey, amountCents })

describe('the periods', () => {
  it('lists the seven filters Vic asked for', () => {
    expect(PERIODS.map((p) => p.label)).toEqual(['This week', 'Last week', 'This month', 'Last month', 'Past 3 months', 'This year', 'Last year'])
  })

  it('runs weeks Monday to Sunday', () => {
    expect(periodRange('this-week', TODAY)).toEqual({ from: '2026-10-19', to: '2026-10-25', unit: 'day' })
    expect(periodRange('last-week', TODAY)).toEqual({ from: '2026-10-12', to: '2026-10-18', unit: 'day' })
    expect(periodRange('this-week', '2026-10-25').from).toBe('2026-10-19') // a Sunday is the end of its week
    expect(periodRange('this-week', '2026-10-26').from).toBe('2026-10-26')
  })

  it('knows the months and years', () => {
    expect(periodRange('this-month', TODAY)).toEqual({ from: '2026-10-01', to: '2026-10-31', unit: 'day' })
    expect(periodRange('last-month', TODAY)).toEqual({ from: '2026-09-01', to: '2026-09-30', unit: 'day' })
    expect(periodRange('last-month', '2026-01-10')).toEqual({ from: '2025-12-01', to: '2025-12-31', unit: 'day' })
    expect(periodRange('this-year', TODAY)).toEqual({ from: '2026-01-01', to: '2026-12-31', unit: 'month' })
    expect(periodRange('last-year', TODAY)).toEqual({ from: '2025-01-01', to: '2025-12-31', unit: 'month' })
  })

  it('cuts the past 3 months into 13 weeks ending with this one', () => {
    expect(periodRange('3-months', TODAY)).toEqual({ from: '2026-07-27', to: '2026-10-25', unit: 'week' })
    expect(buildSeries([], '3-months', TODAY).buckets).toHaveLength(13)
  })

  it('adds days across month ends', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01')
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28')
  })
})

describe('the comparison', () => {
  it('compares an unfinished week with the same days of the week before', () => {
    expect(comparisonRange('this-week', TODAY)).toEqual({ from: '2026-10-12', to: '2026-10-15', label: 'last week so far' })
  })
  it('compares a finished week with the whole one before', () => {
    expect(comparisonRange('last-week', TODAY)).toEqual({ from: '2026-10-05', to: '2026-10-11', label: 'the week before' })
  })
  it('compares this month so far with the same days of last month', () => {
    expect(comparisonRange('this-month', TODAY)).toEqual({ from: '2026-09-01', to: '2026-09-22', label: 'last month so far' })
    expect(comparisonRange('this-month', '2026-03-31').to).toBe('2026-02-28') // never past the end of a shorter month
  })
  it('compares a finished month with the whole month before, even a longer one', () => {
    expect(comparisonRange('last-month', TODAY)).toEqual({ from: '2026-08-01', to: '2026-08-31', label: 'the month before' })
  })
  it('compares years', () => {
    expect(comparisonRange('this-year', TODAY)).toEqual({ from: '2025-01-01', to: '2025-10-22', label: 'last year so far' })
    expect(comparisonRange('last-year', TODAY)).toEqual({ from: '2024-01-01', to: '2024-12-31', label: 'the year before' })
  })
  it('compares the past 3 months with the 13 weeks before', () => {
    expect(comparisonRange('3-months', TODAY)).toMatchObject({ from: '2026-04-27', to: '2026-07-23' })
  })
})

describe('the series', () => {
  const rows = [sale('2026-10-19', 5500), sale('2026-10-19', 7000), sale('2026-10-21', 4000), sale('2026-10-12', 5500), sale('2026-10-13', 5500)]

  it('has a point for every day of the week, zero when nothing sold', () => {
    const s = buildSeries(rows, 'this-week', TODAY)
    expect(s.buckets.map((b) => b.tick)).toEqual(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
    expect(s.buckets.map((b) => b.cents)).toEqual([12500, 0, 4000, 0, 0, 0, 0])
    expect(s.buckets.map((b) => b.count)).toEqual([2, 0, 1, 0, 0, 0, 0])
  })

  it('marks days that have not happened yet', () => {
    expect(buildSeries(rows, 'this-week', TODAY).buckets.map((b) => b.future)).toEqual([false, false, false, false, true, true, true])
    expect(buildSeries(rows, 'last-week', TODAY).buckets.some((b) => b.future)).toBe(false)
  })

  it('totals only up to today and gives the change against the comparison stretch', () => {
    const s = buildSeries(rows, 'this-week', TODAY)
    expect(s.totalCents).toBe(16500)
    expect(s.count).toBe(3)
    expect(s.compareLabel).toBe('last week so far')
    expect(s.changePct).toBe(50) // 16500 vs 11000
    expect(buildSeries(rows, 'this-week', TODAY, 'clients').changePct).toBe(50) // 3 vs 2
  })

  it('has no percentage when there was nothing to compare with', () => {
    const s = buildSeries([sale('2026-10-20')], 'this-week', TODAY)
    expect(s.changePct).toBeNull()
    expect(s.beforeEmpty).toBe(true)
  })

  it('shows a drop as a negative change', () => {
    const s = buildSeries([sale('2026-10-12', 10000), sale('2026-10-20', 5000)], 'this-week', TODAY)
    expect(s.changePct).toBe(-50)
  })

  it('numbers the days of a month and the months of a year', () => {
    const m = buildSeries([sale('2026-10-05', 3000)], 'this-month', TODAY)
    expect(m.buckets).toHaveLength(31)
    expect(m.buckets[4]).toMatchObject({ tick: '5', cents: 3000, long: 'Mon, Oct 5' })
    const y = buildSeries([sale('2026-03-05', 3000), sale('2026-03-30', 1000)], 'this-year', TODAY)
    expect(y.buckets).toHaveLength(12)
    expect(y.buckets[2]).toMatchObject({ tick: 'Mar', cents: 4000, count: 2, long: 'March 2026' })
    expect(y.buckets[10].future).toBe(true)
    expect(y.buckets[9].future).toBe(false) // October has started
  })

  it('adds up weeks for the past 3 months', () => {
    const s = buildSeries([sale('2026-10-19', 1000), sale('2026-10-25', 2000), sale('2026-07-27', 500)], '3-months', TODAY)
    expect(s.buckets[12]).toMatchObject({ key: '2026-10-19', cents: 3000 })
    expect(s.buckets[0]).toMatchObject({ key: '2026-07-27', cents: 500, long: 'Week of Jul 27 to Aug 2' })
  })
})

describe('the axis', () => {
  it('picks round tops and steps', () => {
    expect(niceScale(137)).toEqual({ max: 150, step: 50, ticks: [0, 50, 100, 150] })
    expect(niceScale(5500 / 100)).toMatchObject({ max: 60 })
    expect(niceScale(0)).toEqual({ max: 1, step: 1, ticks: [0, 1] })
    expect(niceScale(1204).max).toBeGreaterThanOrEqual(1204)
    expect(niceScale(3, 4).ticks).toEqual([0, 1, 2, 3])
  })
  it('writes short labels', () => {
    expect(axisLabel(0, 'sales')).toBe('$0')
    expect(axisLabel(250, 'sales')).toBe('$250')
    expect(axisLabel(1500, 'sales')).toBe('$1.5K')
    expect(axisLabel(2, 'clients')).toBe('2')
  })
})
