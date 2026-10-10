#!/usr/bin/env bash
# Vicbless round 5:
#   - Cancel and Remove block are real boxes with a big tap target
#   - a whole day off shows to customers as Closed instead of Full
#   - the customer's email shows on the schedule, tap to email them
#   - the home page words are back to the video overlay, the banner look is gone
#   - Vic's dashboard gets the same menu as the home page (Settings, plus View site and Sign out)
#   - a Pick a date button on the schedule
# Run from inside frontend/, after add-vicbless-admin-step2.sh:  bash update-vicbless-round5.sh
# REPLACES the files listed in this script (tell me first if you edited any of them), DELETES
# src/components/HomeTagline.jsx, and removes the HOME_TAGLINE_STYLE lines from src/config.js.
# Everything else in src/config.js, such as the phone number, is left exactly as it is.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json || [ ! -f src/admin/ConfirmBox.jsx ]; then
  echo "Run this from inside the frontend/ folder, after add-vicbless-admin-step2.sh."
  exit 1
fi

mkdir -p src/lib src/pages src/components src/admin

cat > src/lib/format.js <<'VICBLESS_EOF'
// Small shared display helpers.

// price is the starting price. from: true shows it as "$65+".
export const priceLabel = (s) => (s.from ? `$${s.price}+` : `$${s.price}`)

// The footer line. Takes a date so the year is always the current one.
export const copyrightLine = (date = new Date()) => `\u00A9 ${date.getFullYear()} VICBLESS`

// Reads the service from a link like "#/book?service=mens-design".
// Returns null when there is no service or it is not a real one.
export function serviceIdFromHash(hash, services) {
  const query = (hash || '').split('?')[1] || ''
  const id = new URLSearchParams(query).get('service')
  return services.some((s) => s.id === id) ? id : null
}

// Turns a phone number as people write it, like "(912) 555-0199", into a link that opens the
// phone's dialer: "tel:+19125550199". A 10-digit number is treated as a US number.
// Returns '' when there are no digits, so callers can fall back to plain text.
export function telHref(phone) {
  const raw = String(phone ?? '').trim()
  const digits = raw.replace(/\D/g, '')
  if (!digits) return ''
  if (raw.startsWith('+')) return `tel:+${digits}`
  if (digits.length === 10) return `tel:+1${digits}`
  if (digits.length === 11 && digits.startsWith('1')) return `tel:+${digits}`
  return `tel:${digits}`
}

// How a phone number is shown to people: (912) 555-0142, however it was typed.
// US numbers (10 digits, or 11 starting with 1) are formatted. Anything else, such as an
// international number, is shown exactly as it was typed.
export function formatPhone(phone) {
  const raw = String(phone ?? '').trim()
  if (/^\+(?!1\b)/.test(raw)) return raw
  const digits = raw.replace(/\D/g, '')
  const ten = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits
  if (ten.length !== 10) return raw
  return `(${ten.slice(0, 3)}) ${ten.slice(3, 6)}-${ten.slice(6)}`
}

// A link that opens the email app, addressed to `email`, with a subject filled in.
// Returns '' when it does not look like an email address, so callers can show plain text instead.
export function mailtoHref(email, subject = '') {
  const address = String(email ?? '').trim()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address)) return ''
  const safe = address.replace(/[?&#%]/g, (c) => encodeURIComponent(c))
  return subject ? `mailto:${safe}?subject=${encodeURIComponent(subject)}` : `mailto:${safe}`
}
VICBLESS_EOF

cat > src/lib/format.test.js <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { priceLabel, copyrightLine, serviceIdFromHash, telHref, formatPhone, mailtoHref } from './format.js'

describe('priceLabel', () => {
  it('shows a plus for starting prices', () => {
    expect(priceLabel({ price: 65, from: true })).toBe('$65+')
    expect(priceLabel({ price: 55 })).toBe('$55')
  })
})

describe('copyrightLine', () => {
  it('uses the year of the date it is given', () => {
    expect(copyrightLine(new Date(2026, 5, 1))).toBe('\u00A9 2026 VICBLESS')
    expect(copyrightLine(new Date(2031, 0, 1))).toBe('\u00A9 2031 VICBLESS')
  })

  it('defaults to the current year', () => {
    expect(copyrightLine()).toBe(`\u00A9 ${new Date().getFullYear()} VICBLESS`)
  })

  it('rolls over at midnight on New Year', () => {
    expect(copyrightLine(new Date(2026, 11, 31, 23, 59))).toContain('2026')
    expect(copyrightLine(new Date(2027, 0, 1, 0, 0))).toContain('2027')
  })
})

describe('serviceIdFromHash', () => {
  const services = [{ id: 'mens-cut' }, { id: 'mens-design' }]

  it('reads a real service from the link', () => {
    expect(serviceIdFromHash('#/book?service=mens-design', services)).toBe('mens-design')
  })

  it('returns null with no service, an unknown service, or an empty hash', () => {
    expect(serviceIdFromHash('#/book', services)).toBeNull()
    expect(serviceIdFromHash('#/book?service=nope', services)).toBeNull()
    expect(serviceIdFromHash('', services)).toBeNull()
    expect(serviceIdFromHash(undefined, services)).toBeNull()
  })
})

describe('telHref', () => {
  it('turns a US number written any common way into a dialer link', () => {
    expect(telHref('(912) 555-0199')).toBe('tel:+19125550199')
    expect(telHref('912-555-0199')).toBe('tel:+19125550199')
    expect(telHref('912.555.0199')).toBe('tel:+19125550199')
    expect(telHref('9125550199')).toBe('tel:+19125550199')
    expect(telHref(' (912) 555 0199 ')).toBe('tel:+19125550199')
  })

  it('handles a leading 1 and international numbers', () => {
    expect(telHref('1 (912) 555-0199')).toBe('tel:+19125550199')
    expect(telHref('+1 912 555 0199')).toBe('tel:+19125550199')
    expect(telHref('+44 20 7946 0958')).toBe('tel:+442079460958')
  })

  it('falls back to the plain digits for other lengths', () => {
    expect(telHref('555-0199')).toBe('tel:5550199')
  })

  it('returns an empty string when there is nothing to dial', () => {
    expect(telHref('')).toBe('')
    expect(telHref(null)).toBe('')
    expect(telHref(undefined)).toBe('')
    expect(telHref('call us')).toBe('')
  })
})

describe('formatPhone', () => {
  it('shows a US number the same way however it was typed', () => {
    for (const typed of ['9125550142', '912-555-0142', '912.555.0142', '(912) 555-0142', ' 912 555 0142 ', '1 912 555 0142', '+1 912 555 0142', '1-912-555-0142']) {
      expect(formatPhone(typed), typed).toBe('(912) 555-0142')
    }
  })

  it('leaves anything that is not a US number exactly as typed', () => {
    expect(formatPhone('+44 20 7946 0958')).toBe('+44 20 7946 0958')
    expect(formatPhone('555-0142')).toBe('555-0142')
    expect(formatPhone('ask for Vic')).toBe('ask for Vic')
  })

  it('handles empty values', () => {
    expect(formatPhone('')).toBe('')
    expect(formatPhone(null)).toBe('')
    expect(formatPhone(undefined)).toBe('')
  })

  it('pairs with telHref: the displayed number and the dialled number are the same number', () => {
    for (const typed of ['9125550142', '(912) 555-0142', '1 912 555 0142']) {
      expect(telHref(typed)).toBe('tel:+19125550142')
    }
  })
})

describe('mailtoHref', () => {
  it('makes a link that opens the email app', () => {
    expect(mailtoHref('marcus@example.com')).toBe('mailto:marcus@example.com')
  })

  it('fills in the subject, safely encoded', () => {
    expect(mailtoHref('a@b.com', 'Your Vicbless appointment on Thursday, October 8 at 4:15 pm')).toBe(
      'mailto:a@b.com?subject=Your%20Vicbless%20appointment%20on%20Thursday%2C%20October%208%20at%204%3A15%20pm',
    )
    expect(mailtoHref('a@b.com', 'Cuts & fades? #1')).toBe('mailto:a@b.com?subject=Cuts%20%26%20fades%3F%20%231')
  })

  it('trims spaces around the address and keeps plus-addresses intact', () => {
    expect(mailtoHref('  marcus+cuts@example.com  ')).toBe('mailto:marcus+cuts@example.com')
  })

  it('cannot be tricked into adding extra mail headers through the address', () => {
    // a second @ or a real line break: the address is refused outright
    expect(mailtoHref('a@b.com?bcc=evil@x.com')).toBe('')
    expect(mailtoHref('a@b.com&cc=evil@x.com')).toBe('')
    expect(mailtoHref('a@b.com\nBcc: evil@x.com')).toBe('')
    // otherwise ? & and % are encoded, so they stay part of the address and start no new header
    expect(mailtoHref('a@b.com?bcc=evil')).toBe('mailto:a@b.com%3Fbcc=evil')
    expect(mailtoHref('a@b.com&cc=evil')).toBe('mailto:a@b.com%26cc=evil')
    expect(mailtoHref('a@b.com%0d%0aBcc:x')).toBe('mailto:a@b.com%250d%250aBcc:x')
  })

  it('returns nothing for things that are not an email address, so plain text is shown instead', () => {
    for (const bad of ['', '   ', 'marcus', 'marcus@', '@example.com', 'a@b', 'a b@c.com', 'a@b .com', null, undefined, 42]) {
      expect(mailtoHref(bad), String(bad)).toBe('')
    }
  })
})
VICBLESS_EOF

cat > src/lib/mockStore.js <<'VICBLESS_EOF'
// MOCK storage shared by the customer-facing mock (lib/api.js) and the admin mock.
// It exists so that cancelling or blocking time in the dashboard changes what customers see.
// It goes away when the real backend exists.

import { HOURS, SLOT_MINUTES } from '../config.js'
import { fromKey, slotStarts } from './availability.js'

const KEYS = {
  bookings: 'vicbless.bookings', // bookings made through the site
  blocks: 'vicbless.blocks', // time Vic blocked off
  cancelledSamples: 'vicbless.cancelledSamples', // sample bookings Vic cancelled in the dashboard
}

function read(key) {
  try {
    const list = JSON.parse(localStorage.getItem(key) || '[]')
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

function write(key, list) {
  try {
    localStorage.setItem(key, JSON.stringify(list))
  } catch {
    /* storage blocked: the change just will not survive a reload */
  }
}

export const readBookings = () => read(KEYS.bookings)
export const writeBookings = (list) => write(KEYS.bookings, list)
export const readBlocks = () => read(KEYS.blocks)
export const writeBlocks = (list) => write(KEYS.blocks, list)
export const readCancelledSamples = () => read(KEYS.cancelledSamples)
export const writeCancelledSamples = (list) => write(KEYS.cancelledSamples, list)

// The time blocks on `dateKey` that are covered by blocked-off time.
export function blockedStartsFor(dateKey) {
  const blocks = readBlocks().filter((b) => b.dateKey === dateKey)
  const out = new Set()
  if (blocks.length === 0) return out
  for (const s of slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)) {
    if (blocks.some((b) => s >= b.start && s < b.end)) out.add(s)
  }
  return out
}

// True when Vic has taken the whole day off. Customers see such a day as Closed, not Full.
export function isDayOff(dateKey) {
  return readBlocks().some((b) => b.dateKey === dateKey && b.whole)
}
VICBLESS_EOF

cat > src/lib/api.js <<'VICBLESS_EOF'
// Mock data layer. This is the ONLY file to replace when the backend exists.
//
//   getAvailability(dateKeys) -> GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD
//        { '2026-10-09': { busy: [660, 695], dayOff: false }, ... }  taken times, and whether the day is off
//   createBooking(data) ->  POST /bookings   (return 409 when the slot is taken)
//
// Keep the same return shapes and the pages will not need to change.
// Until then it fakes busy times per day and keeps bookings, blocked time and cancelled
// sample bookings in localStorage (through mockStore.js), so a booked, blocked or freed time
// shows up on the customer grid and in Vic's dashboard alike.

import { HOURS, SLOT_MINUTES } from '../config.js'
import { blocksFor, fromKey, slotStarts } from './availability.js'
import { blockedStartsFor, isDayOff, readBookings, readCancelledSamples, writeBookings } from './mockStore.js'

const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export class SlotTakenError extends Error {
  constructor() {
    super('That time was just taken.')
    this.name = 'SlotTakenError'
  }
}

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

function busyFor(dateKey) {
  const busy = new Set()

  // pretend-busy blocks, unless Vic cancelled them in the dashboard
  const cancelled = new Set(readCancelledSamples().filter((c) => c.dateKey === dateKey).map((c) => c.start))
  for (const s of slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)) {
    if (hash(dateKey + s) % 100 < 30 && !cancelled.has(s)) busy.add(s)
  }

  // real bookings made through the site
  for (const b of readBookings()) {
    if (b.dateKey !== dateKey) continue
    for (let k = 0; k < blocksFor(b.minutes, SLOT_MINUTES); k++) busy.add(b.start + k * SLOT_MINUTES)
  }

  // time Vic blocked off
  for (const s of blockedStartsFor(dateKey)) busy.add(s)

  return [...busy]
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off (shown to customers as "Closed" instead of "Full").
export async function getAvailability(dateKeys) {
  await delay(150)
  return Object.fromEntries(dateKeys.map((k) => [k, { busy: busyFor(k), dayOff: isDayOff(k) }]))
}

// Just the taken times, for code that does not care about days off (the admin mock).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

export async function createBooking(payload) {
  await delay(500)
  const busy = new Set(busyFor(payload.dateKey))
  for (let k = 0; k < blocksFor(payload.minutes, SLOT_MINUTES); k++) {
    if (busy.has(payload.start + k * SLOT_MINUTES)) throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  const booking = { ...payload, code }
  writeBookings([...readBookings(), booking])
  return booking
}
VICBLESS_EOF

cat > src/pages/Book.jsx <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import PhoneLink from '../components/PhoneLink.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, SERVICES, SLOT_MINUTES, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { priceLabel, serviceIdFromHash } from '../lib/format.js'

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
    if (form.email.trim() && !/^\S+@\S+\.\S+$/.test(form.email.trim())) err.email = 'Enter a valid email, or leave it blank.'
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
        setNotice(
          <>
            Something went wrong saving your booking. Try again, or call <PhoneLink />.
          </>,
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
              <input id="f-name" name="name" autoComplete="name" value={form.name} onChange={updateField} aria-invalid={!!errors.name} aria-describedby="e-name" />
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
              <textarea id="f-notes" name="notes" rows={3} value={form.notes} onChange={updateField} />
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
VICBLESS_EOF

cat > src/pages/Home.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import SiteHeader from '../components/SiteHeader.jsx'
import SiteFooter from '../components/SiteFooter.jsx'
import ShopInfo from '../components/ShopInfo.jsx'
import Statement from '../components/Statement.jsx'
import { useSettings } from '../lib/useSettings.js'
import Socials from '../components/Socials.jsx'
import { CTA_TEXT, HOME_TAGLINE } from '../config.js'

const PlayIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M8 5v14l11-7z" fill="currentColor" />
  </svg>
)

const PauseIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor" />
  </svg>
)

// The pan finishes after the visitor has scrolled 85% of the video's height,
// so the movement reads as stronger and faster.
const PAN_DISTANCE = 0.85

export default function Home() {
  const reduceMotion = useSettings().motion === 'off'
  const heroRef = useRef(null)
  const videoRef = useRef(null)
  const [playing, setPlaying] = useState(false)

  // Keep the button in step with the real video state (autoplay can be blocked).
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    const sync = () => setPlaying(!v.paused)
    v.addEventListener('play', sync)
    v.addEventListener('pause', sync)
    sync()
    return () => {
      v.removeEventListener('play', sync)
      v.removeEventListener('pause', sync)
    }
  }, [])

  // Autoplay, including on iPhone. React does not write the muted attribute that iOS
  // wants before it will autoplay, so set it on the element and call play() ourselves.
  // If the phone still blocks it (Low Power Mode, for example), the first touch or
  // scroll starts it. The pause/play button is left alone so it never fights itself.
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    v.muted = true
    v.defaultMuted = true
    v.setAttribute('muted', '')

    const events = ['touchstart', 'pointerdown', 'scroll', 'keydown']
    const stopWaiting = () => events.forEach((name) => window.removeEventListener(name, onGesture))
    const attempt = () => {
      const result = v.play()
      if (result && typeof result.then === 'function') result.then(stopWaiting).catch(() => {})
      else stopWaiting()
    }
    function onGesture(e) {
      if (e.target instanceof Element && e.target.closest('.hero-toggle')) return
      attempt()
    }

    events.forEach((name) => window.addEventListener(name, onGesture, { passive: true }))
    attempt()
    return stopWaiting
  }, [])

  // Pan: as the page scrolls, the footage slides from its top to its bottom
  // (--pan goes 0 to 1 over the first 85% of the hero's height of scrolling). Skipped when Motion is off.
  useEffect(() => {
    if (reduceMotion) return undefined
    const hero = heroRef.current
    if (!hero) return undefined
    let frame = 0
    const update = () => {
      frame = 0
      const h = hero.offsetHeight || 1
      const p = Math.min(1, Math.max(0, window.scrollY / (h * PAN_DISTANCE)))
      hero.style.setProperty('--pan', p.toFixed(3))
    }
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (frame) window.cancelAnimationFrame(frame)
      hero.style.removeProperty('--pan')
    }
  }, [reduceMotion])

  function toggle() {
    const v = videoRef.current
    if (!v) return
    if (v.paused) v.play().catch(() => {})
    else v.pause()
  }

  return (
    <>
      <SiteHeader />

      <main>
        <section ref={heroRef} className="hero" aria-label="Vicbless presentation">
          <img className="hero-backdrop" src="/media/vicbless-poster.jpg" alt="" aria-hidden="true" />
          <video
            ref={videoRef}
            className="hero-video"
            src="/media/vicbless-presentation.mp4"
            poster="/media/vicbless-poster.jpg"
            muted
            loop
            playsInline
            preload="auto"
            autoPlay
            aria-label="Vicbless presentation video"
          />

          {HOME_TAGLINE.length > 0 && (
            <p className="hero-tagline">
              {HOME_TAGLINE.map((line, i) => (
                <span
                  key={line}
                  className={HOME_TAGLINE.length > 1 && i === HOME_TAGLINE.length - 1 ? 'hero-tagline-accent' : undefined}
                  style={{ '--i': i }}
                >
                  {line}{' '}
                </span>
              ))}
            </p>
          )}

          <div className="hero-cta">
            <a className="btn btn-primary book-now" href="#/book">
              {CTA_TEXT}
            </a>
          </div>

          <div className="hero-socials">
            <Socials />
          </div>

          <button
            type="button"
            className="hero-toggle"
            onClick={toggle}
            aria-label={playing ? 'Pause video' : 'Play video'}
          >
            {playing ? <PauseIcon /> : <PlayIcon />}
          </button>
        </section>

        <Statement />

        <ShopInfo />
      </main>

      <SiteFooter />
    </>
  )
}
VICBLESS_EOF

cat > src/components/SiteMenu.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import { SOCIAL } from '../config.js'
import { useSettings } from '../lib/useSettings.js'
import { InstagramIcon, TikTokIcon } from './Socials.jsx'

const BarsIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M4 7h16M4 12h16M4 17h16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const CloseIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const Chevron = () => (
  <svg className="chev" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

// A whole row you tap to flip a setting on or off.
function Switch({ id, label, hint, checked, onToggle }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-labelledby={`${id}-label`}
      aria-describedby={`${id}-hint`}
      className="setting"
      onClick={onToggle}
    >
      <span className="setting-text">
        <span id={`${id}-label`} className="setting-label">
          {label}
        </span>
        <span id={`${id}-hint`} className="setting-hint">
          {hint}
        </span>
      </span>
      <span className="switch-state" aria-hidden="true">
        {checked ? 'On' : 'Off'}
      </span>
      <span className="switch-track" aria-hidden="true" />
    </button>
  )
}

// `children` are extra rows shown at the bottom of the menu (the dashboard adds View site and Sign out).
export default function SiteMenu({ children }) {
  const [open, setOpen] = useState(false)
  const [section, setSection] = useState(null) // 'socials' | 'settings' | null, one open at a time
  const wrapRef = useRef(null)
  const buttonRef = useRef(null)
  const { motion, theme, setMotion, setTheme } = useSettings()

  // Escape closes the menu (and returns focus to the button), a tap outside closes it too.
  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape') {
        setOpen(false)
        buttonRef.current?.focus()
      }
    }
    const onPointerDown = (e) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPointerDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPointerDown)
    }
  }, [open])

  // Closing the menu collapses the dropdowns, so it always opens fresh.
  useEffect(() => {
    if (!open) setSection(null)
  }, [open])

  const toggleSection = (name) => setSection((current) => (current === name ? null : name))

  return (
    <div className="site-menu" ref={wrapRef}>
      <button
        ref={buttonRef}
        type="button"
        className="menu-toggle"
        aria-label="Menu"
        aria-expanded={open}
        aria-controls="site-menu-panel"
        onClick={() => setOpen((o) => !o)}
      >
        {open ? <CloseIcon /> : <BarsIcon />}
      </button>

      <div id="site-menu-panel" className="menu-panel" hidden={!open}>
        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'socials'}
            aria-controls="menu-socials"
            onClick={() => toggleSection('socials')}
          >
            Socials
            <Chevron />
          </button>
          <div id="menu-socials" className="menu-sub" hidden={section !== 'socials'}>
            <a className="menu-link" href={SOCIAL.tiktok} target="_blank" rel="noopener noreferrer">
              <TikTokIcon />
              TikTok
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
            <a className="menu-link" href={SOCIAL.instagram} target="_blank" rel="noopener noreferrer">
              <InstagramIcon />
              Instagram
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </div>
        </div>

        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'settings'}
            aria-controls="menu-settings"
            onClick={() => toggleSection('settings')}
          >
            Settings
            <Chevron />
          </button>
          <div id="menu-settings" className="menu-sub" hidden={section !== 'settings'}>
            <Switch
              id="set-motion"
              label="Motion"
              hint="Parallax, scroll effects and animations"
              checked={motion === 'on'}
              onToggle={() => setMotion(motion === 'on' ? 'off' : 'on')}
            />
            <Switch
              id="set-theme"
              label="Dark mode"
              hint="Switch off for light mode"
              checked={theme === 'dark'}
              onToggle={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
            />
          </div>
        </div>

        {children && <div className="menu-extra">{children}</div>}
      </div>
    </div>
  )
}
VICBLESS_EOF

cat > src/styles.css <<'VICBLESS_EOF'
/* Vicbless: dark purple-black ground, light lavender ink, small purple accents. */
:root {
  --bg: #0a0612;
  --surface: #130c21;
  --ink: #f6efff;
  --muted: #b3a5c9;
  --line: #2f2347;
  --purple: #a855f7;
  --accent: #c084fc;
  --on-accent: #0a0612;
  --danger: #ff8aa0;
  --header-bg: rgba(10, 6, 18, 0.92);
  /* Text and accent that sit on top of photos and video. Always light, in either theme. */
  --on-media: #f6efff;
  --accent-media: #c084fc;
  --font: 'Archivo', 'Arial Narrow', system-ui, -apple-system, 'Segoe UI', sans-serif;
  color-scheme: dark;
}

/* Light theme. Switched with the Dark mode setting (see src/lib/settings.js). */
html[data-theme='light'] {
  --bg: #f8f4fd;
  --surface: #ffffff;
  --ink: #1b1030;
  --muted: #5a4a73;
  --line: #ddd0ee;
  --purple: #7e22ce;
  --accent: #7c3aed;
  --on-accent: #ffffff;
  --danger: #b3123b;
  --header-bg: rgba(248, 244, 253, 0.92);
  color-scheme: light;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font);
  font-size: 1rem;
  line-height: 1.5;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

button,
input,
textarea {
  font: inherit;
  color: inherit;
}

button {
  cursor: pointer;
}

:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- Home: pinned logo bar, video hero, shop info, footer ---------- */
:root {
  --brand-h: calc(84px + env(safe-area-inset-top, 0px));
}

/* Logo bar. Sticky, so it follows the page while scrolling. The logo sits in the
   middle column and the social links on the right. */
.brand {
  position: sticky;
  top: 0;
  z-index: 10;
  height: var(--brand-h);
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  padding: env(safe-area-inset-top, 0px) 16px 0;
  background: var(--header-bg);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}

.logo {
  margin: 0;
  width: min(100%, 880px);
}

.brand .logo {
  grid-column: 2;
  width: auto;
  height: 60px;
}

.logo svg {
  display: block;
  width: 100%;
  height: auto;
  filter: drop-shadow(0 0 3px var(--purple));
}

.brand .logo svg {
  width: auto;
  height: 100%;
}

.logo-link {
  display: block;
  height: 100%;
  color: inherit;
  border-radius: 6px;
}

.logo path {
  fill: var(--ink);
  stroke: var(--purple);
  stroke-width: 6;
  stroke-linejoin: round;
  paint-order: stroke;
}

.brand .socials {
  grid-column: 3;
  justify-self: end;
}

.socials {
  display: flex;
  align-items: center;
  gap: 2px;
}

.social {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  color: var(--ink);
  border-radius: 50%;
}

.social:hover {
  color: var(--accent);
}

/* The hero fills whatever is left of the first screen under the pinned bar. */
.hero {
  position: relative;
  height: calc(100vh - var(--brand-h));
  height: calc(100svh - var(--brand-h));
  min-height: 440px;
  overflow: hidden;
  background: var(--bg);
}

/* Blurred, dimmed poster fills the sides when the screen is wider than the video. */
.hero-backdrop {
  position: absolute;
  top: -48px;
  left: -48px;
  width: calc(100% + 96px);
  height: calc(100% + 96px);
  object-fit: cover;
  filter: blur(36px) brightness(0.5) saturate(1.2);
}

.hero-video {
  position: absolute;
  top: 0;
  left: 50%;
  /* Much taller than the window (165%): --pan (0 to 1, set while scrolling) slides the
     footage up through the extra 65% (that is 39.4% of the video's own height), so the
     view travels from the top of the video to the bottom. */
  transform: translate3d(-50%, calc(var(--pan, 0) * -39.4%), 0);
  will-change: transform;
  height: 165%;
  width: auto;
  max-width: 100%;
  aspect-ratio: 720 / 1084;
  object-fit: cover;
  background: var(--surface);
}

/* Soft shade behind the button so it reads over any frame of the video. */
.hero::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse 60% 40% at 50% 50%, rgba(10, 6, 18, 0.55), rgba(10, 6, 18, 0) 70%);
}

/* Words at the top of the video, right under the logo. A dark fade behind them keeps them readable
   on any frame. They use fixed light colours (like the other text on the video), so they look the
   same in dark and light mode, and they slide down into place when the page opens. */
.hero-tagline {
  position: absolute;
  top: 0;
  right: 0;
  left: 0;
  z-index: 1;
  margin: 0;
  padding: 18px 16px 48px;
  font-size: clamp(1.5rem, 6.2vw, 2.7rem);
  font-weight: 900;
  line-height: 1;
  letter-spacing: -0.01em;
  text-align: center;
  font-variation-settings: 'wdth' 70;
  color: var(--on-media);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.55);
  background: linear-gradient(to bottom, rgba(10, 6, 18, 0.72), rgba(10, 6, 18, 0));
  pointer-events: none;
}

.hero-tagline span {
  display: block;
  animation: tagline-in 0.8s cubic-bezier(0.2, 0.7, 0.2, 1) both;
  animation-delay: calc(0.3s + var(--i, 0) * 0.16s);
}

.hero-tagline .hero-tagline-accent {
  color: var(--accent-media);
}

@keyframes tagline-in {
  from {
    opacity: 0;
    transform: translateY(-22px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

.hero-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  pointer-events: none;
}

.hero .book-now {
  pointer-events: auto;
  max-width: min(88vw, 460px);
  padding: 20px 44px;
  font-size: clamp(1.15rem, 4.6vw, 1.5rem);
  line-height: 1.15;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  animation: ring 2.8s ease-out infinite;
}

@keyframes ring {
  0% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  }
  70%,
  100% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 22px rgba(192, 132, 252, 0);
  }
}

.hero-toggle {
  position: absolute;
  right: 14px;
  bottom: 14px;
  z-index: 2;
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--on-media);
  background: rgba(10, 6, 18, 0.6);
  border: 2px solid rgba(246, 239, 255, 0.7);
  border-radius: 50%;
}

.hero-toggle:hover {
  border-color: var(--on-media);
}

.info {
  max-width: 960px;
  margin: 0 auto;
  padding: 72px 20px 48px;
}

.info-grid {
  display: grid;
  grid-template-columns: 1.2fr 1fr;
  gap: 48px;
}

.info h2 {
  margin: 0 0 14px;
  font-size: 1.5rem;
  font-weight: 800;
  font-variation-settings: 'wdth' 85;
}

.menu,
.hours {
  margin: 0 0 32px;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.menu li {
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
}

.menu-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.menu-name {
  font-weight: 700;
}

.menu-leader {
  flex: 1;
  min-width: 12px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.menu-price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.menu-meta {
  margin: 2px 0 0;
  font-size: 0.9rem;
  color: var(--muted);
}

.hours li {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
}

.hours li span:last-child {
  text-align: right;
}

.hours .closed {
  color: var(--muted);
}

.info address {
  font-style: normal;
  color: var(--muted);
}

/* Phone numbers are tap-to-call links. */
.phone-link {
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.phone-link:hover {
  text-decoration-thickness: 2px;
}

.info address .phone-link {
  display: inline-block;
  padding: 8px 0;
}

.notice .phone-link {
  color: inherit;
}

.info-cta {
  display: flex;
  justify-content: center;
  margin-top: 40px;
}

.site-foot {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 32px 20px calc(36px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.9rem;
}

.site-foot .copy {
  margin: 0;
  font-weight: 700;
  letter-spacing: 0.04em;
}

/* Quiet credit: small, muted, faint underline. Still readable, just out of the way. */
.site-foot .credit {
  margin: 4px 0 0;
  font-size: 0.74rem;
}

.site-foot .credit a {
  display: inline-block;
  padding: 6px 4px;
  color: var(--muted);
  text-decoration: underline;
  text-decoration-color: var(--line);
  text-underline-offset: 3px;
}

.site-foot .credit a:hover {
  color: var(--ink);
  text-decoration-color: currentColor;
}

/* Social links along the bottom of the video. */
.hero-socials {
  position: absolute;
  left: 50%;
  bottom: 14px;
  z-index: 2;
  transform: translateX(-50%);
}

.hero-socials .socials {
  padding: 2px 8px;
  background: rgba(10, 6, 18, 0.6);
  border: 1px solid rgba(246, 239, 255, 0.25);
  border-radius: 999px;
}

.hero-socials .social {
  color: var(--on-media);
}

.hero-socials .social:hover {
  color: var(--accent-media);
}

/* Scroll reveal: content below the video fades up as it enters the screen. */
.reveal {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0.7, 0.2, 1);
  transition-delay: var(--d, 0ms);
}

.reveal.in {
  opacity: 1;
  transform: none;
}

/* Branded CTA on each haircut type: a purple box, matching the other booking buttons. */
.svc-cta {
  display: inline-block;
  margin-top: 12px;
  padding: 12px 24px;
  font-weight: 800;
  text-align: center;
  color: var(--on-accent);
  text-decoration: none;
  background: var(--accent);
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.svc-cta:hover {
  filter: brightness(1.08);
}

/* Menu: three-line button on the left of the pinned bar, opens a panel under it. */
.brand .site-menu {
  grid-column: 1;
  justify-self: start;
}

.menu-toggle {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--ink);
  background: none;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.menu-toggle:hover {
  border-color: var(--accent);
}

/* The bar is the positioned parent, so the panel hangs just under it. */
.menu-panel {
  position: absolute;
  top: calc(100% + 6px);
  left: 12px;
  z-index: 20;
  width: min(330px, calc(100vw - 24px));
  max-height: calc(100vh - var(--brand-h) - 24px);
  max-height: calc(100svh - var(--brand-h) - 24px);
  padding: 8px;
  overflow-y: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.45);
}

.menu-group + .menu-group {
  margin-top: 4px;
}

.menu-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  font-size: 1.05rem;
  font-weight: 800;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.menu-head:hover {
  background: var(--bg);
}

.menu-head .chev {
  transition: transform 0.2s ease;
}

.menu-head[aria-expanded='true'] .chev {
  transform: rotate(180deg);
}

.menu-sub {
  padding: 2px 4px 8px;
}

.menu-link {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 48px;
  padding: 10px 12px;
  font-weight: 600;
  color: var(--ink);
  text-decoration: none;
  border-radius: 8px;
}

.menu-link:hover {
  color: var(--accent);
  background: var(--bg);
}

.setting {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  min-height: 56px;
  padding: 8px 12px;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.setting:hover {
  background: var(--bg);
}

.setting-text {
  display: flex;
  flex: 1;
  flex-direction: column;
}

.setting-label {
  font-weight: 700;
}

.setting-hint {
  font-size: 0.82rem;
  color: var(--muted);
}

.switch-state {
  min-width: 2em;
  font-size: 0.9rem;
  font-weight: 700;
  text-align: right;
  color: var(--muted);
}

.switch-track {
  position: relative;
  flex: none;
  width: 46px;
  height: 26px;
  background: var(--line);
  border: 2px solid var(--line);
  border-radius: 999px;
  transition: background 0.2s ease, border-color 0.2s ease;
}

.switch-track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 18px;
  height: 18px;
  background: var(--ink);
  border-radius: 50%;
  transition: transform 0.2s ease;
}

.setting[aria-checked='true'] .switch-track {
  background: var(--accent);
  border-color: var(--accent);
}

.setting[aria-checked='true'] .switch-track::after {
  background: var(--on-accent);
  transform: translateX(20px);
}

/* Extra rows at the bottom of the menu (the dashboard's View site and Sign out). */
.menu-extra {
  margin-top: 4px;
  padding-top: 4px;
  border-top: 1px solid var(--line);
}

button.menu-link {
  width: 100%;
  text-align: left;
  background: none;
  border: 0;
}

/* Words that drop down into place instead of lifting up. */
.reveal-down {
  transform: translateY(-28px);
}

/* Photo section under the video. The photo is 130% of the section's height and slides
   through it with --pan (see Statement.jsx), so it has its own parallax. The headline sits
   at the top and the stacked words at the bottom, which keeps the faces clear in the middle. */
.statement {
  position: relative;
  color: var(--on-media);
  display: flex;
  min-height: 780px;
  min-height: max(780px, 100svh);
  padding: 56px 20px 48px;
  overflow: hidden;
  background: var(--bg);
}

.statement-img {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 130%;
  object-fit: cover;
  object-position: 20% 50%;
  transform: translate3d(0, calc(var(--pan, 0.5) * -23.1%), 0);
  will-change: transform;
}

/* Darkens the top and bottom where the text sits, leaves the middle (the faces) clear. */
.statement::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(
    to bottom,
    rgba(10, 6, 18, 0.78) 0%,
    rgba(10, 6, 18, 0.35) 28%,
    rgba(10, 6, 18, 0) 45%,
    rgba(10, 6, 18, 0) 55%,
    rgba(10, 6, 18, 0.55) 72%,
    rgba(10, 6, 18, 0.9) 100%
  );
}

.statement-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 32px;
  width: 100%;
  max-width: 1100px;
  margin: 0 auto;
}

.statement h2 {
  max-width: 18ch;
  margin: 0 0 14px;
  font-size: clamp(1.5rem, 5.2vw, 2.6rem);
  font-weight: 900;
  line-height: 1.08;
  letter-spacing: 0.01em;
  font-variation-settings: 'wdth' 85;
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.6);
}

.statement p {
  max-width: 44ch;
  margin: 0;
  font-size: clamp(1rem, 2.6vw, 1.2rem);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.7);
}

.statement-words {
  margin: 0;
  padding: 0;
  list-style: none;
}

.statement-words li {
  font-size: clamp(2.7rem, 13vw, 6.8rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-shadow: 0 4px 24px rgba(0, 0, 0, 0.55);
}

.statement-words .statement-place {
  color: var(--accent-media);
}

/* Centred call to action over the photo: a see-through box with a light outline.
   Fixed light colours, so it reads the same in dark and light mode. */
.statement-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  padding: 0 20px;
  pointer-events: none;
}

.statement-cta-link {
  display: block;
  max-width: min(86vw, 440px);
  padding: 18px 36px;
  font-size: clamp(1.1rem, 4.6vw, 1.4rem);
  font-weight: 800;
  line-height: 1.15;
  text-align: center;
  color: var(--on-media);
  text-decoration: none;
  background: rgba(10, 6, 18, 0.28);
  border: 2px solid rgba(246, 239, 255, 0.85);
  border-radius: 14px;
  -webkit-backdrop-filter: blur(3px);
  backdrop-filter: blur(3px);
  pointer-events: auto;
  transition: background 0.2s ease, color 0.2s ease, border-color 0.2s ease;
}

.statement-cta-link:hover {
  color: #0a0612;
  background: var(--accent-media);
  border-color: var(--accent-media);
}

@media (min-width: 900px) {
  /* Taller section and slightly smaller words on wide screens, so the centred button always
     has a free band to sit in between the paragraph above and the words below. */
  .statement {
    min-height: max(840px, 92svh);
  }

  .statement-words li {
    font-size: clamp(3.4rem, 5.4vw, 4.8rem);
  }

  /* On wide screens the words sit on the left, so shade the left side as well. */
  .statement::after {
    background: linear-gradient(90deg, rgba(10, 6, 18, 0.75) 0%, rgba(10, 6, 18, 0.4) 40%, rgba(10, 6, 18, 0) 70%),
      linear-gradient(
        to bottom,
        rgba(10, 6, 18, 0.6) 0%,
        rgba(10, 6, 18, 0) 30%,
        rgba(10, 6, 18, 0) 60%,
        rgba(10, 6, 18, 0.7) 100%
      );
  }
}

@media (max-width: 760px) {
  .info-grid {
    grid-template-columns: 1fr;
    gap: 36px;
  }
}

@media (max-width: 520px) {
  .hero .book-now {
    padding: 16px 32px;
  }
}

/* Motion off: the Motion setting (which starts from the visitor's system setting). */
html[data-motion='off'] .hero .book-now,
html[data-motion='off'] .hero-tagline span {
  animation: none;
}

html[data-motion='off'] .reveal,
html[data-motion='off'] .reveal-down {
  opacity: 1;
  transform: none;
  transition: none;
}

html[data-motion='off'] .chev,
html[data-motion='off'] .switch-track,
html[data-motion='off'] .switch-track::after {
  transition: none;
}

/* ---------- Buttons ---------- */
.btn {
  display: inline-block;
  padding: 13px 24px;
  border: 2px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--ink);
  font-weight: 700;
  text-align: center;
  text-decoration: none;
}

.btn:not(:disabled):hover {
  border-color: var(--accent);
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.btn-primary:not(:disabled):hover {
  filter: brightness(1.08);
}

.book-now {
  padding: 18px 64px;
  border-radius: 999px;
  font-size: 1.35rem;
  font-weight: 800;
  letter-spacing: 0.01em;
}

/* ---------- Booking ---------- */
.book {
  max-width: 640px;
  margin: 0 auto;
  padding: calc(24px + env(safe-area-inset-top, 0px)) 20px 72px;
}

.back {
  display: inline-block;
  margin-bottom: 8px;
  color: var(--muted);
  text-decoration: none;
  padding: 6px 0;
}

.back:hover {
  color: var(--ink);
}

.book-title {
  margin: 0 0 20px;
  font-size: clamp(2rem, 7vw, 2.8rem);
  font-weight: 900;
  line-height: 1.05;
  font-variation-settings: 'wdth' 85;
}

.steps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.steps button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: none;
  border: 2px solid var(--line);
  border-radius: 999px;
  color: var(--muted);
  font-weight: 600;
  font-size: 0.92rem;
}

.steps button[aria-current='step'] {
  border-color: var(--accent);
  color: var(--ink);
}

.steps button.done {
  color: var(--ink);
}

.steps button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.steps .n {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--line);
  font-size: 0.8rem;
}

.steps [aria-current='step'] .n {
  background: var(--accent);
  color: var(--on-accent);
}

.panel {
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
  padding: 22px;
}

.panel h2 {
  margin: 0 0 16px;
  font-size: 1.4rem;
  font-weight: 800;
}

.opt {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  width: 100%;
  margin-bottom: 10px;
  padding: 14px;
  text-align: left;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.opt:hover {
  border-color: var(--accent);
}

.opt[aria-pressed='true'] {
  border-color: var(--accent);
  box-shadow: inset 4px 0 0 var(--accent);
}

.opt .name {
  font-weight: 700;
}

.opt .meta {
  color: var(--muted);
  font-size: 0.9rem;
}

.opt .leader {
  flex: 1;
  min-width: 16px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.opt .price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.opt .note {
  flex-basis: 100%;
  margin-top: 2px;
  font-size: 0.88rem;
  font-weight: 400;
  color: var(--muted);
}

.days {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 2px 2px 12px;
  overflow-x: auto;
}

.day {
  flex: none;
  width: 72px;
  padding: 10px 6px;
  text-align: center;
  line-height: 1.2;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.day .dow {
  display: block;
  font-size: 0.85rem;
  color: var(--muted);
}

.day .dom {
  display: block;
  font-size: 1.4rem;
  font-weight: 800;
}

.day .tag {
  display: block;
  min-height: 1em;
  font-size: 0.75rem;
  color: var(--muted);
}

.day[aria-pressed='true'] {
  border-color: var(--accent);
}

.day:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(98px, 1fr));
  gap: 8px;
  margin: 12px 0 4px;
}

.time {
  padding: 10px 6px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.time:hover:not(:disabled) {
  border-color: var(--accent);
}

/* Times that are taken or blocked stay visible, greyed out and struck through. */
.time:disabled {
  color: var(--muted);
  text-decoration: line-through;
  opacity: 0.45;
  cursor: not-allowed;
}

.times-note {
  margin: 8px 0 0;
  font-size: 0.85rem;
  color: var(--muted);
}

.time[aria-pressed='true'] {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.empty {
  padding: 18px;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

.summary {
  margin: 0 0 20px;
  padding: 14px 16px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.summary div + div {
  margin-top: 10px;
}

.summary dt {
  font-size: 0.85rem;
  color: var(--muted);
}

.summary dd {
  margin: 0;
  font-weight: 600;
}

.field {
  margin-bottom: 14px;
}

.field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}

.field input,
.field textarea {
  width: 100%;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.field input:focus,
.field textarea:focus {
  border-color: var(--accent);
}

.field input[aria-invalid='true'] {
  border-color: var(--danger);
}

.hint {
  font-weight: 400;
  font-size: 0.85rem;
  color: var(--muted);
}

.err {
  min-height: 1.3em;
  margin: 4px 0 0;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--danger);
}

.notice {
  margin: 0 0 16px;
  padding: 12px 14px;
  font-weight: 600;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.muted {
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 20px;
}

.done {
  padding-top: 24px;
}

.done p {
  margin: 0 0 8px;
}

.code {
  display: inline-block;
  margin: 4px 0 16px !important;
  padding: 6px 14px;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.done .btn {
  margin-top: 16px;
}

/* Big headline on the booking success screen. */
.done-headline {
  margin: 0 0 28px;
  font-size: clamp(2.6rem, 11vw, 4.6rem);
  font-weight: 900;
  line-height: 0.95;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.done-headline span {
  display: block;
}

.done-headline .done-line-2 {
  color: var(--accent);
}

.book-title.done-booked {
  margin: 0 0 12px;
  font-size: clamp(1.5rem, 5.5vw, 2rem);
}

/* The success screen is wider than the booking steps, so the headline can be big. */
.book.book-done {
  max-width: 960px;
}

.book-done .done p {
  max-width: 60ch;
}

@media (max-width: 520px) {
  .book-now {
    padding: 16px 48px;
  }
  .panel {
    padding: 16px;
  }
}

html[data-motion='off'] {
  scroll-behavior: auto;
}
VICBLESS_EOF

cat > src/admin/mockAdminApi.js <<'VICBLESS_EOF'
// MOCK admin data layer. Replace with calls to the real backend later. Shapes to keep:
//   signIn(password)        ->  POST   /admin/login
//   getDay(dateKey)         ->  GET    /admin/schedule?date=YYYY-MM-DD   { items, blocks } for that day
//   cancelBooking(item)     ->  DELETE /admin/bookings/{id}              (frees the time)
//   addBlock(block)         ->  POST   /admin/blocks                     (409 if it overlaps a booking or block)
//   removeBlock(id)         ->  DELETE /admin/blocks/{id}
//
// For now it shows real bookings made through the site in this browser, plus sample bookings for the
// blocks the public mock marks as taken, so the schedule and the customer-facing time grid always
// agree. Sample ones are marked so they are never mistaken for real customers.

import { HOURS, SERVICES, SLOT_MINUTES } from '../config.js'
import { getBusy } from '../lib/api.js'
import { blocksFor, fromKey, slotStarts } from '../lib/availability.js'
import {
  blockedStartsFor,
  readBlocks,
  readBookings,
  readCancelledSamples,
  writeBlocks,
  writeBookings,
  writeCancelledSamples,
} from '../lib/mockStore.js'
import { findConflicts } from './blocks.js'

const SESSION_KEY = 'vicbless.admin.session'
const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export function isSignedIn() {
  try {
    return localStorage.getItem(SESSION_KEY) === 'preview'
  } catch {
    return false
  }
}

export async function signIn(password) {
  await delay(300)
  if (!String(password ?? '').trim()) throw new Error('Enter your password.')
  try {
    localStorage.setItem(SESSION_KEY, 'preview')
  } catch {
    /* storage blocked: the session just will not survive a reload */
  }
}

export function signOut() {
  try {
    localStorage.removeItem(SESSION_KEY)
  } catch {
    /* nothing to clear */
  }
}

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

const FIRST = ['Marcus', 'Dre', 'Tyrell', 'Jamal', 'Chris', 'Devon', 'Andre', 'Malik', 'Terrence', 'Jordan', 'Isaiah', 'Cameron']
const LAST = ['J.', 'W.', 'B.', 'H.', 'T.', 'R.', 'M.', 'G.']
const NOTES = ['Wants it shorter on the sides', 'Bringing his son next', 'Regular, same as last time', 'Beard line-up too if there is time']

function sampleItem(dateKey, start) {
  const h = hash(`${dateKey}|sample|${start}`)
  const service = SERVICES[h % SERVICES.length]
  return {
    id: `sample-${dateKey}-${start}`,
    dateKey,
    source: 'sample',
    start,
    minutes: service.minutes,
    serviceId: service.id,
    name: `${FIRST[h % FIRST.length]} ${LAST[(h >>> 4) % LAST.length]}`,
    phone: `(555) 010-${String(100 + (h % 90)).padStart(4, '0').slice(-4)}`,
    // about two in three sample customers left an email, so the layout can be seen with and without
    email: h % 3 === 0 ? '' : `${FIRST[h % FIRST.length].toLowerCase()}${h % 97}@example.com`,
    notes: h % 4 === 0 ? NOTES[(h >>> 8) % NOTES.length] : '',
    code: 'VB-SAMPLE',
  }
}

export async function getDay(dateKey) {
  const busyByDay = await getBusy([dateKey])
  const busy = busyByDay[dateKey] || []
  const real = readBookings().filter((b) => b.dateKey === dateKey)

  const items = real.map((b) => ({
    id: b.code,
    dateKey,
    source: 'online',
    start: b.start,
    minutes: b.minutes,
    serviceId: b.serviceId,
    name: b.name,
    phone: b.phone,
    email: b.email || '',
    notes: b.notes || '',
    code: b.code,
  }))

  // real bookings and blocked time are never shown as sample bookings
  const covered = new Set(blockedStartsFor(dateKey))
  for (const b of real) {
    for (let k = 0; k < blocksFor(b.minutes, SLOT_MINUTES); k++) covered.add(b.start + k * SLOT_MINUTES)
  }
  for (const start of [...busy].sort((a, b) => a - b)) {
    if (!covered.has(start)) items.push(sampleItem(dateKey, start))
  }
  items.sort((a, b) => a.start - b.start)

  const blocks = readBlocks()
    .filter((b) => b.dateKey === dateKey)
    .sort((a, b) => a.start - b.start)

  return { dateKey, items, blocks }
}

// Frees the time. A real booking is removed; a sample one is remembered as cancelled.
export async function cancelBooking(item) {
  await delay(250)
  if (item.source === 'online') {
    writeBookings(readBookings().filter((b) => !(b.code === item.id && b.dateKey === item.dateKey && b.start === item.start)))
  } else {
    const list = readCancelledSamples()
    if (!list.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
      writeCancelledSamples([...list, { dateKey: item.dateKey, start: item.start }])
    }
  }
}

// The "backend" has the final say: it refuses a block that overlaps a booking or other blocked time,
// even if the screen did not catch it (for example when something changed a moment ago).
export async function addBlock({ dateKey, start, end, note = '', whole = false }) {
  await delay(250)
  const day = await getDay(dateKey)
  const grid = slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)
  const conflicts = findConflicts({ range: { start, end }, grid, items: day.items, blocks: day.blocks, slotMinutes: SLOT_MINUTES })
  if (conflicts.bookings.length > 0 || conflicts.blocks.length > 0) {
    const error = new Error('That time overlaps a booking or blocked time.')
    error.code = 'CONFLICT'
    throw error
  }
  const block = {
    id: `blk-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    dateKey,
    start,
    end,
    note: String(note ?? '').trim().slice(0, 80),
    whole: !!whole,
  }
  writeBlocks([...readBlocks(), block])
  return block
}

export async function removeBlock(id) {
  await delay(150)
  writeBlocks(readBlocks().filter((b) => b.id !== id))
}
VICBLESS_EOF

cat > src/admin/JumpToDate.jsx <<'VICBLESS_EOF'
import { useRef } from 'react'

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

// "Pick a date": a big pill button that opens the phone's own date picker.
// The real date field sits invisibly on top of the whole button, so a tap lands on the field itself.
// That is what makes it reliable on iPhones and Android, where the native picker opens on a direct tap.
export default function JumpToDate({ value, onPick }) {
  const inputRef = useRef(null)

  return (
    <label className="admin-jump">
      <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
        <rect x="3.5" y="5" width="17" height="15.5" rx="3" fill="none" stroke="currentColor" strokeWidth="2" />
        <path d="M3.5 10h17M8 3v4M16 3v4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
      <span>Pick a date</span>
      <input
        ref={inputRef}
        type="date"
        value={value}
        aria-label="Pick a date to jump to"
        onChange={(e) => {
          if (DATE_PATTERN.test(e.target.value)) onPick(e.target.value) // clearing the field does nothing
        }}
        onClick={() => {
          try {
            inputRef.current?.showPicker?.() // opens it on desktop browsers too
          } catch {
            /* the browser already opened it, or cannot: nothing to do */
          }
        }}
      />
    </label>
  )
}
VICBLESS_EOF

cat > src/admin/Schedule.jsx <<'VICBLESS_EOF'
import { useEffect, useMemo, useRef, useState } from 'react'
import { HOURS, SERVICES, SLOT_MINUTES } from '../config.js'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { formatPhone, mailtoHref, telHref } from '../lib/format.js'
import BlockOff from './BlockOff.jsx'
import ConfirmBox from './ConfirmBox.jsx'
import JumpToDate from './JumpToDate.jsx'
import { describeRange } from './blocks.js'
import { cancelBooking, getDay, removeBlock } from './mockAdminApi.js'
import { buildDayRows } from './schedule.js'

const Chevron = ({ direction }) => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path
      d={direction === 'left' ? 'M15 5l-7 7 7 7' : 'M9 5l7 7-7 7'}
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
)

function BookingCard({ item, confirming, working, onAsk, onKeep, onYes }) {
  const service = SERVICES.find((s) => s.id === item.serviceId)
  const serviceName = service ? service.name : 'Appointment'
  const tel = telHref(item.phone)
  // Tapping the email opens his email app, addressed to the customer, with the subject already written.
  const mail = mailtoHref(
    item.email,
    `Your Vicbless appointment on ${fromKey(item.dateKey).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })} at ${fmtTime(item.start)}`,
  )
  return (
    <article className="admin-card">
      <h3>
        {item.name}
        {item.source === 'sample' && <span className="admin-sample-badge">sample</span>}
      </h3>
      <p className="admin-meta">
        {serviceName}, {item.minutes} min
      </p>
      {item.phone &&
        (tel ? (
          <a className="phone-link" href={tel}>
            {formatPhone(item.phone)}
          </a>
        ) : (
          <span>{formatPhone(item.phone)}</span>
        ))}
      {item.email &&
        (mail ? (
          <a className="email-link" href={mail}>
            {item.email}
          </a>
        ) : (
          <span className="email-link">{item.email}</span>
        ))}
      {item.notes && <p className="admin-notes">{item.notes}</p>}

      {confirming ? (
        <ConfirmBox
          label={`Cancel ${item.name}'s booking?`}
          keepLabel="Keep it"
          yesLabel="Yes, cancel it"
          workingLabel="Cancelling…"
          working={working}
          onKeep={onKeep}
          onYes={onYes}
        >
          Cancel {item.name}'s {fmtTime(item.start)} {serviceName}? The time opens up for other customers. The customer is not
          told yet.
        </ConfirmBox>
      ) : (
        <button type="button" className="admin-box-btn admin-box-danger" onClick={onAsk} aria-label={`Cancel ${item.name}'s ${fmtTime(item.start)} booking`}>
          Cancel
        </button>
      )}
    </article>
  )
}

function BlockCard({ block, confirming, working, onAsk, onKeep, onYes }) {
  const range = describeRange(block.start, block.end)
  return (
    <article className="admin-card admin-card-block">
      <h3>{block.whole ? 'Day off' : 'Blocked'}</h3>
      <p className="admin-meta">{range}</p>
      {block.note && <p className="admin-notes">{block.note}</p>}

      {confirming ? (
        <ConfirmBox
          label="Open this time back up?"
          keepLabel="Keep it blocked"
          yesLabel="Yes, open it up"
          workingLabel="Opening…"
          working={working}
          onKeep={onKeep}
          onYes={onYes}
        >
          Open {range} back up? Customers will be able to book it again.
        </ConfirmBox>
      ) : (
        <button type="button" className="admin-box-btn" onClick={onAsk} aria-label={`Remove block ${range}`}>
          Remove block
        </button>
      )}
    </article>
  )
}

export default function Schedule() {
  const [dateKey, setDateKey] = useState(() => keyOf(new Date()))
  const [state, setState] = useState({ status: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const [confirm, setConfirm] = useState(null) // { kind: 'cancel' | 'unblock', id }
  const [working, setWorking] = useState(false)
  const [actionError, setActionError] = useState('')
  const [flash, setFlash] = useState('')
  const [blockOpen, setBlockOpen] = useState(false)
  const dateKeyRef = useRef(dateKey)
  dateKeyRef.current = dateKey

  useEffect(() => {
    let alive = true
    setState({ status: 'loading' })
    getDay(dateKey)
      .then((day) => alive && setState({ status: 'ready', day }))
      .catch(() => alive && setState({ status: 'error' }))
    return () => {
      alive = false
    }
  }, [dateKey, attempt])

  // Moving to another day closes anything that was open.
  useEffect(() => {
    setConfirm(null)
    setActionError('')
    setFlash('')
    setBlockOpen(false)
  }, [dateKey])

  // The confirmation message fades after a few seconds.
  useEffect(() => {
    if (!flash) return undefined
    const timer = setTimeout(() => setFlash(''), 8000)
    return () => clearTimeout(timer)
  }, [flash])

  const date = fromKey(dateKey)
  const today = keyOf(new Date())

  const view = useMemo(
    () =>
      state.status === 'ready'
        ? buildDayRows({
            date: fromKey(dateKey),
            hours: HOURS,
            items: state.day.items,
            blocks: state.day.blocks,
            slotMinutes: SLOT_MINUTES,
          })
        : null,
    [state, dateKey],
  )

  function shift(days) {
    const d = fromKey(dateKey)
    d.setDate(d.getDate() + days)
    setDateKey(keyOf(d))
  }

  // Fetches the day again without the "Loading" flash, so the screen updates in place.
  async function refresh() {
    const day = await getDay(dateKey)
    if (dateKeyRef.current === dateKey) setState({ status: 'ready', day })
  }

  async function run(action, message) {
    setWorking(true)
    setActionError('')
    try {
      await action()
      await refresh()
      setConfirm(null)
      setFlash(message)
    } catch {
      setActionError('That did not work. Nothing was changed. Try again.')
    } finally {
      setWorking(false)
    }
  }

  const askCancel = (item) => setConfirm({ kind: 'cancel', id: item.id })
  const askUnblock = (block) => setConfirm({ kind: 'unblock', id: block.id })
  const keep = () => setConfirm(null)
  const doCancel = (item) =>
    run(() => cancelBooking(item), `Cancelled ${item.name} at ${fmtTime(item.start)}. That time is open again.`)
  const doUnblock = (block) =>
    run(() => removeBlock(block.id), `Opened ${describeRange(block.start, block.end)} back up.`)

  const cardProps = {
    isCancelling: (item) => confirm?.kind === 'cancel' && confirm.id === item.id,
    isUnblocking: (block) => confirm?.kind === 'unblock' && confirm.id === block.id,
    working,
    askCancel,
    askUnblock,
    keep,
    doCancel,
    doUnblock,
  }

  return (
    <section aria-label="Day schedule">
      <div className="admin-day-nav">
        <button type="button" className="admin-icon-btn" aria-label="Previous day" onClick={() => shift(-1)}>
          <Chevron direction="left" />
        </button>
        <div className="admin-day-title">
          <h2>{date.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })}</h2>
          <div className="admin-day-tools">
            {dateKey === today ? (
              <span className="admin-today-tag">Today</span>
            ) : (
              <button type="button" className="admin-link-btn" onClick={() => setDateKey(today)}>
                Back to today
              </button>
            )}
            <JumpToDate value={dateKey} onPick={setDateKey} />
          </div>
        </div>
        <button type="button" className="admin-icon-btn" aria-label="Next day" onClick={() => shift(1)}>
          <Chevron direction="right" />
        </button>
      </div>

      <div role="status" aria-live="polite" className="admin-flash-wrap">
        {flash && <p className="admin-flash">{flash}</p>}
      </div>

      {actionError && (
        <p className="notice" role="alert">
          {actionError}
        </p>
      )}

      {state.status === 'loading' && (
        <p role="status" className="admin-status">
          Loading the day…
        </p>
      )}

      {state.status === 'error' && (
        <div>
          <p className="notice" role="alert">
            Could not load this day.
          </p>
          <button type="button" className="btn" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      )}

      {view && view.closed && <p className="empty">Closed on {date.toLocaleDateString(undefined, { weekday: 'long' })}s.</p>}

      {view && !view.closed && (
        <>
          <div className="admin-summary-row">
            <p className="admin-summary">
              {view.booked} booked, {view.blocked > 0 ? `${view.blocked} blocked, ` : ''}
              {view.open} open
            </p>
            {!blockOpen && (
              <button type="button" className="btn" aria-expanded={false} onClick={() => setBlockOpen(true)}>
                Block off time
              </button>
            )}
          </div>

          {blockOpen && (
            <BlockOff
              dateKey={dateKey}
              items={state.day.items}
              blocks={state.day.blocks}
              onClose={() => setBlockOpen(false)}
              onSaved={async (message) => {
                await refresh()
                setBlockOpen(false)
                setFlash(message)
              }}
            />
          )}

          <ol className="admin-rows">
            {view.groups.map((group, gi) => (
              <GroupRows key={group.open} group={group} previous={view.groups[gi - 1]} {...cardProps} />
            ))}
          </ol>

          {(view.unmatched.length > 0 || view.unmatchedBlocks.length > 0) && (
            <div className="admin-unmatched">
              <h3>Other items on this day</h3>
              <p className="admin-meta">These are not on a regular time block, so they are listed here.</p>
              {view.unmatched.map((item) => (
                <div key={item.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(item.start)}</span>
                  <BookingCard
                    item={item}
                    confirming={cardProps.isCancelling(item)}
                    working={working}
                    onAsk={() => askCancel(item)}
                    onKeep={keep}
                    onYes={() => doCancel(item)}
                  />
                </div>
              ))}
              {view.unmatchedBlocks.map((block) => (
                <div key={block.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(block.start)}</span>
                  <BlockCard
                    block={block}
                    confirming={cardProps.isUnblocking(block)}
                    working={working}
                    onAsk={() => askUnblock(block)}
                    onKeep={keep}
                    onYes={() => doUnblock(block)}
                  />
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </section>
  )
}

function GroupRows({ group, previous, isCancelling, isUnblocking, working, askCancel, askUnblock, keep, doCancel, doUnblock }) {
  return (
    <>
      {previous && (
        <li className="admin-break">
          Break, {fmtTime(previous.close)} to {fmtTime(group.open)}
        </li>
      )}
      {group.rows.map((row) => (
        <li key={row.start} className={`admin-row admin-${row.kind}`}>
          <span className="admin-time">{fmtTime(row.start)}</span>
          <div className="admin-slot">
            {row.kind === 'booking' && (
              <BookingCard
                item={row.item}
                confirming={isCancelling(row.item)}
                working={working}
                onAsk={() => askCancel(row.item)}
                onKeep={keep}
                onYes={() => doCancel(row.item)}
              />
            )}
            {row.kind === 'continues' && <p className="admin-continues">Still with {row.item.name}</p>}
            {row.kind === 'blocked' && (
              <BlockCard
                block={row.block}
                confirming={isUnblocking(row.block)}
                working={working}
                onAsk={() => askUnblock(row.block)}
                onKeep={keep}
                onYes={() => doUnblock(row.block)}
              />
            )}
            {row.kind === 'blocked-continues' && <p className="admin-continues">Still blocked</p>}
            {row.kind === 'open' && <p className="admin-open-label">Open</p>}
          </div>
        </li>
      ))}
    </>
  )
}
VICBLESS_EOF

cat > src/admin/Admin.jsx <<'VICBLESS_EOF'
import { useEffect, useState } from 'react'
import './admin.css'
import Logo from '../components/Logo.jsx'
import SiteMenu from '../components/SiteMenu.jsx'
import { copyrightLine } from '../lib/format.js'
import Greeting from './Greeting.jsx'
import Schedule from './Schedule.jsx'
import SignIn from './SignIn.jsx'
import { pickGreeting } from './greetings.js'
import { isSignedIn, signOut } from './mockAdminApi.js'

const LAST_GREETING_KEY = 'vicbless.admin.lastGreeting'

function readLastGreeting() {
  try {
    return localStorage.getItem(LAST_GREETING_KEY) || ''
  } catch {
    return ''
  }
}

export default function Admin() {
  const [signedIn, setSignedIn] = useState(isSignedIn)

  // One greeting per visit: the sign-in screen and the dashboard show the same one, and the next
  // visit gets a different one.
  const [greeting] = useState(() => pickGreeting({ last: readLastGreeting() }))
  useEffect(() => {
    try {
      localStorage.setItem(LAST_GREETING_KEY, greeting)
    } catch {
      /* storage blocked: the next visit may repeat it, which is harmless */
    }
  }, [greeting])

  // Keep the page out of search results, and give the tab its own title while it is open.
  useEffect(() => {
    const previousTitle = document.title
    document.title = "Vic's dashboard"
    const meta = document.createElement('meta')
    meta.name = 'robots'
    meta.content = 'noindex, nofollow'
    document.head.appendChild(meta)
    return () => {
      document.title = previousTitle
      meta.remove()
    }
  }, [])

  if (!signedIn) return <SignIn greeting={greeting} onSignedIn={() => setSignedIn(true)} />

  return (
    <main className="admin">
      <header className="admin-bar">
        <SiteMenu>
          <a className="menu-link" href="#/">
            View site
          </a>
          <button
            type="button"
            className="menu-link"
            onClick={() => {
              signOut()
              setSignedIn(false)
            }}
          >
            Sign out
          </button>
        </SiteMenu>
        <div className="admin-logo-small">
          <Logo as="div" />
        </div>
        <span aria-hidden="true" />
      </header>

      <Greeting message={greeting} />

      <p className="admin-preview-note">
        Preview data. Bookings made on the site in this browser show up here, along with sample ones marked "sample". Cancelling and blocking time work too, and are saved in this browser only.
      </p>

      <Schedule />

      <footer className="admin-foot">{copyrightLine()}</footer>
    </main>
  )
}
VICBLESS_EOF

cat > src/admin/admin.css <<'VICBLESS_EOF'
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

/* The logo, big on the sign-in screen and small in the dashboard's top bar. */
.admin-logo-large {
  width: min(100%, 360px);
  margin: 12px auto 4px;
}

.admin-logo-large .logo {
  width: 100%;
}

.admin-logo-small .logo {
  width: auto;
  height: 44px;
}

.admin-logo-small .logo svg {
  width: auto;
  height: 100%;
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
VICBLESS_EOF

# the banner look is gone for good
rm -f src/components/HomeTagline.jsx

# remove the HOME_TAGLINE_STYLE switch from the config (the comment and the line), leave everything else alone
if grep -q '^export const HOME_TAGLINE_STYLE' src/config.js; then
  awk '
    /^\/\/ How the home page words are shown/ { skipping = 1 }
    skipping { if ($0 ~ /^export const HOME_TAGLINE_STYLE/) { skipping = 0 } ; next }
    { print }
  ' src/config.js > src/config.js.tmp && mv src/config.js.tmp src/config.js
  # in case the comment had been edited away and only the line was left
  grep -v '^export const HOME_TAGLINE_STYLE' src/config.js > src/config.js.tmp || true
  mv src/config.js.tmp src/config.js
fi

echo ""
echo "Files updated. Running tests..."
npm test
echo ""
echo "Next: npm run dev -- --host"
echo ""
echo "Git commands (not run for you):"
echo "  git add -A"
echo "  git commit -m \"Boxed Cancel, Closed for a day off, customer email link, overlay tagline, dashboard menu, pick a date\""
echo "  git push"
