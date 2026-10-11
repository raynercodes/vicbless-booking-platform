import { useEffect, useMemo, useState } from 'react'
import PhoneLink from '../components/PhoneLink.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, SERVICES, SLOT_MINUTES, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'

const STEPS = ['Service', 'Time', 'Details']
const REFRESH_MS = 30000 // how often the time grid re-checks while it is open
const payLine = (s) =>
  s.from
    ? `Pay at the shop. Starts at $${s.price}, the final price depends on what you get.`
    : `Pay at the shop. $${s.price} total.`

function buildDays() {
  const start = new Date()
  start.setHours(0, 0, 0, 0)
  return Array.from({ length: DAYS_AHEAD }, (_, i) => {
    const d = new Date(start)
    d.setDate(start.getDate() + i)
    return d
  })
}

function dayLabel(d) {
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const diff = Math.round((d - today) / 86400000)
  const monthDay = d.toLocaleDateString(undefined, { month: 'long', day: 'numeric' })
  if (diff === 0) return `Today, ${monthDay}`
  if (diff === 1) return `Tomorrow, ${monthDay}`
  return d.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })
}

export default function Book() {
  const days = useMemo(buildDays, [])
  const staff = STAFF[0]

  // For each day: the taken times, and whether the whole day is off.
  const [availability, setAvailability] = useState(null)
  const busy = useMemo(
    () => availability && Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy])),
    [availability],
  )
  const [loadError, setLoadError] = useState(false)
  // A service link on the home page (#/book?service=mens-design) arrives with the service chosen.
  const [preselected] = useState(() => serviceIdFromHash(window.location.hash, SERVICES))
  const [step, setStep] = useState(preselected ? 1 : 0)
  const [serviceId, setServiceId] = useState(preselected)
  const [dateKey, setDateKey] = useState(null)
  const [time, setTime] = useState(null)
  const [form, setForm] = useState({ name: '', phone: '', email: '', notes: '' })
  const [errors, setErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [notice, setNotice] = useState('')
  const [done, setDone] = useState(null)

  const service = SERVICES.find((s) => s.id === serviceId) || null

  const loadBusy = () =>
    getAvailability(days.map(keyOf))
      .then((result) => {
        setAvailability(result)
        setLoadError(false)
      })
      .catch(() => setLoadError(true))

  useEffect(() => {
    loadBusy()
  }, [])

  // While the time step is open, check again every 30 seconds and whenever the tab comes back
  // into view, so a time someone else just booked turns grey instead of failing at the last step.
  useEffect(() => {
    if (step !== 1) return undefined
    const refresh = () => {
      if (document.visibilityState === 'visible') {
        getAvailability(days.map(keyOf))
          .then(setAvailability)
          .catch(() => {}) // a missed refresh is fine, the next one or the final check catches up
      }
    }
    const timer = window.setInterval(refresh, REFRESH_MS)
    document.addEventListener('visibilitychange', refresh)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', refresh)
    }
  }, [step])

  const slotsByDay = useMemo(() => {
    if (!busy || !service) return {}
    const now = new Date()
    const out = {}
    for (const d of days) {
      const k = keyOf(d)
      out[k] = slotsForDay({
        date: d,
        minutes: service.minutes,
        hours: HOURS,
        busy: busy[k] || [],
        now,
        slotMinutes: SLOT_MINUTES,
      })
    }
    return out
  }, [busy, service, days])

  // Preselect the first day that has openings when the time step opens.
  useEffect(() => {
    if (step !== 1 || dateKey) return
    const first = days.find((d) => (slotsByDay[keyOf(d)] || []).length > 0)
    if (first) setDateKey(keyOf(first))
  }, [step, dateKey, slotsByDay, days])

  // If the time you picked gets taken while the page is open, say so and let you pick again.
  useEffect(() => {
    if (time === null || !dateKey || !busy) return
    if (!(slotsByDay[dateKey] || []).includes(time)) {
      setTime(null)
      setNotice('That time was just taken. Pick another time.')
    }
  }, [slotsByDay])

  const reach = !service ? 0 : time === null ? 1 : 2

  function chooseService(id) {
    if (id !== serviceId) setTime(null)
    setServiceId(id)
    setStep(1)
  }

  function updateField(e) {
    setForm((f) => ({ ...f, [e.target.name]: e.target.value }))
  }

  async function submit(e) {
    e.preventDefault()
    const err = {}
    if (form.name.trim().length < 2) err.name = 'Enter your full name.'
    if (form.phone.replace(/\D/g, '').length < 10) err.phone = 'Enter a 10-digit mobile number so Vic can reach you.'
    if (form.email.trim() && !/^\S+@\S+\.\S+$/.test(form.email.trim())) err.email = "That email doesn't look right. Use something like name@example.com, or leave it blank."
    setErrors(err)
    if (Object.keys(err).length) return

    setSubmitting(true)
    setNotice('')
    try {
      const booking = await createBooking({
        staffId: staff.id,
        serviceId: service.id,
        dateKey,
        start: time,
        minutes: service.minutes,
        name: form.name.trim(),
        phone: form.phone.trim(),
        email: form.email.trim(),
        notes: form.notes.trim(),
      })
      setDone(booking)
    } catch (ex) {
      if (ex instanceof SlotTakenError) {
        setNotice('That time was just taken. Pick another time.')
        setTime(null)
        setStep(1)
        await loadBusy()
      } else {
        // A message the API wrote for customers (a bad phone number, too many bookings) is shown as it is.
        setNotice(
          ex && ex.friendly ? (
            ex.message
          ) : (
            <>
              Something went wrong saving your booking. Try again, or call <PhoneLink />.
            </>
          ),
        )
      }
    } finally {
      setSubmitting(false)
    }
  }

  if (done) {
    const booked = SERVICES.find((s) => s.id === done.serviceId)
    return (
      <main className="book book-done">
        <section className="done" aria-live="polite">
          <Reveal as="h1" from="above" className="done-headline">
            <span>{SUCCESS_HEADLINE[0]}</span> <span className="done-line-2">{SUCCESS_HEADLINE[1]}</span>
          </Reveal>
          <h2 className="book-title done-booked">You're booked, {done.name.split(' ')[0]}.</h2>
          <p className="code" aria-label="Confirmation code">{done.code}</p>
          <p>
            <strong>{booked.name}</strong> with {staff.name}
          </p>
          <p>
            {dayLabel(fromKey(done.dateKey))} at {fmtTime(done.start)}
          </p>
          <p>{payLine(booked)}</p>
          <p className="muted">
            Need to change it? Call <PhoneLink /> and quote your code.
          </p>
          <a className="btn btn-primary" href="#/">Back to home</a>
        </section>
      </main>
    )
  }

  const selectedDay = dateKey ? fromKey(dateKey) : null
  const daySlots = dateKey ? slotsByDay[dateKey] || [] : []
  const openTimes = new Set(daySlots)
  const dayStarts =
    selectedDay && service
      ? startsForDay({ date: selectedDay, minutes: service.minutes, hours: HOURS, slotMinutes: SLOT_MINUTES })
      : []

  return (
    <main className="book">
      <a className="back" href="#/">Back to home</a>
      <h1 className="book-title">Book with {staff.name}</h1>

      <ol className="steps" aria-label="Booking steps">
        {STEPS.map((label, i) => (
          <li key={label}>
            <button
              type="button"
              className={i < step ? 'done' : ''}
              aria-current={i === step ? 'step' : undefined}
              disabled={i > reach}
              onClick={() => setStep(i)}
            >
              <span className="n">{i < step ? '✓' : i + 1}</span>
              {label}
            </button>
          </li>
        ))}
      </ol>

      {loadError && (
        <p className="notice" role="alert">
          Could not load times. Refresh the page to try again.
        </p>
      )}
      {notice && (
        <p className="notice" role="alert">
          {notice}
        </p>
      )}

      {step === 0 && (
        <section className="panel">
          <h2>Choose a service</h2>
          {SERVICES.map((s) => (
            <button
              key={s.id}
              type="button"
              className="opt"
              aria-pressed={serviceId === s.id}
              onClick={() => chooseService(s.id)}
            >
              <span className="name">{s.name}</span>
              <span className="meta">{s.minutes} min</span>
              <span className="leader" />
              <span className="price">{priceLabel(s)}</span>
              {s.note && <span className="note">{s.note}</span>}
            </button>
          ))}
        </section>
      )}

      {step === 1 && (
        <section className="panel">
          <h2>Pick a day and time</h2>
          {!busy && !loadError && <p className="muted">Loading times…</p>}
          {busy && (
            <>
              <div className="days" role="group" aria-label="Days">
                {days.map((d) => {
                  const k = keyOf(d)
                  const closed = !HOURS[d.getDay()] || !!availability[k]?.dayOff // shop closed that weekday, or Vic took the day off
                  const free = (slotsByDay[k] || []).length
                  return (
                    <button
                      key={k}
                      type="button"
                      className="day"
                      aria-pressed={dateKey === k}
                      disabled={!free}
                      onClick={() => {
                        setDateKey(k)
                        setTime(null)
                      }}
                    >
                      <span className="dow">{d.toLocaleDateString(undefined, { weekday: 'short' })}</span>
                      <span className="dom">{d.getDate()}</span>
                      <span className="tag">{closed ? 'Closed' : free ? '' : 'Full'}</span>
                    </button>
                  )
                })}
              </div>

              {selectedDay && dayStarts.length > 0 && (
                <>
                  <div className="times" role="group" aria-label={`Times on ${dayLabel(selectedDay)}`}>
                    {dayStarts.map((m) => {
                      const open = openTimes.has(m)
                      return (
                        <button
                          key={m}
                          type="button"
                          className="time"
                          aria-pressed={time === m}
                          disabled={!open}
                          onClick={() => {
                            setTime(m)
                            setNotice('')
                          }}
                        >
                          {fmtTime(m)}
                          {!open && <span className="sr-only"> (unavailable)</span>}
                        </button>
                      )
                    })}
                  </div>
                  {daySlots.length < dayStarts.length && <p className="times-note">Greyed-out times are not available.</p>}
                </>
              )}
              {selectedDay && dayStarts.length === 0 && <p className="empty">No times on this day. Pick another day.</p>}
              {!selectedDay && <p className="empty">Pick a day to see open times.</p>}
            </>
          )}
          <div className="actions">
            <button type="button" className="btn" onClick={() => setStep(0)}>
              Back
            </button>
            <button type="button" className="btn btn-primary" disabled={time === null} onClick={() => setStep(2)}>
              Continue
            </button>
          </div>
        </section>
      )}

      {step === 2 && service && (
        <section className="panel">
          <h2>Your details</h2>
          <dl className="summary">
            <div>
              <dt>Service</dt>
              <dd>
                {service.name} ({service.minutes} min), {priceLabel(service)}
              </dd>
            </div>
            <div>
              <dt>When</dt>
              <dd>
                {dayLabel(fromKey(dateKey))} at {fmtTime(time)}
              </dd>
            </div>
          </dl>

          <form onSubmit={submit} noValidate>
            <div className="field">
              <label htmlFor="f-name">Full name</label>
              <input id="f-name" name="name" maxLength={LIMITS.name} autoComplete="name" value={form.name} onChange={updateField} aria-invalid={!!errors.name} aria-describedby="e-name" />
              <p className="err" id="e-name">{errors.name}</p>
            </div>
            <div className="field">
              <label htmlFor="f-phone">Mobile number</label>
              <input id="f-phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" value={form.phone} onChange={updateField} aria-invalid={!!errors.phone} aria-describedby="e-phone" />
              <p className="err" id="e-phone">{errors.phone}</p>
            </div>
            <div className="field">
              <label htmlFor="f-email">
                Email <span className="hint">(optional, for a confirmation)</span>
              </label>
              <input id="f-email" name="email" type="email" autoComplete="email" value={form.email} onChange={updateField} aria-invalid={!!errors.email} aria-describedby="e-email" />
              <p className="err" id="e-email">{errors.email}</p>
            </div>
            <div className="field">
              <label htmlFor="f-notes">
                Notes for Vic <span className="hint">(optional)</span>
              </label>
              <textarea id="f-notes" name="notes" rows={3} maxLength={LIMITS.notes} value={form.notes} onChange={updateField} aria-describedby="notes-count" />
              <p
                id="notes-count"
                className={nearLimit(form.notes.length, LIMITS.notes) ? 'counter counter-near' : 'counter'}
              >
                {countLabel(form.notes.length, LIMITS.notes)}
              </p>
            </div>
            <p className="muted">Pay at the shop. No card needed to book.</p>
            <div className="actions">
              <button type="button" className="btn" onClick={() => setStep(1)}>
                Back
              </button>
              <button type="submit" className="btn btn-primary" disabled={submitting}>
                {submitting ? 'Confirming…' : 'Confirm booking'}
              </button>
            </div>
          </form>
        </section>
      )}
    </main>
  )
}
