#!/usr/bin/env bash
# Sales log: bigger touch targets, wider Day, bigger Note box
# Run from the REPO ROOT:  bash vicbless-sales-touch-friendly.sh
#
# Taller dropdowns and buttons in the Sales log for phones, Day stretched full width, Note moved below it as a bigger box.
#
# Safe by design: before anything is written, every file this touches is compared with the version this script was built
# against. If any of them was edited since, NOTHING is changed and the script lists which ones (FORCE=1 overrides that).
# Running it twice is harmless. It runs no git commands.
set -euo pipefail
if [ ! -d .git ] || [ ! -d frontend/src ] || [ ! -d backend/app ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git, frontend/ and backend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/0" <<'VICBLESS_EOF'
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

        <div className="field sales-day">
          <label htmlFor={`${uid}-date`}>Day</label>
          <input id={`${uid}-date`} type="date" max={today} value={form.dateKey} onChange={(e) => edit({ dateKey: e.target.value })} aria-invalid={!!errors.date} />
          {errors.date && <p className="err">{errors.date}</p>}
        </div>

        <div className="field sales-notebox">
          <label htmlFor={`${uid}-note`}>
            Note <span className="hint">(optional)</span>
          </label>
          <textarea id={`${uid}-note`} rows={3} maxLength={NOTE_MAX} placeholder="Anything worth remembering about this cut" value={form.note} onChange={(e) => edit({ note: e.target.value })} />
          {errors.note && <p className="err">{errors.note}</p>}
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
              <select className="sales-wide" aria-label="Filter by service" value={serviceFilter} onChange={(e) => setServiceFilter(e.target.value)}>
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
              <select className="sales-wide" aria-label="Sort the list" value={sortId} onChange={(e) => setSortId(e.target.value)}>
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
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
/* Admin screens. Every rule starts with .admin so nothing here can touch the public pages. */

.admin {
  max-width: 720px;
  margin: 0 auto;
  padding: calc(16px + env(safe-area-inset-top, 0px)) 16px calc(48px + env(safe-area-inset-bottom, 0px));
}

/* The big welcome line, the page heading. Vic's name is picked out in the accent colour. */
.admin-greeting {
  margin: 20px 0 8px;
  font-size: clamp(2.1rem, 9vw, 3.3rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.admin-name {
  color: var(--accent);
}

.admin-lede {
  margin: 0 0 24px;
  color: var(--muted);
}

/* ---- The logo: goes around an oval like a carousel and turns as it goes ----
   Facing you at the front of the oval, edge-on at the sides, facing away at the back (where the writing
   reads backwards, like a mirror). Bigger at the front, smaller at the back. Always flat.
   To adjust, change these on .admin-loop:
     --orbit-time  seconds for one lap (3.5s now)
     --ax          how wide the oval is, as a % of the logo's own width
     --by          how tall the oval is, as a % of the logo's own height
     --depth       how much bigger at the front / smaller at the back (0.28 = 28%)
   --persp (set per spot below) is how strong the 3D looks: smaller means stronger.
   The logo's size in each spot is the width on its .admin-loop-orbit rule. A bigger logo needs a bigger
   frame, because the whole lap has to fit inside it. */
.admin-loop {
  --orbit-time: 3.5s;
  --ax: 28;
  --by: 20;
  --depth: 0.28;
}

/* Anything outside the frame is cut off, so the frame is sized to hold the whole lap.
   The front of the oval swings low and big, so the logo sits a little higher in its frame (--lift)
   to give that swing room. */
.admin-loop-frame {
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: center;
  padding-bottom: calc(var(--lift) * 2);
  overflow: hidden;
}

.admin-loop-orbit {
  animation: admin-orbit var(--orbit-time) linear infinite;
}

.admin-loop-still {
  animation: none;
  transform: none;
}

.admin-loop .logo {
  width: 100%;
}

/* Sign-in: a little smaller than the old still logo, to leave room for the lap. The frame is the full
   width of the screen (it cancels the page's 16px side padding). */
.admin-loop-hero {
  --persp: 880px;
  --lift: 13px;
  width: calc(100% + 32px);
  height: 160px;
  margin: 0 -16px 8px;
}

.admin-loop-hero .admin-loop-frame {
  width: 100%;
  height: 100%;
}

/* 260px, but on a narrower phone it shrinks so the whole lap (about 1.45 times the logo's width)
   still fits on the screen. */
.admin-loop-hero .admin-loop-orbit {
  width: min(260px, calc((100vw - 12px) / 1.5));
}

/* Dashboard top bar: the logo's place in the bar is this tall, but its frame is the whole width of the bar. */
.admin-loop-bar {
  --persp: 490px;
  --lift: 7px;
  width: 144px;
  height: 94px;
}

.admin-loop-bar .admin-loop-frame {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 14px;
  left: 0;
  pointer-events: none;
}

.admin-loop-bar .admin-loop-orbit {
  width: 144px;
}

.admin-bar .menu-toggle {
  position: relative;
  z-index: 3;
  background: var(--bg);
}

@keyframes admin-orbit {
  0% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(0deg);
  }

  2.0833% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(7.5deg);
  }

  4.1667% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(15deg);
  }

  6.25% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(22.5deg);
  }

  8.3333% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(30deg);
  }

  10.4167% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(37.5deg);
  }

  12.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(45deg);
  }

  14.5833% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(52.5deg);
  }

  16.6667% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(60deg);
  }

  18.75% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(67.5deg);
  }

  20.8333% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(75deg);
  }

  22.9167% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(82.5deg);
  }

  25% {
    transform: translate(calc(var(--ax) * -1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(90deg);
  }

  27.0833% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(97.5deg);
  }

  29.1667% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(105deg);
  }

  31.25% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(112.5deg);
  }

  33.3333% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(120deg);
  }

  35.4167% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(127.5deg);
  }

  37.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(135deg);
  }

  39.5833% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(142.5deg);
  }

  41.6667% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(150deg);
  }

  43.75% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(157.5deg);
  }

  45.8333% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(165deg);
  }

  47.9167% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(172.5deg);
  }

  50% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * -1%)) scale(calc(1 + var(--depth) * -1)) perspective(var(--persp)) rotateY(180deg);
  }

  52.0833% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(187.5deg);
  }

  54.1667% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(195deg);
  }

  56.25% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(202.5deg);
  }

  58.3333% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(210deg);
  }

  60.4167% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(217.5deg);
  }

  62.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(225deg);
  }

  64.5833% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(232.5deg);
  }

  66.6667% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(240deg);
  }

  68.75% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(247.5deg);
  }

  70.8333% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(255deg);
  }

  72.9167% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(262.5deg);
  }

  75% {
    transform: translate(calc(var(--ax) * 1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(270deg);
  }

  77.0833% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(277.5deg);
  }

  79.1667% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(285deg);
  }

  81.25% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(292.5deg);
  }

  83.3333% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(300deg);
  }

  85.4167% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(307.5deg);
  }

  87.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(315deg);
  }

  89.5833% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(322.5deg);
  }

  91.6667% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(330deg);
  }

  93.75% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(337.5deg);
  }

  95.8333% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(345deg);
  }

  97.9167% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(352.5deg);
  }

  100% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(360deg);
  }
}

/* Sign-in is a single centred column. */
.admin-signin {
  max-width: 440px;
  text-align: center;
}

.admin-signin form {
  text-align: left;
}

.admin-signin .btn {
  width: 100%;
}

.admin-signin a {
  color: var(--accent);
}

.admin-foot {
  margin-top: 40px;
  padding-top: 20px;
  font-size: 0.85rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-align: center;
  color: var(--muted);
  border-top: 1px solid var(--line);
}

.admin-preview-note {
  margin: 12px 0 20px;
  padding: 10px 12px;
  font-size: 0.88rem;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

/* Top bar: menu on the left, logo in the middle (the same arrangement as the public site). */
.admin-bar {
  position: relative; /* the menu panel hangs just under the bar */
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  gap: 12px;
  padding-bottom: 14px;
  border-bottom: 2px solid var(--accent);
}

.admin-bar .site-menu {
  justify-self: start;
}

.admin-bar .menu-panel {
  left: 0;
  max-height: calc(100vh - 120px);
  max-height: calc(100svh - 120px);
}

/* ---- day navigation ---- */
.admin-day-nav {
  display: grid;
  grid-template-columns: 48px 1fr 48px;
  gap: 8px;
  align-items: center;
  margin-bottom: 12px;
}

.admin-icon-btn {
  display: grid;
  place-items: center;
  width: 48px;
  height: 48px;
  padding: 0;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-icon-btn:hover {
  border-color: var(--accent);
}

.admin-day-title {
  text-align: center;
}

.admin-day-title h2 {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 800;
}

/* Under the date: Today (or Back to today) and the Pick a date button. */
.admin-day-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 10px;
  margin-top: 8px;
}

/* Pick a date: a big pill. The real date field is invisible and covers all of it, so any tap opens the
   phone's own date picker. 16px text stops iPhones from zooming in. */
.admin-jump {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 48px;
  padding: 0 18px;
  font-weight: 800;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--accent);
  border-radius: 999px;
  cursor: pointer;
}

.admin-jump:hover {
  background: var(--bg);
}

.admin-jump:focus-within {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.admin-jump input[type='date'] {
  position: absolute;
  inset: -2px; /* reaches over the pill's own 2px outline too, so every part of it is the real field */
  width: calc(100% + 4px);
  height: calc(100% + 4px);
  margin: 0;
  padding: 0;
  font-size: 16px;
  opacity: 0;
  cursor: pointer;
}

.admin-jump input[type='date']::-webkit-calendar-picker-indicator {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0;
  cursor: pointer;
}

.admin-today-tag {
  display: inline-block;
  margin-top: 2px;
  padding: 1px 10px;
  font-size: 0.78rem;
  font-weight: 700;
  color: var(--on-accent);
  background: var(--accent);
  border-radius: 999px;
}

.admin-link-btn {
  min-height: 44px;
  padding: 8px 12px;
  font-size: 0.85rem;
  font-weight: 600;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
  background: none;
  border: 0;
}

.admin-status {
  color: var(--muted);
}

.admin-summary {
  margin: 0 0 8px;
  color: var(--muted);
  font-weight: 600;
}

/* ---- the day ---- */
.admin-rows {
  margin: 0;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.admin-row {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  align-items: start;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-time {
  padding-top: 2px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.admin-open-label,
.admin-continues {
  margin: 0;
  padding: 4px 0;
  color: var(--muted);
}

.admin-open .admin-time {
  color: var(--muted);
  font-weight: 600;
}

.admin-card {
  padding: 10px 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-card h3 {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 800;
}

.admin-card p {
  margin: 2px 0 0;
}

.admin-meta {
  font-size: 0.92rem;
  color: var(--muted);
}

.admin-notes {
  font-size: 0.92rem;
  font-style: italic;
}

.admin-card .phone-link,
.admin-card .email-link {
  display: block;
  width: fit-content;
  max-width: 100%;
  padding: 6px 0;
  overflow-wrap: anywhere;
}

.admin-card .email-link {
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-card span.email-link {
  color: var(--ink);
  text-decoration: none;
}

.admin-sample-badge {
  margin-left: 8px;
  padding: 1px 8px;
  font-size: 0.7rem;
  font-weight: 600;
  vertical-align: middle;
  color: var(--muted);
  border: 1px solid var(--line);
  border-radius: 999px;
}

.admin-break {
  padding: 10px 0;
  font-size: 0.85rem;
  text-align: center;
  color: var(--muted);
  border-bottom: 1px dashed var(--line);
}

.admin-unmatched {
  margin-top: 24px;
}

.admin-unmatched h3 {
  margin: 0 0 4px;
}

.admin-row-lone {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  margin-top: 10px;
}

/* ---- actions: cancel, block off time ---- */
.admin-summary-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin: 0 0 8px;
}

.admin-summary-row .admin-summary {
  margin: 0;
}

.admin-summary-row .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

/* Cancel and Remove block: real boxes with a big, easy tap target. */
.admin-box-btn {
  display: block;
  width: 100%;
  max-width: 280px;
  min-height: 52px;
  margin-top: 12px;
  padding: 12px 18px;
  font-size: 1rem;
  font-weight: 800;
  text-align: center;
  color: var(--ink);
  background: transparent;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-box-btn:hover {
  border-color: var(--ink);
}

.admin-box-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-box-danger:hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-confirm {
  margin-top: 10px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-confirm-text {
  margin: 0 0 14px;
  font-size: 0.95rem;
}

.admin-confirm-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.admin-confirm-actions .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

.admin-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-danger:not(:disabled):hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-card-block {
  background: transparent;
  border-style: dashed;
  border-left: 5px solid var(--muted);
}

.admin-blocked-continues .admin-time,
.admin-blocked .admin-time {
  color: var(--muted);
}

.admin-flash-wrap {
  min-height: 0;
}

.admin-flash {
  margin: 0 0 12px;
  padding: 10px 12px;
  font-weight: 600;
  border: 2px solid var(--accent);
  border-radius: 8px;
}

/* ---- block off time form ---- */
.admin-block-form {
  margin: 4px 0 16px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-block-form h3 {
  margin: 0 0 8px;
  font-size: 1.2rem;
  font-weight: 800;
}

.admin-block-form fieldset {
  margin: 0 0 8px;
  padding: 0;
  border: 0;
}

.admin-block-form legend {
  margin-bottom: 4px;
  padding: 0;
  font-weight: 700;
}

.admin-radio {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 44px;
}

.admin-radio input {
  width: 20px;
  height: 20px;
  accent-color: var(--accent);
}

.admin-block-times {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.admin-block-form select {
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-block-form select:focus {
  border-color: var(--accent);
}

.admin-conflicts {
  margin: 0 0 12px;
  padding: 10px 12px;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-conflicts p {
  margin: 0;
  font-weight: 600;
}

.admin-conflicts p + p {
  margin-top: 6px;
}

/* ---- Phones: a roomier "Block off time" ----
   Bigger time pickers, radio buttons and buttons, because the compact sizes that suit a mouse are small for a
   thumb. This applies to phones and touch tablets only; computers keep the compact sizes. */
@media (max-width: 640px), (pointer: coarse) {
  .admin-summary-row {
    flex-wrap: wrap;
    gap: 10px;
  }

  .admin-summary-row .btn {
    min-height: 56px;
    padding: 12px 20px;
    font-size: 1.05rem;
    white-space: nowrap;
  }

  .admin-block-form {
    padding: 18px;
  }

  .admin-block-form legend,
  .admin-block-form .field label {
    font-size: 1.05rem;
  }

  .admin-radio {
    gap: 14px;
    min-height: 58px;
    font-size: 1.1rem;
  }

  .admin-radio input {
    width: 28px;
    height: 28px;
  }

  .admin-block-times {
    gap: 14px;
  }

  .admin-block-form select {
    min-height: 64px;
    padding: 14px 16px;
    font-size: 1.15rem;
    font-weight: 700;
  }

  .admin-block-form .field input {
    min-height: 60px;
    font-size: 1.1rem;
  }

  .admin-block-form .actions .btn {
    flex: 1;
    min-height: 60px;
    font-size: 1.1rem;
  }
}

/* On the narrowest phones the From and Until pickers stack, so each one is full width and big. */
@media (max-width: 380px) {
  .admin-block-times {
    grid-template-columns: 1fr;
  }

  .admin-summary-row .btn {
    flex: 1 1 100%;
  }
}

/* On phones the two buttons at the bottom of the form stack, one per row, so each label fits on one line. */
@media (max-width: 480px) {
  .admin-block-form .actions {
    flex-direction: column;
  }
}

/* ---- long notes: wrap inside the card, fold behind "Show more" ---- */

/* A grid column can't shrink below its widest word unless told it may. This is what stopped a long note
   (or one long unbroken string) from pushing the page sideways. */
.admin-row,
.admin-row-lone {
  grid-template-columns: 84px minmax(0, 1fr);
}

.admin-slot,
.admin-row-lone > :last-child,
.admin-card {
  min-width: 0;
}

.admin-notes {
  white-space: pre-line; /* keep the customer's line breaks, wrap everything else */
  overflow-wrap: anywhere;
}

.admin-notes-folded {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  overflow: hidden;
}

.admin-notes-toggle {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 44px;
  margin-top: 2px;
  padding: 0 6px 0 0;
  font-size: 0.92rem;
  font-weight: 700;
  color: var(--accent);
  background: transparent;
  border: 0;
  cursor: pointer;
}

.admin-notes-toggle:hover {
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-chevron {
  transition: transform 0.15s ease;
}

.admin-chevron.open {
  transform: rotate(180deg);
}

@media (prefers-reduced-motion: reduce) {
  .admin-chevron {
    transition: none;
  }
}

/* ---- Change time / Cancel buttons, and the Change time panel ---- */
.admin-card-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 12px;
}

.admin-card-actions .admin-box-btn {
  flex: 1 1 140px;
  width: auto;
  max-width: none;
  margin-top: 0;
}

.admin-move-form {
  margin: 12px 0 0;
  background: var(--bg);
}

.admin-move-form h3 {
  margin: 0 0 2px;
}

.admin-move-form .field input[type='date'] {
  width: 100%;
}

.admin-move-times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(104px, 1fr));
  gap: 8px;
  margin: 0 0 12px;
}

.admin-move-time {
  position: relative;
  min-height: 52px;
  padding: 8px 6px;
  font-size: 1rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.admin-move-time:not(:disabled):hover {
  border-color: var(--accent);
}

.admin-move-time[aria-pressed='true'] {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

.admin-move-time:disabled {
  cursor: not-allowed;
  color: var(--muted);
  background: transparent;
  opacity: 0.55;
}

.admin-move-taken,
.admin-move-past {
  text-decoration: line-through;
}

.admin-move-now {
  display: block;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.admin-move-summary {
  margin: 0 0 12px;
  font-weight: 600;
}

/* ---- shop settings (Menu > Settings > Shop settings) ---- */
.admin-settings {
  margin: 12px 0 24px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-settings-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px 12px;
}

.admin-settings h2 {
  margin: 0;
  font-size: 1.4rem;
  font-weight: 800;
}

.admin-settings-group {
  margin: 20px 0 0;
  padding: 0;
  border: 0;
}

.admin-settings-group legend {
  margin-bottom: 8px;
  padding: 0;
  font-size: 1.1rem;
  font-weight: 800;
}

.admin-svc-list,
.admin-slot-list {
  margin: 0 0 12px;
  padding: 0;
  list-style: none;
}

.admin-svc {
  margin-bottom: 12px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-svc .field input {
  min-height: 48px;
}

.admin-svc-price {
  display: grid;
  grid-template-columns: minmax(96px, 140px) 1fr;
  gap: 4px 14px;
  align-items: start;
}

.admin-svc-from {
  margin-top: 26px;
}

.admin-svc-actions {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(112px, 1fr));
  gap: 8px;
}

.admin-slot-row {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 4px 12px;
  align-items: center;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-slot-day label {
  display: block;
  font-weight: 700;
}

.admin-slot-input {
  display: flex;
  align-items: center;
  gap: 8px;
}

.admin-slot-input input {
  width: 92px;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-slot-input input:focus {
  border-color: var(--accent);
}

.admin-slot-input input[aria-invalid='true'] {
  border-color: var(--danger);
}

.admin-slot-row .err {
  grid-column: 1 / -1;
  min-height: 0;
}

.admin-svc-actions .admin-box-btn {
  width: 100%;
  max-width: none;
  min-width: 0;
  margin-top: 0;
}

.admin-remind-list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.admin-svc-actions .admin-box-btn {
  padding-inline: 8px;
  font-size: 0.95rem;
}

.admin-card-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 10px;
}

.admin-card .admin-code {
  flex: none;
  margin: 0;
  padding: 4px 10px;
  font-size: 0.82rem;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.admin-phone-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 12px;
}

.texts-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 10px;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.82rem;
  font-weight: 700;
  white-space: nowrap;
}

.texts-on {
  color: #5fd18a;
}

.texts-off {
  color: var(--muted);
}

.admin-card .admin-pay-row {
  margin: 4px 0 2px;
}

.pay-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 10px;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.82rem;
  font-weight: 700;
  white-space: nowrap;
}

.pay-paid {
  color: #5fd18a;
}

.pay-shop {
  color: var(--muted);
}

.pay-pending {
  color: #f0b44c;
}

/* After Hours Cuts on Vic's dashboard: purple outline and an "After hours" label, like on the booking page. */
.admin-card-after {
  border-color: var(--accent);
  box-shadow: 0 0 0 1px var(--accent), 0 0 16px -8px var(--accent);
}

.admin-meta .after-badge {
  display: block;
  width: fit-content;
  margin-top: 8px;
}

.admin-after-divider {
  list-style: none;
  margin: 18px 0 6px;
  padding: 4px 0;
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--accent);
  border-bottom: 2px solid var(--accent);
}

.admin-move-late {
  display: block;
  font-size: 0.6rem;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--accent);
}

.admin-after-group {
  border-color: var(--accent);
}

/* ---- the dashboard's two pages: Schedule and Sales log ------------------------------------------------------- */

.admin-wide {
  max-width: 980px;
}

.admin-tabs {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  margin: 8px 0 20px;
}

.admin-tabs button {
  min-height: 44px;
  font-weight: 800;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.admin-tabs button[aria-current='page'] {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

/* ---- Sales log ------------------------------------------------------------------------------------------------- */

.sales h2 {
  margin: 0;
  font-size: 1.3rem;
  font-weight: 800;
}

.sales-add {
  margin-bottom: 28px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-add h2 {
  margin-bottom: 14px;
}

.sales-add select,
.sales-filters select,
.sales-search,
.sales-other {
  width: 100%;
  min-height: 46px;
  padding: 10px 12px;
  color: var(--ink);
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-other {
  margin-top: 8px;
}

.sales-add select:focus,
.sales-filters select:focus,
.sales-search:focus {
  border-color: var(--accent);
}

.sales-choice {
  margin: 0 0 14px;
  padding: 0;
  border: 0;
}

.sales-choice legend {
  margin-bottom: 4px;
  padding: 0;
  font-weight: 600;
}

.sales-pills {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.sales-pill {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 46px;
  padding: 8px 10px;
  font-weight: 700;
  text-align: center;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.sales-pill input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.sales-pill.is-on {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

.sales-pill.is-off {
  opacity: 0.4;
  cursor: not-allowed;
}

.sales-pill:focus-within {
  outline: 3px solid var(--accent);
  outline-offset: 2px;
}

.sales-custom {
  margin: 10px 0 0;
}

.sales-two {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.sales-submit {
  width: 100%;
  margin-top: 6px;
}

.sales-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: space-between;
  gap: 4px 12px;
  margin: 28px 0 12px;
}

.sales-head .admin-meta {
  margin: 0;
}

.sales-metrics {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  margin: 0;
}

.sales-metric {
  min-width: 0;
  padding: 12px 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-metric.is-big {
  grid-column: 1 / -1;
  border-color: var(--accent);
}

.sales-metric dt {
  font-size: 0.8rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--muted);
}

.sales-metric dd {
  margin: 4px 0 0;
  font-size: 1.6rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
}

.sales-metric.is-big dd {
  font-size: 2.2rem;
  color: var(--accent);
}

.sales-metric dd.is-text {
  font-size: 1.05rem;
  line-height: 1.25;
}

.sales-metric dd.sales-hint,
.sales-hint {
  margin-top: 2px;
  font-size: 0.8rem;
  font-weight: 400;
  color: var(--muted);
}

.sales-bars {
  display: grid;
  gap: 8px;
  margin-top: 14px;
}

.sales-bar-row {
  display: grid;
  grid-template-columns: minmax(90px, 1.1fr) 1.4fr auto;
  align-items: center;
  gap: 10px;
  font-size: 0.9rem;
}

.sales-bar-name {
  overflow-wrap: anywhere;
}

.sales-bar-track {
  height: 10px;
  background: var(--line);
  border-radius: 999px;
  overflow: hidden;
}

.sales-bar-track span {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: 999px;
}

.sales-bar-num {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.sales-filters {
  display: grid;
  gap: 8px;
  margin-bottom: 12px;
}

.sales-filter-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.sales-sheet {
  max-height: 70vh;
  overflow: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-sheet table {
  width: 100%;
  min-width: 600px;
  border-collapse: collapse;
  font-size: 0.92rem;
}

.sales-sheet th,
.sales-sheet td {
  padding: 10px 12px;
  text-align: left;
  vertical-align: top;
  border-bottom: 1px solid var(--line);
}

.sales-sheet thead th {
  position: sticky;
  top: 0;
  z-index: 1;
  font-size: 0.78rem;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--muted);
  background: var(--bg);
  border-bottom: 2px solid var(--accent);
}

.sales-sheet thead button {
  padding: 0;
  font: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  color: inherit;
  background: none;
  border: 0;
  cursor: pointer;
}

.sales-sheet th[aria-sort='ascending'] button,
.sales-sheet th[aria-sort='descending'] button {
  color: var(--accent);
}

.sales-sheet tbody tr:nth-child(even) {
  background: color-mix(in srgb, var(--line) 28%, transparent);
}

.sales-sheet .num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

.sales-sheet .nowrap {
  white-space: nowrap;
}

.sales-sheet tfoot td {
  position: sticky;
  bottom: 0;
  font-weight: 800;
  background: var(--bg);
  border-top: 2px solid var(--accent);
  border-bottom: 0;
}

.sales-client {
  display: block;
  font-weight: 700;
}

.sales-note {
  display: block;
  margin-top: 2px;
  font-size: 0.8rem;
  color: var(--muted);
}

.sales-custom-tag {
  display: block;
  font-size: 0.65rem;
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}

.sales-paid {
  display: inline-block;
  padding: 2px 10px;
  font-size: 0.78rem;
  font-weight: 700;
  white-space: nowrap;
  border: 1px solid currentColor;
  border-radius: 999px;
}

.sales-paid-online {
  color: var(--accent);
}

.sales-paid-shop {
  color: var(--muted);
}

.sales-actions {
  white-space: nowrap;
}

.sales-confirm {
  display: inline-flex;
  gap: 6px;
}

.sales-more {
  display: block;
  width: 100%;
  margin-top: 12px;
}

@media (min-width: 720px) {
  .sales-metrics {
    grid-template-columns: repeat(3, 1fr);
  }

  .sales-metric.is-big {
    grid-column: auto;
  }

  .sales-filters {
    grid-template-columns: 1fr;
  }

  .sales-filter-row {
    grid-template-columns: repeat(4, 1fr);
  }
}

.sales-actions .admin-box-btn {
  min-height: 34px;
  padding: 4px 10px;
}

.sales-swipe {
  margin: 6px 0 0;
  font-size: 0.8rem;
  color: var(--muted);
}

@media (max-width: 719px) {
  .sales-sheet table {
    min-width: 520px;
    font-size: 0.85rem;
  }

  .sales-sheet th,
  .sales-sheet td {
    padding: 8px;
  }
}

@media (min-width: 720px) {
  .sales-swipe {
    display: none;
  }
}

/* ---- editing a sale ---- */

.sales-add.is-editing {
  border-color: var(--accent);
}

.sales-editing {
  margin: -4px 0 12px;
  font-size: 0.9rem;
  color: var(--muted);
}

.sales-submit-row {
  display: flex;
  gap: 10px;
}

.sales-submit-row .sales-submit {
  flex: 1;
}

.sales-sheet tbody tr.is-editing td {
  background: color-mix(in srgb, var(--accent) 14%, transparent);
}

/* ---- the line graph ---- */

.sales-chart {
  margin-top: 18px;
  padding: 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-chart-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 10px;
}

.sales-chart h3 {
  margin: 0;
  font-size: 1.1rem;
}

.sales-seg {
  display: inline-flex;
  border: 2px solid var(--line);
  border-radius: 8px;
  overflow: hidden;
}

.sales-seg-btn,
.sales-period {
  position: relative;
  border-radius: 999px;
  cursor: pointer;
}

.sales-seg-btn input,
.sales-period input {
  position: absolute;
  opacity: 0;
  inset: 0;
  margin: 0;
  cursor: pointer;
}

.sales-seg-btn span {
  display: block;
  padding: 6px 14px;
  min-height: 36px;
  font-weight: 700;
  font-size: 0.9rem;
  line-height: 24px;
  color: var(--muted);
}

.sales-seg-btn.is-on span {
  background: var(--accent);
  color: var(--on-accent);
}

.sales-seg-btn:focus-within {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
  border-radius: 8px;
}

.sales-period:focus-within {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.sales-periods {
  display: flex;
  gap: 8px;
  margin: 0 -14px 12px;
  padding: 2px 14px 6px;
  overflow-x: auto;
  scrollbar-width: thin;
}

.sales-period span {
  display: block;
  padding: 7px 12px;
  min-height: 40px;
  line-height: 26px;
  border: 2px solid var(--line);
  border-radius: 999px;
  font-size: 0.9rem;
  font-weight: 700;
  white-space: nowrap;
  color: var(--muted);
}

.sales-period.is-on span {
  border-color: var(--accent);
  color: var(--ink);
  background: color-mix(in srgb, var(--accent) 18%, transparent);
}

.sales-chart-total {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 10px;
  margin: 0 0 8px;
  color: var(--muted);
}

.sales-chart-total strong {
  font-size: 1.8rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
}

.sales-chart-change {
  font-size: 0.9rem;
  font-weight: 700;
  color: var(--ink);
}

.sales-plot {
  position: relative;
  width: 100%;
}

.sales-plot svg {
  display: block;
  max-width: 100%;
  touch-action: pan-y;
  border-radius: 6px;
}

.sales-plot svg:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.sc-grid {
  stroke: var(--line);
  stroke-width: 1;
}

.sc-axis {
  fill: var(--muted);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}

.sc-line {
  fill: none;
  stroke: var(--accent);
  stroke-width: 2;
  stroke-linejoin: round;
  stroke-linecap: round;
}

.sc-area {
  fill: var(--accent);
  fill-opacity: 0.1;
}

.sc-cross {
  stroke: var(--muted);
  stroke-width: 1;
}

.sc-dot {
  fill: var(--accent);
  stroke: var(--surface);
  stroke-width: 2;
}

.sales-tip {
  position: absolute;
  top: 6px;
  transform: translateX(-50%);
  display: grid;
  gap: 1px;
  min-width: 120px;
  padding: 8px 12px;
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
  pointer-events: none;
  font-size: 0.85rem;
  text-align: center;
  white-space: nowrap;
}

.sales-tip-day,
.sales-tip-sub {
  color: var(--muted);
}

.sales-tip-num {
  font-size: 1.15rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
}

.sales-chart-empty {
  position: absolute;
  left: 0;
  right: 0;
  top: 38%;
  margin: 0;
  text-align: center;
  color: var(--muted);
  pointer-events: none;
}

.sales-chart-toggle {
  margin-top: 8px;
}

.sales-chart-table {
  max-height: 260px;
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: 6px;
}

.sales-chart-table table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.9rem;
}

.sales-chart-table th,
.sales-chart-table td {
  padding: 7px 10px;
  text-align: left;
  border-bottom: 1px solid var(--line);
  font-weight: 400;
}

.sales-chart-table thead th {
  position: sticky;
  top: 0;
  background: var(--surface);
  font-weight: 700;
  color: var(--muted);
}

.sales-chart-table .num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

/* ---- touch-friendly sales log ---- */

.sales-add select,
.sales-filters select {
  min-height: 52px;
  padding: 12px 40px 12px 14px;
  font-size: 16px; /* 16px or more stops phones zooming in when a box is tapped */
  appearance: none;
  -webkit-appearance: none;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='14' height='9' viewBox='0 0 14 9'%3E%3Cpath d='M1 1.5l6 6 6-6' fill='none' stroke='%23a78bfa' stroke-width='2.2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
  background-repeat: no-repeat;
  background-position: right 16px center;
}

.sales-search,
.sales-other,
.sales-add .field input,
.sales-add .field textarea {
  min-height: 52px;
  font-size: 16px;
}

.sales-add .field input[type='date'] {
  display: block;
  width: 100%;
  min-width: 0;
  -webkit-appearance: none;
  appearance: none;
}

.sales-add .field textarea {
  display: block;
  width: 100%;
  min-height: 104px;
  padding: 12px 14px;
  line-height: 1.4;
  resize: vertical;
  font-family: inherit;
  color: var(--ink);
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-add .field textarea:focus {
  border-color: var(--accent);
  outline: none;
}

.sales-day,
.sales-notebox {
  margin-bottom: 14px;
}

.sales-pill {
  min-height: 52px;
  font-size: 1rem;
}

.sales-filter-row .sales-wide {
  grid-column: 1 / -1;
}

.sales-submit-row .btn {
  min-height: 52px;
}

.sales-actions .admin-box-btn {
  min-height: 44px;
  min-width: 64px;
  padding: 8px 14px;
}

@media (min-width: 720px) {
  .sales-filter-row .sales-wide {
    grid-column: auto;
  }

  .sales-add select,
  .sales-filters select {
    min-height: 46px;
    font-size: 1rem;
  }
}
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"frontend/src/admin/SalesPage.jsx\", \"base\": \"a128740ad259e54200e91080841a86275c0cfbe517472e85c6422b7802ba5c55\", \"new\": 0}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"fd0451c23ac10a1f4d21c56cbd02e97ce41e86df33b883b3cbae40a233f2b134\", \"new\": 1}]")

def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()

plan, problems = [], []
for m in MANIFEST:
    path = Path(m["path"])
    new = (stage / str(m["new"])).read_bytes() if m["new"] is not None else None
    current = path.read_bytes() if path.exists() else None
    if current == new:
        continue  # already in its final state
    if current is not None and m["base"] is not None and sha(current) != m["base"]:
        problems.append(str(path))  # edited since this script was built
    elif current is not None and m["base"] is None:
        problems.append(str(path) + " (already exists with different content)")
    elif current is None and m["base"] is not None and new is not None:
        problems.append(str(path) + " (missing)")
    plan.append((path, new))

if problems and not force:
    print("Stopped. These files are not the versions this script was built for, so NOTHING was changed:")
    for p in problems: print("  -", p)
    print("Tell me what differs (or run with FORCE=1 to overwrite them anyway).")
    sys.exit(1)

if not plan:
    print("Already up to date. Nothing to change.")
    sys.exit(0)
for path, new in plan:
    if new is None:
        if path.exists(): path.unlink()
        print("  removed", path)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(new)
        print("  wrote  ", path)
print(f"Done. {len(plan)} file(s) changed.")
PY
echo
echo "Deploy the frontend."
