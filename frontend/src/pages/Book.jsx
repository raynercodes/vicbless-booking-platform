import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import LogoCheckerboard from '../components/LogoCheckerboard.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, SMS_CONSENT, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'
import { clearPending, loadPending, readReturn, savePending, tabStorage } from '../lib/paymentReturn.js'
import { slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'

const STEPS = ['Service', 'Time', 'Details']
const REFRESH_MS = 30000 // how often the time grid re-checks while it is open
const payLine = (s, paidOnline = false) => {
  if (paidOnline) {
    return s.from
      ? `Paid online. You paid the starting price of $${s.price}. Vic settles any difference at the shop.`
      : `Paid online. $${s.price} total, thank you.`
  }
  return s.from
    ? `Pay at the shop. Starts at $${s.price}, the final price depends on what you get.`
    : `Pay at the shop. $${s.price} total.`
}

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
  // Vic's services and how long an appointment is on each weekday (he edits both in his dashboard).
  const shop = useShopSettings()
  const SERVICES = shop.services

  // For each day: the taken times, and whether the whole day is off.
  const [availability, setAvailability] = useState(null)
  const busy = useMemo(
    () => availability && Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy])),
    [availability],
  )
  const [loadError, setLoadError] = useState(false)
  // Back from Stripe: #/book?paid=CODE (they paid) or #/book?payment=cancelled (they did not). What they were booking was
  // remembered before they left, so they land on their confirmation, or back on their filled-in form to try again.
  const [back] = useState(() => {
    const kind = readReturn(window.location.hash)
    return kind ? { ...kind, pending: loadPending(tabStorage()) } : null
  })
  const resumed = back && back.kind === 'cancelled' ? back.pending : null
  // A service link on the home page (#/book?service=mens-design) arrives with the service chosen.
  const [preselected] = useState(() => (resumed ? resumed.request.serviceId : serviceIdFromHash(window.location.hash, shop.services)))
  const [step, setStep] = useState(resumed ? 2 : preselected ? 1 : 0)
  const [serviceId, setServiceId] = useState(preselected)
  const [dateKey, setDateKey] = useState(resumed ? resumed.request.dateKey : null)
  const [time, setTime] = useState(resumed ? resumed.request.time : null)
  const [form, setForm] = useState(resumed ? { ...resumed.request.form } : { name: '', phone: '', email: '', notes: '', sms: false, pay: 'shop' })
  const [errors, setErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [notice, setNotice] = useState(
    back && back.kind === 'cancelled'
      ? "Your payment wasn't completed. Your time is only held for 10 minutes, so pay now or choose to pay at the shop."
      : '',
  )
  // They paid: the booking they made before leaving, or just its code if this browser forgot the rest.
  const [done, setDone] = useState(() => {
    if (!back || back.kind !== 'paid') return null
    const saved = back.pending && back.pending.booking.code === back.code ? back.pending.booking : null
    return { ...(saved || { code: back.code, name: '', serviceId: '', dateKey: null, start: null }), payment: 'paid' }
  })
  // A time held for this customer while they pay shows as taken to everyone, themselves included, so it is not "just taken".
  const ownHold = resumed ? { dateKey: resumed.request.dateKey, time: resumed.request.time } : null

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
        minutes: slotFor(shop, d),
        hours: HOURS,
        busy: busy[k] || [],
        now,
        slotMinutes: slotFor(shop, d),
      })
    }
    return out
  }, [busy, service, days, shop])

  // Preselect the first day that has openings when the time step opens.
  useEffect(() => {
    if (step !== 1 || dateKey) return
    const first = days.find((d) => (slotsByDay[keyOf(d)] || []).length > 0)
    if (first) setDateKey(keyOf(first))
  }, [step, dateKey, slotsByDay, days])

  // If the time you picked gets taken while the page is open, say so and let you pick again.
  useEffect(() => {
    if (time === null || !dateKey || !busy) return
    if (ownHold && ownHold.dateKey === dateKey && ownHold.time === time) return
    if (!(slotsByDay[dateKey] || []).includes(time)) {
      setTime(null)
      setNotice('That time was just taken. Pick another time.')
    }
  }, [slotsByDay])

  const reach = !service ? 0 : time === null ? 1 : 2
  // Card payment is offered when the API says it is set up and the service costs something; the choice is theirs.
  const canPayOnline = shop.payOnline === true && !!service && service.price > 0
  const wantsOnline = canPayOnline && form.pay === 'online'

  function chooseService(id) {
    if (id !== serviceId) setTime(null)
    setServiceId(id)
    setStep(1)
  }

  function updateField(e) {
    const { name, type, checked, value } = e.target
    setForm((f) => ({ ...f, [name]: type === 'checkbox' ? checked : value }))
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
        minutes: slotFor(shop, fromKey(dateKey)),
        name: form.name.trim(),
        phone: form.phone.trim(),
        email: form.email.trim(),
        notes: form.notes.trim(),
        smsConsent: form.sms,
        payment: wantsOnline ? 'online' : 'shop',
        returnTo: window.location.origin,
      })
      if (booking.checkoutUrl) {
        // Off to Stripe to pay. What they were booking is remembered for when they come back (or turn back).
        savePending(tabStorage(), { request: { serviceId: service.id, dateKey, time, form: { ...form, pay: 'online' } }, booking })
        window.location.assign(booking.checkoutUrl)
        return // the page is leaving: the button keeps saying so
      }
      clearPending(tabStorage())
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
              Something went wrong saving your booking. Try again, or email <EmailLink />.
            </>
          ),
        )
      }
    }
    setSubmitting(false)
  }

  if (done) {
    // the booking remembers the name it was made with; the price comes from the current list when it is still there
    const current = SERVICES.find((s) => s.id === done.serviceId)
    const booked = { ...(current || { price: 0 }), name: done.serviceName || (current && current.name) || 'Appointment' }
    return (
      <main className="book book-done">
        <LogoCheckerboard />
        <section className="done" aria-live="polite">
          <Reveal as="h1" from="above" className="done-headline">
            <span>{SUCCESS_HEADLINE[0]}</span> <span className="done-line-2">{SUCCESS_HEADLINE[1]}</span>
          </Reveal>
          <h2 className="book-title done-booked">{done.name ? `You're booked, ${done.name.split(' ')[0]}.` : "You're booked."}</h2>
          <p className="code" aria-label="Confirmation code">{done.code}</p>
          {done.dateKey ? (
            <>
              <p>
                <strong>{booked.name}</strong> with {staff.name}
              </p>
              <p>
                {dayLabel(fromKey(done.dateKey))} at {fmtTime(done.start)}
              </p>
              {current && <p>{payLine(booked, done.payment === 'paid')}</p>}
            </>
          ) : (
            <p>Your payment went through and Vic has your booking. Thank you!</p>
          )}
          <p className="muted">
            Need to change it? Email <EmailLink /> and quote your code.
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
      ? startsForDay({ date: selectedDay, minutes: slotFor(shop, selectedDay), hours: HOURS, slotMinutes: slotFor(shop, selectedDay) })
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
                {service.name} ({slotFor(shop, fromKey(dateKey))} min), {priceLabel(service)}
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
              <label className="consent" htmlFor="f-sms">
                <input id="f-sms" name="sms" type="checkbox" checked={form.sms} onChange={updateField} />
                <span>{SMS_CONSENT}</span>
              </label>
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
            {canPayOnline ? (
              <fieldset className="pay-choice">
                <legend>How would you like to pay?</legend>
                <label className="pay-option" htmlFor="f-pay-shop">
                  <input id="f-pay-shop" type="radio" name="pay" value="shop" checked={!wantsOnline} onChange={updateField} />
                  <span>
                    <strong>Pay at the shop</strong>
                    <span className="hint">No card needed to book.</span>
                  </span>
                </label>
                <label className="pay-option" htmlFor="f-pay-online">
                  <input id="f-pay-online" type="radio" name="pay" value="online" checked={wantsOnline} onChange={updateField} />
                  <span>
                    <strong>Pay online now{service.from ? ` ($${service.price} starting price)` : ` ($${service.price})`}</strong>
                    <span className="hint">
                      Secure card payment with Stripe. Your time is held for 10 minutes while you pay.
                      {service.from ? ' Vic settles any difference at the shop.' : ''}
                    </span>
                  </span>
                </label>
              </fieldset>
            ) : (
              <p className="muted">Pay at the shop. No card needed to book.</p>
            )}
            <div className="actions">
              <button type="button" className="btn" onClick={() => setStep(1)}>
                Back
              </button>
              <button type="submit" className="btn btn-primary" disabled={submitting}>
                {submitting ? (wantsOnline ? 'Taking you to payment…' : 'Confirming…') : wantsOnline ? 'Continue to payment' : 'Confirm booking'}
              </button>
            </div>
          </form>
        </section>
      )}
    </main>
  )
}
