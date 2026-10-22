import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { money } from '../lib/sales.js'
import { PERIODS, axisLabel, buildSeries, niceScale } from '../lib/salesChart.js'

const HEIGHT = 230
const PAD = { top: 14, right: 16, bottom: 28, left: 46 }
const METRICS = [
  { id: 'sales', label: 'Sales' },
  { id: 'clients', label: 'Clients' },
]

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`

// The line graph under the numbers: sales (or number of clients) over a period Vic picks. One line, one axis. Hover or
// touch a point for the exact figure; arrow keys move along it; "Show as a table" lists the same numbers.
export default function SalesChart({ rows, today }) {
  const uid = useId()
  const [period, setPeriod] = useState('this-week')
  const [metric, setMetric] = useState('sales')
  const [active, setActive] = useState(null) // index of the point being looked at
  const [table, setTable] = useState(false)
  const [width, setWidth] = useState(640)
  const box = useRef(null)

  useEffect(() => {
    const el = box.current
    if (!el) return undefined
    const measure = () => setWidth(Math.max(260, Math.round(el.getBoundingClientRect().width)) || 640)
    measure()
    if (typeof ResizeObserver === 'undefined') return undefined
    const watcher = new ResizeObserver(measure)
    watcher.observe(el)
    return () => watcher.disconnect()
  }, [])

  const series = useMemo(() => buildSeries(rows, period, today, metric), [rows, period, today, metric])
  const points = series.buckets
  const value = (b) => (metric === 'clients' ? b.count : b.cents / 100)
  const past = points.filter((b) => !b.future)
  const top = Math.max(0, ...past.map(value))
  const scale = niceScale(top)
  const inner = { w: width - PAD.left - PAD.right, h: HEIGHT - PAD.top - PAD.bottom }
  const x = (i) => PAD.left + (points.length === 1 ? inner.w / 2 : (i / (points.length - 1)) * inner.w)
  const y = (v) => PAD.top + inner.h - (v / scale.max) * inner.h
  const xy = past.map((b, i) => [x(i), y(value(b))])
  const line = xy.map(([px, py], i) => `${i ? 'L' : 'M'}${px.toFixed(1)} ${py.toFixed(1)}`).join(' ')
  const area = xy.length > 1 ? `${line} L${xy[xy.length - 1][0].toFixed(1)} ${y(0)} L${xy[0][0].toFixed(1)} ${y(0)} Z` : ''
  const empty = past.every((b) => b.count === 0)

  // Which x labels fit: about one every 44px, always the first.
  const every = Math.max(1, Math.ceil(points.length / Math.max(2, Math.floor(inner.w / 44))))
  const labelled = (i) => i % every === 0

  const shown = (n) => (metric === 'clients' ? plural(n, 'client', 'clients') : money(n))
  const total = metric === 'clients' ? plural(series.count, 'client', 'clients') : money(series.totalCents)
  const label = PERIODS.find((p) => p.id === period).label
  const change = series.changePct
  const changeText =
    change === null
      ? series.beforeEmpty && (series.totalCents > 0 || series.count > 0)
        ? `Nothing to compare with ${series.compareLabel}`
        : ''
      : change === 0
        ? `Same as ${series.compareLabel}`
        : `${change > 0 ? '▲' : '▼'} ${Math.abs(change)}% vs ${series.compareLabel}`

  function nearest(event) {
    const rect = event.currentTarget.getBoundingClientRect()
    const px = event.clientX - rect.left
    const i = Math.round(((px - PAD.left) / inner.w) * (points.length - 1))
    setActive(Math.min(past.length - 1, Math.max(0, i)))
  }
  function keys(event) {
    const last = past.length - 1
    const move = { ArrowLeft: -1, ArrowRight: 1 }[event.key]
    if (move) {
      event.preventDefault()
      setActive((a) => Math.min(last, Math.max(0, (a === null ? last : a) + move)))
    } else if (event.key === 'Home') setActive(0)
    else if (event.key === 'End') setActive(last)
    else if (event.key === 'Escape') setActive(null)
  }

  const a = active !== null && active < past.length ? past[active] : null
  const tipLeft = a ? Math.min(Math.max(x(active), 80), width - 80) : 0

  return (
    <div className="sales-chart" role="group" aria-label="Sales over time">
      <div className="sales-chart-top">
        <h3>Over time</h3>
        <div className="sales-seg" role="radiogroup" aria-label="What to graph">
          {METRICS.map((m) => (
            <label key={m.id} className={`sales-seg-btn${metric === m.id ? ' is-on' : ''}`}>
              <input type="radio" name={`${uid}-metric`} checked={metric === m.id} onChange={() => setMetric(m.id)} />
              <span>{m.label}</span>
            </label>
          ))}
        </div>
      </div>

      <div className="sales-periods" role="radiogroup" aria-label="Time period">
        {PERIODS.map((p) => (
          <label key={p.id} className={`sales-period${period === p.id ? ' is-on' : ''}`}>
            <input
              type="radio"
              name={`${uid}-period`}
              checked={period === p.id}
              onChange={() => {
                setPeriod(p.id)
                setActive(null)
              }}
            />
            <span>{p.label}</span>
          </label>
        ))}
      </div>

      <p className="sales-chart-total" aria-live="polite">
        <strong>{total}</strong> <span>{label.toLowerCase()}</span>
        {changeText && <span className="sales-chart-change">{changeText}</span>}
      </p>

      {table ? (
        <div className="sales-chart-table">
          <table>
            <thead>
              <tr>
                <th scope="col">{series.range.unit === 'day' ? 'Day' : series.range.unit === 'week' ? 'Week' : 'Month'}</th>
                <th scope="col" className="num">
                  Sales
                </th>
                <th scope="col" className="num">
                  Clients
                </th>
              </tr>
            </thead>
            <tbody>
              {past.map((b) => (
                <tr key={b.key}>
                  <th scope="row">{b.long}</th>
                  <td className="num">{money(b.cents)}</td>
                  <td className="num">{b.count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="sales-plot" ref={box}>
          <svg
            width={width}
            height={HEIGHT}
            viewBox={`0 0 ${width} ${HEIGHT}`}
            role="img"
            tabIndex={0}
            aria-label={`${metric === 'clients' ? 'Clients' : 'Sales'}, ${label.toLowerCase()}: ${total}. Use the left and right arrow keys to read each point, or show the table.`}
            onPointerMove={nearest}
            onPointerDown={nearest}
            onPointerLeave={(e) => e.pointerType === 'mouse' && setActive(null)}
            onKeyDown={keys}
            onBlur={() => setActive(null)}
          >
            {scale.ticks.map((t) => (
              <g key={t}>
                <line x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} className="sc-grid" />
                <text x={PAD.left - 8} y={y(t) + 4} textAnchor="end" className="sc-axis">
                  {axisLabel(t, metric)}
                </text>
              </g>
            ))}
            {points.map((b, i) => labelled(i) && (
              <text key={b.key} x={x(i)} y={HEIGHT - 8} textAnchor={i === 0 ? 'start' : i === points.length - 1 ? 'end' : 'middle'} className="sc-axis">
                {b.tick}
              </text>
            ))}
            {area && <path d={area} className="sc-area" />}
            {xy.length > 1 && <path d={line} className="sc-line" />}
            {a && <line x1={x(active)} x2={x(active)} y1={PAD.top} y2={y(0)} className="sc-cross" />}
            {xy.length > 0 && !a && (
              <circle cx={xy[xy.length - 1][0]} cy={xy[xy.length - 1][1]} r={5} className="sc-dot" />
            )}
            {a && <circle cx={x(active)} cy={y(value(a))} r={5} className="sc-dot" />}
          </svg>
          {a && (
            <div className="sales-tip" style={{ left: tipLeft }} role="status">
              <span className="sales-tip-day">{a.long}</span>
              <span className="sales-tip-num">{shown(metric === 'clients' ? a.count : a.cents)}</span>
              <span className="sales-tip-sub">{metric === 'clients' ? money(a.cents) : plural(a.count, 'client', 'clients')}</span>
            </div>
          )}
          {empty && <p className="sales-chart-empty">No sales in this period yet.</p>}
        </div>
      )}

      <button type="button" className="link-btn sales-chart-toggle" onClick={() => setTable((t) => !t)} aria-pressed={table}>
        {table ? 'Show the graph' : 'Show as a table'}
      </button>
    </div>
  )
}
