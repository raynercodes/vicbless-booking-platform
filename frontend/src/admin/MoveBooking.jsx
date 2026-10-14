import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS } from '../config.js'
import { getAvailability } from '../lib/api.js'
import { fmtTime, fromKey, keyOf, slotStarts } from '../lib/availability.js'
import { findService, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { moveBooking } from './adminApi.js'
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

  const shop = useShopSettings()
  const service = findService(shop, item.serviceId)
  const serviceName = item.serviceName || (service ? service.name : 'Appointment')
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
    // The booking takes the appointment length of the day it is moved to (the API does the same).
    const date = fromKey(dateKey)
    const slot = slotFor(shop, date)
    return moveOptions({
      date,
      hours: HOURS,
      slotMinutes: slot,
      minutes: slot,
      busy: day.busy,
      own: sameDay ? ownStarts(item, slot, slotStarts(date, HOURS, slot)) : [],
      current: sameDay ? item.start : null,
      nowMinutes: dateKey === keyOf(now) ? now.getHours() * 60 + now.getMinutes() : null,
    })
  }, [day, dateKey, item, sameDay, shop])

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
        {item.name}, {serviceName}. Now: {dayLabel(item.dateKey)} at {fmtTime(item.start)}.
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
