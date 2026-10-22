// The numbers behind the sales line graph. Pure: no browser, no network.
//
// The graph shows one period at a time (this week, last month, past 3 months ...). A period is cut into buckets: one per
// day for a week or a month, one per week for the past 3 months, one per month for a year. Every bucket in the period gets
// a point, including days with no sales (they are zero, not missing), except buckets that have not happened yet.
// Weeks run Monday to Sunday.

export const PERIODS = [
  { id: 'this-week', label: 'This week' },
  { id: 'last-week', label: 'Last week' },
  { id: 'this-month', label: 'This month' },
  { id: 'last-month', label: 'Last month' },
  { id: '3-months', label: 'Past 3 months' },
  { id: 'this-year', label: 'This year' },
  { id: 'last-year', label: 'Last year' },
]

// ---- dates as YYYY-MM-DD keys (UTC arithmetic, so daylight saving never shifts a day) ----

const toDate = (key) => new Date(Date.UTC(Number(key.slice(0, 4)), Number(key.slice(5, 7)) - 1, Number(key.slice(8, 10))))
const toKey = (d) => d.toISOString().slice(0, 10)
export function addDays(key, n) {
  const d = toDate(key)
  d.setUTCDate(d.getUTCDate() + n)
  return toKey(d)
}
const weekStart = (key) => addDays(key, -((toDate(key).getUTCDay() + 6) % 7)) // the Monday on or before
const monthStart = (key) => `${key.slice(0, 8)}01`
const addMonths = (monthKey, n) => {
  const d = toDate(monthStart(monthKey))
  d.setUTCMonth(d.getUTCMonth() + n)
  return toKey(d)
}
const monthEnd = (key) => addDays(addMonths(key, 1), -1)
const min = (a, b) => (a < b ? a : b)

const SHORT_DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const SHORT_MONTH = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const LONG_MONTH = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const monthDay = (key) => `${SHORT_MONTH[Number(key.slice(5, 7)) - 1]} ${Number(key.slice(8, 10))}`
const dayWords = (key) => `${SHORT_DAY[toDate(key).getUTCDay()]}, ${monthDay(key)}`

// The first and last day of a period, and how it is cut up: { from, to, unit: 'day' | 'week' | 'month' }.
export function periodRange(id, today) {
  const year = Number(today.slice(0, 4))
  switch (id) {
    case 'this-week': {
      const from = weekStart(today)
      return { from, to: addDays(from, 6), unit: 'day' }
    }
    case 'last-week': {
      const from = addDays(weekStart(today), -7)
      return { from, to: addDays(from, 6), unit: 'day' }
    }
    case 'last-month': {
      const from = addMonths(today, -1)
      return { from, to: monthEnd(from), unit: 'day' }
    }
    case '3-months': {
      const from = addDays(weekStart(today), -12 * 7) // 13 weeks, the last one being this week
      return { from, to: addDays(weekStart(today), 6), unit: 'week' }
    }
    case 'this-year':
      return { from: `${year}-01-01`, to: `${year}-12-31`, unit: 'month' }
    case 'last-year':
      return { from: `${year - 1}-01-01`, to: `${year - 1}-12-31`, unit: 'month' }
    default: {
      const from = monthStart(today) // 'this-month'
      return { from, to: monthEnd(from), unit: 'day' }
    }
  }
}

// The stretch to compare a period with, cut to the same length so far: this month so far against the same days of last
// month. A period that is over is compared with the whole one before it. Returns { from, to, label }.
export function comparisonRange(id, today) {
  const { from, to, unit } = periodRange(id, today)
  const through = min(to, today) // how far the period has got
  const ongoing = through < to
  if (id === '3-months') return { from: addDays(from, -91), to: addDays(through, -91), label: 'the 3 months before' }
  if (unit === 'month') {
    const year = Number(from.slice(0, 4)) - 1
    return { from: `${year}-01-01`, to: `${year}${through.slice(4)}`, label: ongoing ? 'last year so far' : 'the year before' }
  }
  if (id === 'this-week' || id === 'last-week') return { from: addDays(from, -7), to: addDays(through, -7), label: ongoing ? 'last week so far' : 'the week before' }
  const prevFrom = addMonths(from, -1)
  return { from: prevFrom, to: ongoing ? min(monthEnd(prevFrom), addDays(prevFrom, Number(through.slice(8)) - 1)) : monthEnd(prevFrom), label: ongoing ? 'last month so far' : 'the month before' }
}

// The buckets of a period, each with what was sold in it. `rows` are lines of the sales log.
function buckets({ from, to, unit }, today, rows) {
  const out = []
  let start = from
  while (start <= to) {
    let end
    let tick
    let long
    if (unit === 'day') {
      end = start
      tick = unit === 'day' && to === addDays(from, 6) ? SHORT_DAY[toDate(start).getUTCDay()] : String(Number(start.slice(8)))
      long = dayWords(start)
    } else if (unit === 'week') {
      end = addDays(start, 6)
      tick = monthDay(start)
      long = `Week of ${monthDay(start)} to ${monthDay(end)}`
    } else {
      end = monthEnd(start)
      tick = SHORT_MONTH[Number(start.slice(5, 7)) - 1]
      long = `${LONG_MONTH[Number(start.slice(5, 7)) - 1]} ${start.slice(0, 4)}`
    }
    const mine = rows.filter((r) => r.dateKey >= start && r.dateKey <= end)
    out.push({ key: start, end, tick, long, cents: mine.reduce((sum, r) => sum + r.amountCents, 0), count: mine.length, future: start > today })
    start = addDays(end, 1)
    if (unit === 'month') start = monthStart(start)
  }
  return out
}

const sum = (rows, from, to) => {
  const mine = rows.filter((r) => r.dateKey >= from && r.dateKey <= to)
  return { cents: mine.reduce((total, r) => total + r.amountCents, 0), count: mine.length }
}

// Everything the graph needs for one period. `metric` is 'sales' (dollars) or 'clients' (how many); the change against the
// comparison stretch is for that metric.
export function buildSeries(rows, periodId, today, metric = 'sales') {
  const range = periodRange(periodId, today)
  const list = buckets(range, today, rows)
  const through = min(range.to, today)
  const now = sum(rows, range.from, through)
  const compare = comparisonRange(periodId, today)
  const before = sum(rows, compare.from, compare.to)
  const a = metric === 'clients' ? now.count : now.cents
  const b = metric === 'clients' ? before.count : before.cents
  return {
    range,
    buckets: list,
    totalCents: now.cents,
    count: now.count,
    compareLabel: compare.label,
    // a percent change, or null when there is nothing before to compare with
    changePct: b > 0 ? Math.round(((a - b) / b) * 100) : null,
    beforeEmpty: b === 0,
  }
}

// A round top for the vertical axis and ticks up to it: niceScale(137) -> { max: 150, step: 50, ticks: [0, 50, 100, 150] }.
export function niceScale(top, wanted = 4) {
  if (!(top > 0)) return { max: 1, step: 1, ticks: [0, 1] }
  const magnitude = 10 ** Math.floor(Math.log10(top / wanted))
  const step = [1, 2, 5, 10].map((m) => m * magnitude).find((s) => top / s <= wanted) || 10 * magnitude
  const max = Math.ceil(top / step) * step
  const ticks = []
  for (let v = 0; v <= max + step / 1000; v += step) ticks.push(Math.round(v * 100) / 100)
  return { max, step, ticks }
}

// Axis and tooltip numbers: $0, $250, $1.5K for sales; plain counts for clients.
export function axisLabel(value, metric) {
  if (metric === 'clients') return String(Math.round(value))
  if (value >= 1000) return `$${Number((value / 1000).toFixed(1))}K`
  return `$${value}`
}
