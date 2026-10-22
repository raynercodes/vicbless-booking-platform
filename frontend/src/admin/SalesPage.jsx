import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { fromKey, keyOf } from '../lib/availability.js'
import {
  NOTE_MAX,
  OTHER,
  PAYMENT_WORDS,
  RANGES,
  blankEntry,
  checkEntry,
  entryFromRow,
  filterSales,
  money,
  saleServices,
  salesMetrics,
  sortSales,
  toCsv,
} from '../lib/sales.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import SalesChart from './SalesChart.jsx'
import { addSale, getSales, removeSale, updateSale } from './adminApi.js'

const PAGE = 100 // rows drawn at a time, so a long log stays quick
const COLUMNS = [
  { key: 'date', label: 'Date' },
  { key: 'client', label: 'Client' },
  { key: 'service', label: 'Service' },
  { key: 'amount', label: 'Price', numeric: true },
  { key: 'payment', label: 'Paid' },
]
const SORTS = [
  { id: 'date-desc', label: 'Newest first', key: 'date', dir: 'desc' },
  { id: 'date-asc', label: 'Oldest first', key: 'date', dir: 'asc' },
  { id: 'amount-desc', label: 'Highest sales', key: 'amount', dir: 'desc' },
  { id: 'amount-asc', label: 'Lowest sales', key: 'amount', dir: 'asc' },
  { id: 'client-asc', label: 'Client A to Z', key: 'client', dir: 'asc' },
]

const dayWords = (dateKey) => fromKey(dateKey).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })

// Vic's sales log (the "Sales log" tab of his dashboard): a quick form to log a client, a spreadsheet of every client
// with search, filters and sorting, and the numbers for whatever the spreadsheet is showing.
export default function SalesPage() {
  const shop = useShopSettings()
  const uid = useId()
  const today = keyOf(new Date())
  const services = useMemo(() => saleServices(shop), [shop])

  const [rows, setRows] = useState([])
  const [status, setStatus] = useState('loading') // loading | ready | error
  const [attempt, setAttempt] = useState(0)

  const [form, setForm] = useState(() => blankEntry(shop, today))
  const [errors, setErrors] = useState({})
  const [saving, setSaving] = useState(false)
  const [flash, setFlash] = useState('')
  const [failure, setFailure] = useState('')

  const [query, setQuery] = useState('')
  const [serviceFilter, setServiceFilter] = useState('all')
  const [payment, setPayment] = useState('all')
  const [range, setRange] = useState('all')
  const [sortId, setSortId] = useState('date-desc')
  const [shown, setShown] = useState(PAGE)
  const [confirmId, setConfirmId] = useState(null)
  const [editing, setEditing] = useState(null) // the line being changed in the form above, or null when adding
  const formRef = useRef(null)

  useEffect(() => {
    let alive = true
    setStatus('loading')
    getSales()
      .then((list) => {
        if (!alive) return
        setRows(list)
        setStatus('ready')
      })
      .catch(() => alive && setStatus('error'))
    return () => {
      alive = false
    }
  }, [attempt])

  useEffect(() => {
    if (!flash) return undefined
    const timer = setTimeout(() => setFlash(''), 6000)
    return () => clearTimeout(timer)
  }, [flash])

  // Back to the first page of rows whenever what is shown changes.
  useEffect(() => setShown(PAGE), [query, serviceFilter, payment, range, sortId])

  const sort = SORTS.find((s) => s.id === sortId) || SORTS[0]
  const filtered = useMemo(() => filterSales(rows, { query, service: serviceFilter, payment, range }, today), [rows, query, serviceFilter, payment, range, today])
  const visible = useMemo(() => sortSales(filtered, sort.key, sort.dir), [filtered, sort])
  const metrics = useMemo(() => salesMetrics(filtered), [filtered])
  const serviceNames = useMemo(() => [...new Set(rows.map((r) => r.serviceName))].sort((a, b) => a.localeCompare(b)), [rows])
  const filtering = query.trim() !== '' || serviceFilter !== 'all' || payment !== 'all' || range !== 'all'

  const picked = services.find((s) => s.id === form.serviceId) || null
  const isOther = form.serviceId === OTHER
  const custom = isOther || form.priceMode === 'custom'
  const edit = (change) => {
    setForm((f) => ({ ...f, ...change }))
    setFlash('')
    setFailure('')
  }

  async function submit(e) {
    e.preventDefault()
    if (saving) return
    const result = checkEntry(form, shop, today)
    setErrors(result.ok ? {} : result.errors)
    if (!result.ok) return
    setSaving(true)
    setFailure('')
    try {
      if (editing) {
        const row = await updateSale(editing.id, result.body)
        setRows((list) => list.map((r) => (r.id === editing.id ? row : r)))
        setFlash(`Saved the changes to ${row.clientName}, ${row.serviceName}, ${money(row.amountCents)}.`)
        setEditing(null)
        setForm(blankEntry(shop, today))
      } else {
        const row = await addSale(result.body)
        setRows((list) => [row, ...list])
        setFlash(`Added ${row.clientName}, ${row.serviceName}, ${money(row.amountCents)}.`)
        // ready for the next client: the name, note and typed price clear; the service, payment and day stay
        setForm((f) => ({ ...f, clientName: '', note: '', custom: '', otherName: isOther ? '' : f.otherName }))
      }
    } catch (ex) {
      setFailure(ex && ex.friendly ? ex.message : editing ? 'Could not save the changes. Nothing was changed. Try again.' : 'Could not add that. Nothing was saved. Try again.')
    } finally {
      setSaving(false)
    }
  }

  function startEdit(row) {
    setEditing(row)
    setForm(entryFromRow(row, shop))
    setErrors({})
    setFailure('')
    setFlash('')
    setConfirmId(null)
    if (formRef.current) {
      formRef.current.scrollIntoView({ behavior: 'smooth', block: 'start' })
      const first = formRef.current.querySelector('select')
      if (first) first.focus({ preventScroll: true })
    }
  }

  function cancelEdit() {
    setEditing(null)
    setForm(blankEntry(shop, today))
    setErrors({})
    setFailure('')
  }

  async function remove(row) {
    try {
      await removeSale(row.id)
      if (editing && editing.id === row.id) cancelEdit()
      setRows((list) => list.filter((r) => r.id !== row.id))
      setFlash(`Removed ${row.clientName}, ${money(row.amountCents)}.`)
    } catch {
      setFailure('Could not remove that. Nothing was changed. Try again.')
    }
    setConfirmId(null)
  }

  function download() {
    const blob = new Blob([toCsv(visible)], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `vicbless-sales-${today}.csv`
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
  }

  function clearFilters() {
    setQuery('')
    setServiceFilter('all')
    setPayment('all')
    setRange('all')
  }

  // Tapping a column heading sorts by it; tapping it again flips the order.
  function sortBy(key) {
    const sameColumn = sort.key === key
    const next = SORTS.find((s) => s.key === key && s.dir === (sameColumn && sort.dir === 'desc' ? 'asc' : 'desc'))
    if (next) setSortId(next.id)
    else setSortId('date-desc')
  }
  const sortable = new Set(SORTS.map((s) => s.key))

  return (
    <section className="sales" aria-label="Sales log">
      <form ref={formRef} className={`sales-add${editing ? ' is-editing' : ''}`} onSubmit={submit} noValidate aria-label={editing ? 'Edit a sale' : 'Log a sale'}>
        <h2>{editing ? 'Edit this sale' : 'Log a client'}</h2>
        {editing && (
          <p className="sales-editing">
            Changing {editing.clientName}, {dayWords(editing.dateKey)}. Nothing changes until you save.
          </p>
        )}

        <div className="field">
          <label htmlFor={`${uid}-service`}>Which service</label>
          <select id={`${uid}-service`} value={form.serviceId} onChange={(e) => edit({ serviceId: e.target.value })} aria-invalid={!!errors.service}>
            {services.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
            <option value={OTHER}>Other (type it)</option>
          </select>
          {isOther && (
            <input
              className="sales-other"
              aria-label="Name of the service"
              placeholder="What was it? Like Line up only"
              maxLength={60}
              value={form.otherName}
              onChange={(e) => edit({ otherName: e.target.value })}
            />
          )}
          {errors.service && <p className="err">{errors.service}</p>}
        </div>

        <fieldset className="sales-choice">
          <legend>Price</legend>
          <div className="sales-pills">
            <label className={`sales-pill${!custom ? ' is-on' : ''}${isOther ? ' is-off' : ''}`}>
              <input type="radio" name={`${uid}-price`} checked={!custom} disabled={isOther} onChange={() => edit({ priceMode: 'standard' })} />
              <span>{picked && !isOther ? `Listed price ${money(picked.price * 100)}` : 'Listed price'}</span>
            </label>
            <label className={`sales-pill${custom ? ' is-on' : ''}`}>
              <input type="radio" name={`${uid}-price`} checked={custom} onChange={() => edit({ priceMode: 'custom' })} />
              <span>Custom price</span>
            </label>
          </div>
          {custom && (
            <div className="field sales-custom">
              <label htmlFor={`${uid}-custom`}>Price ($)</label>
              <input id={`${uid}-custom`} inputMode="decimal" placeholder="62.50" value={form.custom} onChange={(e) => edit({ custom: e.target.value })} aria-invalid={!!errors.price} />
            </div>
          )}
          {errors.price && <p className="err">{errors.price}</p>}
        </fieldset>

        <fieldset className="sales-choice">
          <legend>How they paid</legend>
          <div className="sales-pills">
            {['shop', 'online'].map((value) => (
              <label key={value} className={`sales-pill${form.payment === value ? ' is-on' : ''}`}>
                <input type="radio" name={`${uid}-pay`} checked={form.payment === value} onChange={() => edit({ payment: value })} />
                <span>{value === 'shop' ? 'At the shop' : 'Online'}</span>
              </label>
            ))}
          </div>
        </fieldset>

        <div className="field">
          <label htmlFor={`${uid}-client`}>Client's name</label>
          <input id={`${uid}-client`} autoComplete="off" maxLength={60} value={form.clientName} onChange={(e) => edit({ clientName: e.target.value })} aria-invalid={!!errors.client} />
          {errors.client && <p className="err">{errors.client}</p>}
        </div>

        <div className="sales-two">
          <div className="field">
            <label htmlFor={`${uid}-date`}>Day</label>
            <input id={`${uid}-date`} type="date" max={today} value={form.dateKey} onChange={(e) => edit({ dateKey: e.target.value })} aria-invalid={!!errors.date} />
            {errors.date && <p className="err">{errors.date}</p>}
          </div>
          <div className="field">
            <label htmlFor={`${uid}-note`}>
              Note <span className="hint">(optional)</span>
            </label>
            <input id={`${uid}-note`} maxLength={NOTE_MAX} value={form.note} onChange={(e) => edit({ note: e.target.value })} />
          </div>
        </div>

        {failure && (
          <p className="err" role="alert">
            {failure}
          </p>
        )}
        <div role="status" aria-live="polite">
          {flash && <p className="admin-flash">{flash}</p>}
        </div>
        <div className="sales-submit-row">
          <button type="submit" className="btn btn-primary sales-submit" disabled={saving}>
            {saving ? (editing ? 'Saving…' : 'Adding…') : editing ? 'Save changes' : 'Add to log'}
          </button>
          {editing && (
            <button type="button" className="btn" onClick={cancelEdit} disabled={saving}>
              Cancel
            </button>
          )}
        </div>
      </form>

      {status === 'loading' && (
        <p role="status" className="admin-status">
          Loading the sales log…
        </p>
      )}
      {status === 'error' && (
        <div>
          <p className="notice" role="alert">
            Could not load the sales log.
          </p>
          <button type="button" className="btn" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      )}

      {status === 'ready' && (
        <>
          <div className="sales-head">
            <h2>Numbers</h2>
            <p className="admin-meta">
              {filtering ? `For the ${metrics.count} of ${rows.length} sales shown below` : `For all ${rows.length} sales`}
            </p>
          </div>
          <Metrics m={metrics} />
          <SalesChart rows={rows} today={today} />

          <div className="sales-head">
            <h2>Clients</h2>
            <button type="button" className="admin-box-btn" onClick={download} disabled={visible.length === 0}>
              Download for Excel
            </button>
          </div>

          <div className="sales-filters" role="search" aria-label="Search and filter the sales log">
            <input type="search" className="sales-search" aria-label="Search clients" placeholder="Search a client, service or note" value={query} onChange={(e) => setQuery(e.target.value)} />
            <div className="sales-filter-row">
              <select aria-label="Filter by service" value={serviceFilter} onChange={(e) => setServiceFilter(e.target.value)}>
                <option value="all">All services</option>
                {serviceNames.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
              <select aria-label="Filter by how they paid" value={payment} onChange={(e) => setPayment(e.target.value)}>
                <option value="all">Any payment</option>
                <option value="shop">Paid at the shop</option>
                <option value="online">Paid online</option>
              </select>
              <select aria-label="Filter by dates" value={range} onChange={(e) => setRange(e.target.value)}>
                {RANGES.map((r) => (
                  <option key={r.id} value={r.id}>
                    {r.label}
                  </option>
                ))}
              </select>
              <select aria-label="Sort the list" value={sortId} onChange={(e) => setSortId(e.target.value)}>
                {SORTS.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label}
                  </option>
                ))}
              </select>
            </div>
            {filtering && (
              <button type="button" className="link-btn" onClick={clearFilters}>
                Clear search and filters
              </button>
            )}
          </div>

          {rows.length === 0 ? (
            <p className="empty">Nothing logged yet. Add your first client above.</p>
          ) : visible.length === 0 ? (
            <p className="empty">No sales match. Clear the search or filters to see them all.</p>
          ) : (
            <>
              <div className="sales-sheet" tabIndex={0} role="region" aria-label="Sales spreadsheet">
                <table>
                  <thead>
                    <tr>
                      {COLUMNS.map((c) => (
                        <th key={c.key} scope="col" className={c.numeric ? 'num' : ''} aria-sort={sort.key === c.key ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                          {sortable.has(c.key) ? (
                            <button type="button" onClick={() => sortBy(c.key)}>
                              {c.label}
                              <span aria-hidden="true">{sort.key === c.key ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : ''}</span>
                            </button>
                          ) : (
                            c.label
                          )}
                        </th>
                      ))}
                      <th scope="col">
                        <span className="sr-only">Edit or remove</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {visible.slice(0, shown).map((r) => (
                      <tr key={r.id} className={editing && editing.id === r.id ? 'is-editing' : ''}>
                        <td className="nowrap">{dayWords(r.dateKey)}</td>
                        <td>
                          <span className="sales-client">{r.clientName}</span>
                          {r.note && <span className="sales-note">{r.note}</span>}
                        </td>
                        <td>{r.serviceName}</td>
                        <td className="num nowrap">
                          {money(r.amountCents)}
                          {r.customPrice && <span className="sales-custom-tag">custom</span>}
                        </td>
                        <td>
                          <span className={`sales-paid sales-paid-${r.payment}`}>{PAYMENT_WORDS[r.payment]}</span>
                        </td>
                        <td className="sales-actions">
                          {confirmId === r.id ? (
                            <span className="sales-confirm">
                              <button type="button" className="admin-box-btn admin-box-danger" onClick={() => remove(r)}>
                                Yes, remove
                              </button>
                              <button type="button" className="admin-box-btn" onClick={() => setConfirmId(null)}>
                                Keep
                              </button>
                            </span>
                          ) : (
                            <span className="sales-confirm">
                              <button type="button" className="admin-box-btn" onClick={() => startEdit(r)} aria-label={`Edit ${r.clientName}, ${money(r.amountCents)}`}>
                                Edit
                              </button>
                              <button type="button" className="admin-box-btn" onClick={() => setConfirmId(r.id)} aria-label={`Remove ${r.clientName}, ${money(r.amountCents)}`}>
                                Remove
                              </button>
                            </span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr>
                      <td colSpan={3}>
                        {visible.length} {visible.length === 1 ? 'sale' : 'sales'}
                      </td>
                      <td className="num nowrap">{money(metrics.totalCents)}</td>
                      <td colSpan={2} />
                    </tr>
                  </tfoot>
                </table>
              </div>
              <p className="sales-swipe">Swipe the table sideways to see every column.</p>
              {visible.length > shown && (
                <button type="button" className="btn sales-more" onClick={() => setShown((n) => n + PAGE)}>
                  Show more ({visible.length - shown} left)
                </button>
              )}
            </>
          )}
        </>
      )}
    </section>
  )
}

function Metrics({ m }) {
  const best = m.byService[0]
  const topClient = m.topClients[0]
  const cards = [
    { label: 'Total sales', value: money(m.totalCents), big: true },
    { label: 'Clients logged', value: String(m.count), hint: m.count ? `${m.clientCount} different, ${m.repeatClients} came back` : '' },
    { label: 'Average sale', value: m.count ? money(m.averageCents) : '$0' },
    { label: 'Highest sale', value: m.highest ? money(m.highest.amountCents) : '$0', hint: m.highest ? `${m.highest.clientName}, ${m.highest.serviceName}` : '' },
    { label: 'Paid at the shop', value: money(m.shop.cents), hint: `${m.shop.count} ${m.shop.count === 1 ? 'client' : 'clients'}` },
    { label: 'Paid online', value: money(m.online.cents), hint: `${m.online.count} ${m.online.count === 1 ? 'client' : 'clients'}` },
    { label: 'Top service', value: best ? best.name : 'None yet', hint: best ? `${money(best.cents)}, ${best.count} ${best.count === 1 ? 'sale' : 'sales'}` : '', text: true },
    { label: 'Top client', value: topClient ? topClient.name : 'None yet', hint: topClient ? `${money(topClient.cents)}, ${topClient.count} ${topClient.count === 1 ? 'visit' : 'visits'}` : '', text: true },
    {
      label: 'Best day',
      value: m.bestDay ? dayWords(m.bestDay.name) : 'None yet',
      hint: m.bestDay ? `${money(m.bestDay.cents)}, ${m.bestDay.count} ${m.bestDay.count === 1 ? 'client' : 'clients'}` : '',
      text: true,
    },
  ]
  return (
    <>
      <dl className="sales-metrics">
        {cards.map((c) => (
          <div key={c.label} className={`sales-metric${c.big ? ' is-big' : ''}`}>
            <dt>{c.label}</dt>
            <dd className={c.text ? 'is-text' : ''}>{c.value}</dd>
            {c.hint && <dd className="sales-hint">{c.hint}</dd>}
          </div>
        ))}
      </dl>
      {m.byService.length > 0 && (
        <div className="sales-bars" role="group" aria-label="Sales by service">
          {m.byService.map((s) => (
            <div key={s.name} className="sales-bar-row">
              <span className="sales-bar-name">{s.name}</span>
              <span className="sales-bar-track" aria-hidden="true">
                <span style={{ width: `${Math.max(4, Math.round((s.cents / m.byService[0].cents) * 100))}%` }} />
              </span>
              <span className="sales-bar-num">
                {money(s.cents)} <span className="sales-hint">({s.count})</span>
              </span>
            </div>
          ))}
        </div>
      )}
    </>
  )
}
