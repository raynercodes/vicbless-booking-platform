// Vic's sales log: the pure rules behind the "Sales log" page of his dashboard. No browser or network access here.
//
// A row of the log (what the API sends):
//   { id, dateKey, serviceId, serviceName, amountCents, customPrice, payment: 'shop' | 'online', clientName, note, createdAt }
// serviceId is '' for a one-off service Vic typed in.

import { AFTER_HOURS } from '../config.js'

export const OTHER = 'other' // the "Other (type it)" choice in the service list
export const NAME_MAX = 60
export const NOTE_MAX = 120
export const MAX_CENTS = 999999 // $9,999.99, the most the API accepts
export const PAYMENT_WORDS = { shop: 'At the shop', online: 'Online' }

// "$55", "$62.50", "$1,204". Cents only show when there are some.
export function money(cents) {
  const whole = cents % 100 === 0
  return `$${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: 2 })}`
}

// What Vic typed in a price box ("62.5", "$62.50", "62") -> cents, or null when it is not a price.
export function parseDollars(text) {
  const m = /^\$?\s*(\d{1,4})(?:\.(\d{1,2}))?$/.exec(String(text ?? '').trim())
  if (!m) return null
  const cents = Number(m[1]) * 100 + Number((m[2] || '').padEnd(2, '0') || 0)
  return cents <= MAX_CENTS ? cents : null
}

// The services he can pick: his own list, then After Hours Cuts (always, even on a week with no late times).
export function saleServices(settings) {
  return [
    ...settings.services.map((s) => ({ id: s.id, name: s.name, price: s.price })),
    { id: AFTER_HOURS.id, name: AFTER_HOURS.name, price: settings.afterHours.price },
  ]
}

export const blankEntry = (settings, todayKey) => ({
  serviceId: settings.services[0] ? settings.services[0].id : OTHER,
  otherName: '',
  priceMode: 'standard',
  custom: '',
  payment: 'shop',
  clientName: '',
  note: '',
  dateKey: todayKey,
})

// "62.50", "55": cents as the text of a price box.
export const dollarsText = (cents) => (cents / 100).toFixed(cents % 100 === 0 ? 0 : 2)

// A line of the log as the form's fields, ready to edit. A service Vic has since removed (or a one-off) comes back as
// "Other" with its name; a price that is not the service's listed price today comes back as a custom price, so saving
// without touching the price never changes it.
export function entryFromRow(row, settings) {
  const service = row.serviceId ? saleServices(settings).find((s) => s.id === row.serviceId) : null
  const custom = !service || row.customPrice || row.amountCents !== service.price * 100
  return {
    serviceId: service ? service.id : OTHER,
    otherName: service ? '' : row.serviceName,
    priceMode: custom ? 'custom' : 'standard',
    custom: custom ? dollarsText(row.amountCents) : '',
    payment: row.payment === 'online' ? 'online' : 'shop',
    clientName: row.clientName,
    note: row.note || '',
    dateKey: row.dateKey,
  }
}

// Checks the quick form the way the API will. { ok: true, body } or { ok: false, errors: { service?, price?, client?, note?, date? } }
export function checkEntry(form, settings, todayKey) {
  const errors = {}
  const services = saleServices(settings)
  const isOther = form.serviceId === OTHER
  const service = isOther ? null : services.find((s) => s.id === form.serviceId) || null
  const otherName = form.otherName.trim().replace(/\s+/g, ' ')

  if (isOther ? otherName.length < 1 || otherName.length > 60 : !service) errors.service = 'Pick a service, or type the name of a one-off one.'

  // A one-off service has no listed price, so its price is always typed.
  const custom = isOther || form.priceMode === 'custom'
  let amountCents
  if (custom) {
    amountCents = parseDollars(form.custom)
    if (amountCents === null) errors.price = 'Enter the price in dollars, like 55 or 62.50.'
  }

  const clientName = form.clientName.trim().replace(/\s+/g, ' ')
  if (clientName.length < 1 || clientName.length > NAME_MAX) errors.client = "Enter the client's name."
  if (form.note.length > NOTE_MAX) errors.note = `Up to ${NOTE_MAX} characters.`
  if (!/^\d{4}-\d{2}-\d{2}$/.test(form.dateKey)) errors.date = 'Pick the day.'
  else if (form.dateKey > todayKey) errors.date = "A sale can't be dated in the future."

  if (Object.keys(errors).length) return { ok: false, errors }
  return {
    ok: true,
    body: {
      ...(service ? { serviceId: service.id } : { serviceName: otherName }),
      priceMode: custom ? 'custom' : 'standard',
      ...(custom ? { amountCents } : {}),
      payment: form.payment === 'online' ? 'online' : 'shop',
      clientName,
      note: form.note.trim(),
      dateKey: form.dateKey,
    },
  }
}

// ---- the spreadsheet: filter, sort, add up --------------------------------------------------------------------

const pad = (n) => String(n).padStart(2, '0')
const keyOf = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
const dateOf = (key) => {
  const [y, m, d] = key.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export const RANGES = [
  { id: 'all', label: 'All time' },
  { id: 'today', label: 'Today' },
  { id: 'week', label: 'Last 7 days' },
  { id: 'month', label: 'This month' },
  { id: '30', label: 'Last 30 days' },
]

// The first and last day (YYYY-MM-DD) of a date range, counting today. 'all' has no limits.
export function rangeBounds(range, todayKey) {
  const today = dateOf(todayKey)
  const daysBack = (n) => keyOf(new Date(today.getFullYear(), today.getMonth(), today.getDate() - n))
  if (range === 'today') return { from: todayKey, to: todayKey }
  if (range === 'week') return { from: daysBack(6), to: todayKey }
  if (range === '30') return { from: daysBack(29), to: todayKey }
  if (range === 'month') return { from: `${todayKey.slice(0, 8)}01`, to: todayKey }
  return { from: '', to: '' }
}

// Rows that match the search words, the service, how they paid and the dates. `service` is a service name or 'all'.
export function filterSales(rows, { query = '', service = 'all', payment = 'all', range = 'all' } = {}, todayKey) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const { from, to } = rangeBounds(range, todayKey)
  return rows.filter((r) => {
    if (service !== 'all' && r.serviceName !== service) return false
    if (payment !== 'all' && r.payment !== payment) return false
    if (from && r.dateKey < from) return false
    if (to && r.dateKey > to) return false
    if (!words.length) return true
    const text = `${r.clientName} ${r.serviceName} ${r.note} ${r.dateKey} ${money(r.amountCents)} ${PAYMENT_WORDS[r.payment]}`.toLowerCase()
    return words.every((w) => text.includes(w))
  })
}

const byText = (a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' })

// Sorted copy. key: 'date' | 'client' | 'service' | 'amount' | 'payment'; dir: 'asc' | 'desc'. Ties fall back to newest first.
export function sortSales(rows, key = 'date', dir = 'desc') {
  const sign = dir === 'asc' ? 1 : -1
  const newest = (a, b) => (b.dateKey === a.dateKey ? byText(b.createdAt || '', a.createdAt || '') : byText(b.dateKey, a.dateKey))
  const compare = {
    date: (a, b) => byText(a.dateKey, b.dateKey) || byText(a.createdAt || '', b.createdAt || ''),
    client: (a, b) => byText(a.clientName, b.clientName),
    service: (a, b) => byText(a.serviceName, b.serviceName),
    amount: (a, b) => a.amountCents - b.amountCents,
    payment: (a, b) => byText(a.payment, b.payment),
  }[key]
  return [...rows].sort((a, b) => (compare ? sign * compare(a, b) : 0) || newest(a, b))
}

// Everything the numbers at the top of the page show, for the rows given (the page passes the filtered ones).
export function salesMetrics(rows) {
  const total = rows.reduce((sum, r) => sum + r.amountCents, 0)
  const group = (keyOf2, labelOf) => {
    const map = new Map()
    for (const r of rows) {
      const k = keyOf2(r)
      const g = map.get(k) || { name: labelOf(r), count: 0, cents: 0 }
      g.count += 1
      g.cents += r.amountCents
      map.set(k, g)
    }
    return [...map.values()].sort((a, b) => b.cents - a.cents || b.count - a.count || byText(a.name, b.name))
  }
  const part = (payment) => {
    const mine = rows.filter((r) => r.payment === payment)
    return { count: mine.length, cents: mine.reduce((sum, r) => sum + r.amountCents, 0) }
  }
  const highest = rows.reduce((best, r) => (!best || r.amountCents > best.amountCents ? r : best), null)
  const clients = group((r) => r.clientName.toLowerCase(), (r) => r.clientName)
  const days = group((r) => r.dateKey, (r) => r.dateKey)
  return {
    count: rows.length,
    totalCents: total,
    averageCents: rows.length ? Math.round(total / rows.length) : 0,
    highest: highest && { amountCents: highest.amountCents, clientName: highest.clientName, serviceName: highest.serviceName, dateKey: highest.dateKey },
    shop: part('shop'),
    online: part('online'),
    customCount: rows.filter((r) => r.customPrice).length,
    byService: group((r) => r.serviceName, (r) => r.serviceName),
    topClients: clients.slice(0, 5),
    clientCount: clients.length,
    repeatClients: clients.filter((c) => c.count > 1).length,
    bestDay: days[0] || null,
  }
}

// The rows as a CSV file Vic can open in Excel or Google Sheets. A cell that starts with = + - @ is made safe so a
// spreadsheet never runs it as a formula.
export function toCsv(rows) {
  const cell = (value) => {
    let text = String(value ?? '')
    if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`
    return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
  }
  const header = ['Date', 'Client', 'Service', 'Price', 'Payment', 'Custom price', 'Note']
  const lines = rows.map((r) =>
    [r.dateKey, r.clientName, r.serviceName, (r.amountCents / 100).toFixed(2), PAYMENT_WORDS[r.payment], r.customPrice ? 'Yes' : 'No', r.note].map(cell).join(','),
  )
  return [header.join(','), ...lines].join('\r\n') + '\r\n'
}
