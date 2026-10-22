import { describe, expect, it } from 'vitest'
import { DEFAULT_SHOP_SETTINGS } from './shopSettings.js'
import {
  OTHER,
  blankEntry,
  checkEntry,
  dollarsText,
  entryFromRow,
  filterSales,
  money,
  parseDollars,
  rangeBounds,
  saleServices,
  salesMetrics,
  sortSales,
  toCsv,
} from './sales.js'

const TODAY = '2026-10-22' // a Thursday
const row = (over) => ({
  id: 'x',
  dateKey: TODAY,
  serviceId: 'mens-cut',
  serviceName: "Men's haircut",
  amountCents: 5500,
  customPrice: false,
  payment: 'shop',
  clientName: 'Marcus Jones',
  note: '',
  createdAt: '2026-10-22T15:00:00+00:00',
  ...over,
})
const LOG = [
  row({ id: 'a', clientName: 'Marcus Jones', dateKey: '2026-10-22', amountCents: 5500 }),
  row({ id: 'b', clientName: 'Dre Williams', dateKey: '2026-10-21', serviceName: 'After Hours Cuts', serviceId: 'after-hours', amountCents: 7000, payment: 'online' }),
  row({ id: 'c', clientName: 'marcus jones', dateKey: '2026-10-15', amountCents: 6250, customPrice: true, note: 'beard too' }),
  row({ id: 'd', clientName: 'Kid Cam', dateKey: '2026-09-30', serviceName: 'Kids cut', amountCents: 4000, payment: 'online' }),
]

describe('money and prices', () => {
  it('shows cents only when there are some', () => {
    expect(money(5500)).toBe('$55')
    expect(money(6250)).toBe('$62.50')
    expect(money(120400)).toBe('$1,204')
    expect(money(0)).toBe('$0')
  })

  it('reads what Vic types', () => {
    expect(parseDollars('55')).toBe(5500)
    expect(parseDollars('$62.5')).toBe(6250)
    expect(parseDollars(' 62.50 ')).toBe(6250)
    expect(parseDollars('0')).toBe(0)
    expect(parseDollars('9999.99')).toBe(999999)
    for (const bad of ['', 'abc', '-5', '10000', '5.555', '1,000', null]) expect(parseDollars(bad)).toBeNull()
  })
})

describe('the quick form', () => {
  const settings = DEFAULT_SHOP_SETTINGS
  const form = (over) => ({ ...blankEntry(settings, TODAY), clientName: 'Marcus Jones', ...over })

  it('offers his services, then After Hours Cuts', () => {
    const list = saleServices(settings)
    expect(list.slice(0, 5).map((s) => s.id)).toEqual(['mens-cut', 'mens-design', 'mens-beard-eyebrow', 'buzz-beard', 'kids-design'])
    expect(list.at(-1)).toMatchObject({ id: 'after-hours', name: 'After Hours Cuts', price: 70 })
  })

  it('starts on the first service, listed price, paid at the shop, today', () => {
    expect(blankEntry(settings, TODAY)).toMatchObject({ serviceId: 'mens-cut', priceMode: 'standard', payment: 'shop', dateKey: TODAY, clientName: '' })
  })

  it('makes the body for a listed-price sale', () => {
    expect(checkEntry(form(), settings, TODAY)).toEqual({
      ok: true,
      body: { serviceId: 'mens-cut', priceMode: 'standard', payment: 'shop', clientName: 'Marcus Jones', note: '', dateKey: TODAY },
    })
  })

  it('makes the body for a custom price paid online', () => {
    const r = checkEntry(form({ priceMode: 'custom', custom: '62.5', payment: 'online', note: ' beard too ' }), settings, TODAY)
    expect(r.body).toMatchObject({ priceMode: 'custom', amountCents: 6250, payment: 'online', note: 'beard too' })
  })

  it('a one-off service always needs a typed price', () => {
    expect(checkEntry(form({ serviceId: OTHER, otherName: 'Line up' }), settings, TODAY).errors.price).toBeTruthy()
    const r = checkEntry(form({ serviceId: OTHER, otherName: ' Line   up ', custom: '15' }), settings, TODAY)
    expect(r.body).toMatchObject({ serviceName: 'Line up', priceMode: 'custom', amountCents: 1500 })
    expect(r.body.serviceId).toBeUndefined()
    expect(checkEntry(form({ serviceId: OTHER, otherName: '', custom: '15' }), settings, TODAY).errors.service).toBeTruthy()
  })

  it('says what is wrong', () => {
    const r = checkEntry(form({ clientName: '  ', priceMode: 'custom', custom: 'abc', dateKey: '2026-10-23', note: 'x'.repeat(121) }), settings, TODAY)
    expect(r.ok).toBe(false)
    expect(Object.keys(r.errors).sort()).toEqual(['client', 'date', 'note', 'price'])
    expect(checkEntry(form({ serviceId: 'gone' }), settings, TODAY).errors.service).toBeTruthy()
  })
})

describe('date ranges', () => {
  it('counts today', () => {
    expect(rangeBounds('today', TODAY)).toEqual({ from: TODAY, to: TODAY })
    expect(rangeBounds('week', TODAY)).toEqual({ from: '2026-10-16', to: TODAY })
    expect(rangeBounds('30', TODAY)).toEqual({ from: '2026-09-23', to: TODAY })
    expect(rangeBounds('month', TODAY)).toEqual({ from: '2026-10-01', to: TODAY })
    expect(rangeBounds('all', TODAY)).toEqual({ from: '', to: '' })
  })
})

describe('filtering', () => {
  const ids = (rows) => rows.map((r) => r.id)

  it('finds by client, service, note, price and day, ignoring case', () => {
    expect(ids(filterSales(LOG, { query: 'MARCUS' }, TODAY))).toEqual(['a', 'c'])
    expect(ids(filterSales(LOG, { query: 'after hours' }, TODAY))).toEqual(['b'])
    expect(ids(filterSales(LOG, { query: 'beard' }, TODAY))).toEqual(['c'])
    expect(ids(filterSales(LOG, { query: '$62.50' }, TODAY))).toEqual(['c'])
    expect(ids(filterSales(LOG, { query: 'online' }, TODAY))).toEqual(['b', 'd'])
    expect(ids(filterSales(LOG, { query: 'marcus beard' }, TODAY))).toEqual(['c']) // every word must match
  })

  it('filters by service, how they paid and dates, together', () => {
    expect(ids(filterSales(LOG, { service: "Men's haircut" }, TODAY))).toEqual(['a', 'c'])
    expect(ids(filterSales(LOG, { payment: 'online' }, TODAY))).toEqual(['b', 'd'])
    expect(ids(filterSales(LOG, { range: 'week' }, TODAY))).toEqual(['a', 'b']) // the 16th to today, so the 15th is out
    expect(ids(filterSales(LOG, { range: 'today' }, TODAY))).toEqual(['a'])
    expect(ids(filterSales(LOG, { payment: 'online', range: 'week' }, TODAY))).toEqual(['b'])
    expect(filterSales(LOG, {}, TODAY)).toHaveLength(4)
  })
})

describe('sorting', () => {
  const names = (rows) => rows.map((r) => r.clientName)

  it('puts the highest sales first, ties newest first', () => {
    expect(names(sortSales(LOG, 'amount', 'desc'))).toEqual(['Dre Williams', 'marcus jones', 'Marcus Jones', 'Kid Cam'])
    expect(names(sortSales(LOG, 'amount', 'asc'))[0]).toBe('Kid Cam')
  })

  it('sorts by date, client and service, and never changes the list it was given', () => {
    const copy = [...LOG]
    expect(names(sortSales(LOG, 'date', 'desc'))).toEqual(['Marcus Jones', 'Dre Williams', 'marcus jones', 'Kid Cam'])
    expect(names(sortSales(LOG, 'date', 'asc'))[0]).toBe('Kid Cam')
    expect(names(sortSales(LOG, 'client', 'asc'))[0]).toBe('Dre Williams')
    expect(sortSales(LOG, 'service', 'asc')[0].serviceName).toBe('After Hours Cuts')
    expect(LOG).toEqual(copy)
  })
})

describe('the numbers', () => {
  const m = salesMetrics(LOG)

  it('adds up the sales', () => {
    expect(m.count).toBe(4)
    expect(m.totalCents).toBe(5500 + 7000 + 6250 + 4000)
    expect(m.averageCents).toBe(Math.round(22750 / 4))
    expect(m.highest).toMatchObject({ amountCents: 7000, clientName: 'Dre Williams', serviceName: 'After Hours Cuts' })
    expect(m.customCount).toBe(1)
  })

  it('splits shop and online', () => {
    expect(m.shop).toEqual({ count: 2, cents: 11750 })
    expect(m.online).toEqual({ count: 2, cents: 11000 })
  })

  it('ranks services, clients (one person however the name is cased) and days', () => {
    expect(m.byService[0]).toEqual({ name: "Men's haircut", count: 2, cents: 11750 })
    expect(m.topClients[0]).toEqual({ name: 'Marcus Jones', count: 2, cents: 11750 })
    expect(m.clientCount).toBe(3)
    expect(m.repeatClients).toBe(1)
    expect(m.bestDay).toEqual({ name: '2026-10-21', count: 1, cents: 7000 })
  })

  it('copes with an empty log', () => {
    expect(salesMetrics([])).toMatchObject({ count: 0, totalCents: 0, averageCents: 0, highest: null, bestDay: null, byService: [], clientCount: 0 })
  })
})

describe('the download', () => {
  it('writes a header and one line per sale', () => {
    const csv = toCsv([LOG[2], LOG[0]])
    expect(csv.split('\r\n')).toEqual([
      'Date,Client,Service,Price,Payment,Custom price,Note',
      "2026-10-15,marcus jones,Men's haircut,62.50,At the shop,Yes,beard too",
      "2026-10-22,Marcus Jones,Men's haircut,55.00,At the shop,No,",
      '',
    ])
  })

  it('quotes commas and quotes, and defuses formulas', () => {
    const csv = toCsv([row({ clientName: 'Jones, "JJ"', note: '=SUM(A1)' })])
    expect(csv).toContain('"Jones, ""JJ"""')
    expect(csv).toContain("'=SUM(A1)")
  })
})

describe('editing a line', () => {
  const settings = DEFAULT_SHOP_SETTINGS

  it('fills the form from a line at its listed price', () => {
    const f = entryFromRow(row(), settings)
    expect(f).toMatchObject({ serviceId: 'mens-cut', priceMode: 'standard', custom: '', payment: 'shop', clientName: 'Marcus Jones', dateKey: TODAY })
  })

  it('keeps a custom price as typed dollars', () => {
    expect(entryFromRow(row({ customPrice: true, amountCents: 6250 }), settings)).toMatchObject({ priceMode: 'custom', custom: '62.50' })
    expect(entryFromRow(row({ customPrice: true, amountCents: 6000 }), settings)).toMatchObject({ priceMode: 'custom', custom: '60' })
  })

  it('treats a price that no longer matches the listed one as custom, so saving never changes it', () => {
    const old = row({ amountCents: 4500 }) // listed at $45 back then
    const f = entryFromRow(old, settings)
    expect(f.priceMode).toBe('custom')
    const checked = checkEntry(f, settings, TODAY)
    expect(checked.ok && checked.body.amountCents).toBe(4500)
  })

  it('brings a one-off or removed service back as Other with its name', () => {
    const f = entryFromRow(row({ serviceId: '', serviceName: 'Line up only', amountCents: 2500, customPrice: true }), settings)
    expect(f).toMatchObject({ serviceId: OTHER, otherName: 'Line up only', priceMode: 'custom', custom: '25' })
    expect(entryFromRow(row({ serviceId: 'gone', serviceName: 'Old cut' }), settings).serviceId).toBe(OTHER)
  })

  it('turns an edited form back into a request the API accepts', () => {
    const f = { ...entryFromRow(row({ payment: 'online', note: 'beard too' }), settings), clientName: '  Marcus   J ' }
    const checked = checkEntry(f, settings, TODAY)
    expect(checked).toMatchObject({ ok: true, body: { serviceId: 'mens-cut', priceMode: 'standard', payment: 'online', clientName: 'Marcus J', note: 'beard too', dateKey: TODAY } })
  })

  it('writes dollars without needless cents', () => {
    expect(dollarsText(5500)).toBe('55')
    expect(dollarsText(6205)).toBe('62.05')
  })
})
