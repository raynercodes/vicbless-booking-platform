#!/usr/bin/env bash
# Vicbless dashboard: long notes fold up behind "Show more", and Vic can change the time of any booking.
#   - Notes now wrap inside the card (no more sideways scrolling) and long ones show 3 lines with a
#     "Show more" / "Show less" button.
#   - Each booking gets a "Change time" button next to Cancel. Vic picks a new day (today up to a year
#     ahead) and one of its free times. Taken or blocked times are greyed out. In the real app this calls
#     PATCH /api/admin/bookings/{id}, which the backend now has.
# Run from inside frontend/:  bash update-vicbless-dashboard.sh
# Adds src/admin/notes.js, NoteText.jsx, moveTimes.js, MoveBooking.jsx (and tests).
# REPLACES src/admin/Schedule.jsx (tell me first if you edited it). APPENDS to admin.css and mockAdminApi.js.
# Nothing is written unless every check passes, and running it twice is safe.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json || [ ! -f src/admin/Schedule.jsx ] || [ ! -f src/admin/mockAdminApi.js ] || [ ! -f src/admin/admin.css ]; then
  echo "Run this from inside the frontend/ folder, after the dashboard scripts (add-vicbless-admin-step2.sh and update-vicbless-round5.sh)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/notes.js" <<'VICBLESS_EOF'
// Long notes on Vic's schedule: when to fold them up behind "Show more". Pure, so it is easy to test.

export const NOTE_PREVIEW_CHARS = 140 // a note longer than this is folded
export const NOTE_PREVIEW_LINES = 3 // so is one with more line breaks than this

// True when a note is long enough that the card should show a short preview with "Show more".
// Short notes are always shown in full, so there is never a button with nothing behind it.
export function isLongNote(text) {
  const note = String(text ?? '')
  return note.length > NOTE_PREVIEW_CHARS || note.split('\n').length > NOTE_PREVIEW_LINES
}
VICBLESS_EOF
cat > "$STAGE/notes.test.js" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { NOTE_PREVIEW_CHARS, isLongNote } from './notes.js'

describe('isLongNote', () => {
  it('shows short notes in full', () => {
    expect(isLongNote('')).toBe(false)
    expect(isLongNote(undefined)).toBe(false)
    expect(isLongNote('Wants it shorter on the sides')).toBe(false)
    expect(isLongNote('a'.repeat(NOTE_PREVIEW_CHARS))).toBe(false)
  })

  it('folds a note one character over the preview size', () => {
    expect(isLongNote('a'.repeat(NOTE_PREVIEW_CHARS + 1))).toBe(true)
    expect(isLongNote('a'.repeat(500))).toBe(true)
  })

  it('folds a short note with many line breaks', () => {
    expect(isLongNote('one\ntwo\nthree')).toBe(false)
    expect(isLongNote('one\ntwo\nthree\nfour')).toBe(true)
  })
})
VICBLESS_EOF
cat > "$STAGE/NoteText.jsx" <<'VICBLESS_EOF'
import { useId, useState } from 'react'
import { isLongNote } from './notes.js'

const Chevron = ({ open }) => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false" className={open ? 'admin-chevron open' : 'admin-chevron'}>
    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

// A customer's note on Vic's schedule. Short notes show in full. A long one (up to 500 characters) shows
// the first few lines with a "Show more" button, and "Show less" folds it back so the day stays easy to scan.
// The text wraps inside the card, so there is never any side-to-side scrolling.
export default function NoteText({ text, who }) {
  const [open, setOpen] = useState(false)
  const id = useId()
  const long = isLongNote(text)

  return (
    <div className="admin-notes-wrap">
      <p id={id} className={long && !open ? 'admin-notes admin-notes-folded' : 'admin-notes'}>
        {text}
      </p>
      {long && (
        <button
          type="button"
          className="admin-notes-toggle"
          aria-expanded={open}
          aria-controls={id}
          aria-label={`${open ? 'Show less' : 'Show more'} of ${who}'s note`}
          onClick={() => setOpen((v) => !v)}
        >
          <Chevron open={open} />
          {open ? 'Show less' : 'Show more'}
        </button>
      )}
    </div>
  )
}
VICBLESS_EOF
cat > "$STAGE/moveTimes.js" <<'VICBLESS_EOF'
import { blocksFor, keyOf, startsForDay } from '../lib/availability.js'

// Vic can move a booking to any open time from today up to a year ahead (the API enforces the same).
export const MOVE_DAYS_AHEAD = 365

// The earliest and latest day the "new day" field accepts, as YYYY-MM-DD.
export function moveDateRange(today = new Date()) {
  const last = new Date(today.getFullYear(), today.getMonth(), today.getDate() + MOVE_DAYS_AHEAD)
  return { min: keyOf(today), max: keyOf(last) }
}

// The block starts a booking holds, e.g. a 70 minute booking at 12:00 holds 12:00 and 12:35.
export function ownStarts(item, slotMinutes) {
  const out = []
  for (let k = 0; k < blocksFor(item.minutes, slotMinutes); k++) out.push(item.start + k * slotMinutes)
  return out
}

// Every start time on the chosen day, each marked so the screen can show it properly:
//   free      can be picked
//   taken     someone else's booking, or time Vic blocked off (greyed out)
//   current   where this booking is now (when the chosen day is its own day)
//   past      already over today
// `busy` is the day's taken blocks. `own` are this booking's own blocks, which do not count against it:
// moving a long booking one block later must not be blocked by itself.
export function moveOptions({ date, hours, slotMinutes, minutes, busy = [], own = [], current = null, nowMinutes = null }) {
  const taken = new Set(busy)
  for (const s of own) taken.delete(s)
  const count = blocksFor(minutes, slotMinutes)

  return startsForDay({ date, minutes, hours, slotMinutes }).map((start) => {
    if (current !== null && start === current) return { start, state: 'current' }
    if (nowMinutes !== null && start <= nowMinutes) return { start, state: 'past' }
    for (let k = 0; k < count; k++) {
      if (taken.has(start + k * slotMinutes)) return { start, state: 'taken' }
    }
    return { start, state: 'free' }
  })
}
VICBLESS_EOF
cat > "$STAGE/moveTimes.test.js" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { HOURS } from '../config.js'
import { moveDateRange, moveOptions, ownStarts } from './moveTimes.js'

const TUESDAY = new Date(2026, 9, 13) // Oct 13 2026: open 12:00 pm to 6:00 pm
const base = { date: TUESDAY, hours: HOURS, slotMinutes: 35, minutes: 35 }
const states = (options) => Object.fromEntries(options.map((o) => [o.start, o.state]))

describe('moveOptions', () => {
  it('lists the whole day and marks taken times', () => {
    const options = moveOptions({ ...base, busy: [755] })
    expect(options[0]).toEqual({ start: 720, state: 'free' })
    expect(states(options)[755]).toBe('taken')
    expect(options.length).toBeGreaterThan(5)
  })

  it('marks where the booking is now, on its own day', () => {
    expect(states(moveOptions({ ...base, busy: [720], own: [720], current: 720 }))[720]).toBe('current')
  })

  it('does not let a long booking block itself when it moves one block later', () => {
    // a 70 minute booking holds 12:00 and 12:35; moving it to 12:35 needs 12:35 and 1:10
    const s = states(moveOptions({ ...base, minutes: 70, busy: [720, 755], own: [720, 755], current: 720 }))
    expect(s[755]).toBe('free')
    expect(s[720]).toBe('current')
  })

  it('refuses a long booking when the second block is taken', () => {
    const s = states(moveOptions({ ...base, minutes: 70, busy: [790] }))
    expect(s[755]).toBe('taken')
    expect(s[720]).toBe('free')
  })

  it('marks times that already passed today, including the current minute', () => {
    const s = states(moveOptions({ ...base, nowMinutes: 755 }))
    expect(s[720]).toBe('past')
    expect(s[755]).toBe('past')
    expect(s[790]).toBe('free')
  })

  it('has no times on a closed day', () => {
    expect(moveOptions({ ...base, date: new Date(2026, 9, 14) })).toEqual([]) // Wednesday
  })
})

describe('ownStarts', () => {
  it('lists every block a booking holds', () => {
    expect(ownStarts({ start: 720, minutes: 35 }, 35)).toEqual([720])
    expect(ownStarts({ start: 720, minutes: 70 }, 35)).toEqual([720, 755])
    expect(ownStarts({ start: 720, minutes: 30 }, 35)).toEqual([720])
  })
})

describe('moveDateRange', () => {
  it('runs from today to a year ahead', () => {
    expect(moveDateRange(new Date(2026, 9, 12))).toEqual({ min: '2026-10-12', max: '2027-10-12' })
  })
})
VICBLESS_EOF
cat > "$STAGE/MoveBooking.jsx" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS, SERVICES, SLOT_MINUTES } from '../config.js'
import { getAvailability } from '../lib/api.js'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { moveBooking } from './mockAdminApi.js'
import { moveDateRange, moveOptions, ownStarts } from './moveTimes.js'

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/
const dayLabel = (dateKey) => fromKey(dateKey).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })

// "Change time": Vic picks a new day and one of its free times for an existing booking.
// Times that are taken or blocked are shown greyed out, so he can see why they cannot be picked.
// The API has the final say (it refuses a time that was taken a moment ago), and this screen says so.
export default function MoveBooking({ item, onClose, onMoved }) {
  const dateId = useId()
  const range = useMemo(() => moveDateRange(new Date()), [])
  const [dateKey, setDateKey] = useState(item.dateKey)
  const [day, setDay] = useState({ status: 'loading' })
  const [picked, setPicked] = useState(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const service = SERVICES.find((s) => s.id === item.serviceId)
  const sameDay = dateKey === item.dateKey

  // Look up the chosen day's taken times. A newer choice cancels the answer to an older one.
  useEffect(() => {
    let alive = true
    setDay({ status: 'loading' })
    setPicked(null)
    getAvailability([dateKey])
      .then((all) => alive && setDay({ status: 'ready', ...all[dateKey] }))
      .catch(() => alive && setDay({ status: 'error' }))
    return () => {
      alive = false
    }
  }, [dateKey])

  const options = useMemo(() => {
    if (day.status !== 'ready') return []
    const now = new Date()
    return moveOptions({
      date: fromKey(dateKey),
      hours: HOURS,
      slotMinutes: SLOT_MINUTES,
      minutes: item.minutes,
      busy: day.busy,
      own: sameDay ? ownStarts(item, SLOT_MINUTES) : [],
      current: sameDay ? item.start : null,
      nowMinutes: dateKey === keyOf(now) ? now.getHours() * 60 + now.getMinutes() : null,
    })
  }, [day, dateKey, item, sameDay])

  const anyFree = options.some((o) => o.state === 'free')

  function pickDay(value) {
    // Clearing the field, or typing a day outside the allowed range, does nothing.
    if (DATE_PATTERN.test(value) && value >= range.min && value <= range.max) setDateKey(value)
  }

  async function submit(e) {
    e.preventDefault()
    if (picked === null || saving) return
    setSaving(true)
    setError('')
    try {
      await moveBooking(item, { dateKey, start: picked })
      onMoved(`Moved ${item.name} to ${dayLabel(dateKey)} at ${fmtTime(picked)}.`)
    } catch (ex) {
      setError(
        ex.code === 'CONFLICT'
          ? 'That time was just taken. Pick another one.'
          : 'Could not move it. Nothing was changed. Try again.',
      )
      setSaving(false)
      if (ex.code === 'CONFLICT') {
        // Show the fresh picture of the day so the time that was just taken is greyed out.
        getAvailability([dateKey]).then((all) => setDay({ status: 'ready', ...all[dateKey] })).catch(() => {})
        setPicked(null)
      }
    }
  }

  return (
    <form className="admin-block-form admin-move-form" onSubmit={submit} noValidate aria-label={`Change ${item.name}'s time`}>
      <h3>Change time</h3>
      <p className="admin-meta">
        {item.name}, {service ? service.name : 'Appointment'}. Now: {dayLabel(item.dateKey)} at {fmtTime(item.start)}.
      </p>

      <div className="field">
        <label htmlFor={dateId}>New day</label>
        <input id={dateId} type="date" min={range.min} max={range.max} value={dateKey} onChange={(e) => pickDay(e.target.value)} />
      </div>

      {day.status === 'loading' && (
        <p role="status" className="admin-status">
          Checking {dayLabel(dateKey)}…
        </p>
      )}
      {day.status === 'error' && (
        <p className="err" role="alert">
          Could not check that day. Pick the day again to retry.
        </p>
      )}
      {day.status === 'ready' && options.length === 0 && <p className="empty">Vic is closed that day. Pick another day.</p>}
      {day.status === 'ready' && options.length > 0 && !anyFree && (
        <p className="empty">Nothing is free that day. Pick another day.</p>
      )}

      {options.length > 0 && (
        <div className="admin-move-times" role="group" aria-label="Pick a new time">
          {options.map((o) => {
            const label = fmtTime(o.start)
            const note = { taken: ', taken', current: ', where it is now', past: ', already passed' }[o.state] || ''
            return (
              <button
                key={o.start}
                type="button"
                className={`admin-move-time admin-move-${o.state}`}
                disabled={o.state !== 'free'}
                aria-pressed={picked === o.start}
                aria-label={label + note}
                onClick={() => setPicked(o.start)}
              >
                {label}
                {o.state === 'current' && <span className="admin-move-now">now</span>}
              </button>
            )
          })}
        </div>
      )}

      {picked !== null && (
        <p className="admin-move-summary" role="status">
          Move {item.name} to {dayLabel(dateKey)} at {fmtTime(picked)}? If they left an email, they are told about the new time.
        </p>
      )}

      {error && (
        <p className="err" role="alert">
          {error}
        </p>
      )}

      <div className="actions">
        <button type="button" className="btn" onClick={onClose} disabled={saving}>
          Close
        </button>
        <button type="submit" className="btn btn-primary" disabled={picked === null || saving}>
          {saving ? 'Moving…' : picked === null ? 'Pick a time' : `Move to ${fmtTime(picked)}`}
        </button>
      </div>
    </form>
  )
}
VICBLESS_EOF
cat > "$STAGE/Schedule.jsx" <<'VICBLESS_EOF'
import { useEffect, useMemo, useRef, useState } from 'react'
import { HOURS, SERVICES, SLOT_MINUTES } from '../config.js'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { formatPhone, mailtoHref, telHref } from '../lib/format.js'
import BlockOff from './BlockOff.jsx'
import ConfirmBox from './ConfirmBox.jsx'
import JumpToDate from './JumpToDate.jsx'
import MoveBooking from './MoveBooking.jsx'
import NoteText from './NoteText.jsx'
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

// `ctl` is the set of actions the schedule gives every card (see `ctl` in Schedule below).
function BookingCard({ item, ctl }) {
  const service = SERVICES.find((s) => s.id === item.serviceId)
  const serviceName = service ? service.name : 'Appointment'
  const tel = telHref(item.phone)
  // Tapping the email opens his email app, addressed to the customer, with the subject already written.
  const mail = mailtoHref(
    item.email,
    `Your Vicbless appointment on ${fromKey(item.dateKey).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })} at ${fmtTime(item.start)}`,
  )
  const confirming = ctl.isCancelling(item)
  const moving = ctl.isMoving(item)
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
      {item.notes && <NoteText text={item.notes} who={item.name} />}

      {confirming && (
        <ConfirmBox
          label={`Cancel ${item.name}'s booking?`}
          keepLabel="Keep it"
          yesLabel="Yes, cancel it"
          workingLabel="Cancelling…"
          working={ctl.working}
          onKeep={ctl.keep}
          onYes={() => ctl.doCancel(item)}
        >
          Cancel {item.name}'s {fmtTime(item.start)} {serviceName}? The time opens up for other customers. The customer is not
          told yet.
        </ConfirmBox>
      )}

      {moving && <MoveBooking item={item} onClose={ctl.closeMove} onMoved={ctl.doMoved} />}

      {!confirming && !moving && (
        <div className="admin-card-actions">
          <button type="button" className="admin-box-btn" onClick={() => ctl.askMove(item)} aria-label={`Change ${item.name}'s ${fmtTime(item.start)} booking time`}>
            Change time
          </button>
          <button type="button" className="admin-box-btn admin-box-danger" onClick={() => ctl.askCancel(item)} aria-label={`Cancel ${item.name}'s ${fmtTime(item.start)} booking`}>
            Cancel
          </button>
        </div>
      )}
    </article>
  )
}

function BlockCard({ block, ctl }) {
  const range = describeRange(block.start, block.end)
  const confirming = ctl.isUnblocking(block)
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
          working={ctl.working}
          onKeep={ctl.keep}
          onYes={() => ctl.doUnblock(block)}
        >
          Open {range} back up? Customers will be able to book it again.
        </ConfirmBox>
      ) : (
        <button type="button" className="admin-box-btn" onClick={() => ctl.askUnblock(block)} aria-label={`Remove block ${range}`}>
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
  const [movingId, setMovingId] = useState(null) // the booking whose "Change time" panel is open
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
    setMovingId(null)
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

  // Only one panel is open at a time: asking to cancel closes "Change time", and the other way round.
  const askCancel = (item) => {
    setMovingId(null)
    setConfirm({ kind: 'cancel', id: item.id })
  }
  const askUnblock = (block) => setConfirm({ kind: 'unblock', id: block.id })
  const askMove = (item) => {
    setConfirm(null)
    setActionError('')
    setMovingId(item.id)
  }
  const keep = () => setConfirm(null)
  const doCancel = (item) =>
    run(() => cancelBooking(item), `Cancelled ${item.name} at ${fmtTime(item.start)}. That time is open again.`)
  const doUnblock = (block) =>
    run(() => removeBlock(block.id), `Opened ${describeRange(block.start, block.end)} back up.`)
  // Called by the "Change time" panel once the booking has moved: reload the day, close the panel, say what happened.
  const doMoved = async (message) => {
    await refresh()
    setMovingId(null)
    setFlash(message)
  }

  // Everything a card needs, in one object, so the cards don't each need six separate props.
  const ctl = {
    isCancelling: (item) => confirm?.kind === 'cancel' && confirm.id === item.id,
    isUnblocking: (block) => confirm?.kind === 'unblock' && confirm.id === block.id,
    isMoving: (item) => movingId === item.id,
    working,
    askCancel,
    askUnblock,
    askMove,
    closeMove: () => setMovingId(null),
    keep,
    doCancel,
    doUnblock,
    doMoved,
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
              <GroupRows key={group.open} group={group} previous={view.groups[gi - 1]} ctl={ctl} />
            ))}
          </ol>

          {(view.unmatched.length > 0 || view.unmatchedBlocks.length > 0) && (
            <div className="admin-unmatched">
              <h3>Other items on this day</h3>
              <p className="admin-meta">These are not on a regular time block, so they are listed here.</p>
              {view.unmatched.map((item) => (
                <div key={item.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(item.start)}</span>
                  <BookingCard item={item} ctl={ctl} />
                </div>
              ))}
              {view.unmatchedBlocks.map((block) => (
                <div key={block.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(block.start)}</span>
                  <BlockCard block={block} ctl={ctl} />
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </section>
  )
}

function GroupRows({ group, previous, ctl }) {
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
            {row.kind === 'booking' && <BookingCard item={row.item} ctl={ctl} />}
            {row.kind === 'continues' && <p className="admin-continues">Still with {row.item.name}</p>}
            {row.kind === 'blocked' && <BlockCard block={row.block} ctl={ctl} />}
            {row.kind === 'blocked-continues' && <p className="admin-continues">Still blocked</p>}
            {row.kind === 'open' && <p className="admin-open-label">Open</p>}
          </div>
        </li>
      ))}
    </>
  )
}
VICBLESS_EOF
cat > "$STAGE/mock_add.js" <<'VICBLESS_EOF'
// Moves a booking to another day and time. The "backend" has the final say, like the real one will:
// it refuses a time that is not on the grid, or that is taken or blocked (except by this booking itself).
// A real booking keeps its code. A sample booking becomes a real one at the new time, and its old time is freed.
export async function moveBooking(item, { dateKey, start }) {
  await delay(300)
  const onGrid = slotStarts(fromKey(dateKey), HOURS, SLOT_MINUTES)
  const blocks = blocksFor(item.minutes, SLOT_MINUTES)
  const wanted = Array.from({ length: blocks }, (_, k) => start + k * SLOT_MINUTES)
  if (!wanted.every((s) => onGrid.includes(s))) {
    const error = new Error('That is not a time Vic works.')
    error.code = 'INVALID'
    throw error
  }

  const busy = new Set((await getBusy([dateKey]))[dateKey] || [])
  if (item.dateKey === dateKey) {
    for (let k = 0; k < blocks; k++) busy.delete(item.start + k * SLOT_MINUTES) // its own old blocks are not in the way
  }
  if (wanted.some((s) => busy.has(s))) {
    const error = new Error('That time is taken.')
    error.code = 'CONFLICT'
    throw error
  }

  if (item.source === 'online') {
    writeBookings(
      readBookings().map((b) => (b.code === item.id && b.dateKey === item.dateKey && b.start === item.start ? { ...b, dateKey, start } : b)),
    )
    return
  }

  // sample booking: free its old time, then make a real booking at the new one
  const cancelled = readCancelledSamples()
  if (!cancelled.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
    writeCancelledSamples([...cancelled, { dateKey: item.dateKey, start: item.start }])
  }
  const code = 'VB-' + Math.random().toString(36).slice(2, 7).toUpperCase()
  writeBookings([
    ...readBookings(),
    {
      staffId: 'vic',
      serviceId: item.serviceId,
      dateKey,
      start,
      minutes: item.minutes,
      name: item.name,
      phone: item.phone,
      email: item.email,
      notes: item.notes,
      code,
    },
  ])
}
VICBLESS_EOF
cat > "$STAGE/css_add.css" <<'VICBLESS_EOF'
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
VICBLESS_EOF
export STAGE
python3 - <<'PY'
import os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
src = Path("src/admin")
NEW_FILES = ['notes.js', 'notes.test.js', 'NoteText.jsx', 'moveTimes.js', 'moveTimes.test.js', 'MoveBooking.jsx', 'Schedule.jsx']
HEADER_OLD = '//   removeBlock(id)         ->  DELETE /admin/blocks/{id}\n'
HEADER_NEW = '//   removeBlock(id)         ->  DELETE /admin/blocks/{id}\n//   moveBooking(item, {dateKey, start})  ->  PATCH /admin/bookings/{id}   body { dateKey, start }\n//                                         (409 if the time is taken; the booking comes back with a NEW id)\n'

schedule = (src / "Schedule.jsx").read_text()
mock = (src / "mockAdminApi.js").read_text()
css = (src / "admin.css").read_text()

# 1. Is this the Schedule.jsx this script knows how to replace?
already = "MoveBooking" in schedule
if not already:
    for marker in ("JumpToDate", "admin-box-danger", "askUnblock", "BookingCard"):
        if marker not in schedule:
            sys.exit("src/admin/Schedule.jsx is not the version this script expects (missing '%s').\nNothing was changed. Tell me what you edited and I will fit the change to it." % marker)
if "removeBlock" not in mock or "getBusy" not in mock:
    sys.exit("src/admin/mockAdminApi.js is not the version this script expects. Nothing was changed.")

# 2. Work out every change first.
changes = {}
for name in NEW_FILES:
    changes[src / name] = (stage / name).read_text()
if "export async function moveBooking" not in mock:
    new_mock = mock.replace(HEADER_OLD, HEADER_NEW, 1) if HEADER_OLD in mock else mock
    changes[src / "mockAdminApi.js"] = new_mock.rstrip("\n") + "\n\n" + (stage / "mock_add.js").read_text()
if "long notes: wrap inside the card" not in css:
    changes[src / "admin.css"] = css.rstrip("\n") + "\n\n" + (stage / "css_add.css").read_text()

# 3. Write only what actually differs.
done = []
for path, text in changes.items():
    if not path.exists() or path.read_text() != text:
        path.write_text(text)
        done.append(str(path))
if done:
    print("Changed:")
    for d in done:
        print("  -", d)
else:
    print("Already up to date. Nothing to change.")
PY

if [ -d node_modules ]; then
  echo "Running the tests..."
  npm test --silent
else
  echo "(No node_modules here, so the tests were not run. Run: npm install && npm test)"
fi

echo
echo "Done. Open /#/vic: long notes fold up, and every booking has a Change time button."
echo "Next: git add -A && git commit"
