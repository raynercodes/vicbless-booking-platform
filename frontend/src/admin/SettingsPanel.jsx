import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS, MAX_SERVICES, REMINDER_CHOICES, SLOT_MAX, SLOT_MIN, SLOT_STEP } from '../config.js'
import { fmtTime } from '../lib/availability.js'
import {
  DAY_NAMES,
  NAME_MAX,
  NOTE_MAX,
  PRICE_MAX,
  checkDraft,
  draftFrom,
  fromApi,
  isChanged,
  newDraftService,
  setShopSettings,
  toApi,
  toggleReminder,
} from '../lib/shopSettings.js'
import { getAdminSettings, saveSettings } from './adminApi.js'

// Monday first, the way people read a week (the numbers are JavaScript's: 0 is Sunday).
const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0]

const hoursText = (day) => {
  const windows = HOURS[day]
  return windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'
}

// Vic's shop settings, only reachable from inside his dashboard (Menu > Settings > Shop settings):
//   - the services, their prices and notes (add, rename, reorder, remove)
//   - how long an appointment is on each weekday, in steps of 5 minutes
// Saving changes what customers see and book straight away. Bookings already made keep their times and names.
export default function SettingsPanel({ onClose }) {
  const [saved, setSaved] = useState(null) // the settings as last saved, in the screens' shape
  const [draft, setDraft] = useState(null) // what Vic is editing
  const [errors, setErrors] = useState({ general: '', services: {}, slots: {} })
  const [status, setStatus] = useState('loading') // loading | ready | error
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')
  const [failure, setFailure] = useState('')
  const [attempt, setAttempt] = useState(0)
  const uid = useId()

  useEffect(() => {
    let alive = true
    setStatus('loading')
    getAdminSettings()
      .then((raw) => {
        const parsed = fromApi(raw)
        if (!alive) return
        if (!parsed) throw new Error('unreadable')
        setSaved(parsed)
        setDraft(draftFrom(parsed))
        setStatus('ready')
      })
      .catch(() => alive && setStatus('error'))
    return () => {
      alive = false
    }
  }, [attempt])

  const changed = useMemo(() => !!draft && !!saved && isChanged(draft, saved), [draft, saved])

  const touch = (change) => {
    setDraft((d) => change(d))
    setMessage('')
    setFailure('')
  }
  const editService = (key, field, value) =>
    touch((d) => ({ ...d, services: d.services.map((s) => (s.key === key ? { ...s, [field]: value } : s)) }))
  const move = (index, by) =>
    touch((d) => {
      const services = [...d.services]
      const target = index + by
      if (target < 0 || target >= services.length) return d
      ;[services[index], services[target]] = [services[target], services[index]]
      return { ...d, services }
    })
  const remove = (key) => touch((d) => ({ ...d, services: d.services.filter((s) => s.key !== key) }))
  const add = () => touch((d) => ({ ...d, services: [...d.services, newDraftService()] }))

  async function submit(e) {
    e.preventDefault()
    if (saving) return
    const result = checkDraft(draft)
    setErrors(result.ok ? { general: '', services: {}, slots: {} } : result.errors)
    if (!result.ok) {
      setFailure('Some things need fixing. They are marked below.')
      return
    }
    setSaving(true)
    setFailure('')
    setMessage('')
    try {
      const reply = fromApi(await saveSettings(toApi(result.settings)))
      if (!reply) throw new Error('unreadable')
      setSaved(reply)
      setDraft(draftFrom(reply))
      setShopSettings(reply) // every page open in this browser now shows the new settings
      setMessage('Saved. Customers see the new services and times right away.')
    } catch (ex) {
      // The API's own sentence is written for Vic ("Two services have the same name...").
      setFailure(ex && ex.message && ex.code !== 'network' ? ex.message : 'Could not save. Nothing was changed. Try again.')
    } finally {
      setSaving(false)
    }
  }

  if (status === 'loading') {
    return (
      <section className="admin-settings" aria-label="Shop settings">
        <p role="status" className="admin-status">
          Loading your settings…
        </p>
      </section>
    )
  }
  if (status === 'error') {
    return (
      <section className="admin-settings" aria-label="Shop settings">
        <p className="err" role="alert">
          Could not load your settings.
        </p>
        <div className="actions">
          <button type="button" className="btn" onClick={onClose}>
            Back to schedule
          </button>
          <button type="button" className="btn btn-primary" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      </section>
    )
  }

  return (
    <form className="admin-settings" onSubmit={submit} noValidate aria-label="Shop settings">
      <div className="admin-settings-head">
        <h2>Shop settings</h2>
        <button type="button" className="admin-box-btn" onClick={onClose}>
          Back to schedule
        </button>
      </div>
      <p className="admin-meta">Changes apply to new bookings as soon as you save. Bookings already made keep their time and service name.</p>

      <fieldset className="admin-settings-group">
        <legend>Services and prices</legend>
        {errors.general && (
          <p className="err" role="alert">
            {errors.general}
          </p>
        )}
        <ul className="admin-svc-list">
          {draft.services.map((s, i) => {
            const e = errors.services[s.key] || {}
            return (
              <li key={s.key} className="admin-svc">
                <div className="field">
                  <label htmlFor={`${uid}-n-${s.key}`}>Service name</label>
                  <input id={`${uid}-n-${s.key}`} value={s.name} maxLength={NAME_MAX} aria-invalid={!!e.name} onChange={(ev) => editService(s.key, 'name', ev.target.value)} />
                  {e.name && <p className="err">{e.name}</p>}
                </div>
                <div className="admin-svc-price">
                  <div className="field">
                    <label htmlFor={`${uid}-p-${s.key}`}>Price ($)</label>
                    <input id={`${uid}-p-${s.key}`} inputMode="numeric" value={s.price} maxLength={3} aria-invalid={!!e.price} onChange={(ev) => editService(s.key, 'price', ev.target.value)} />
                    {e.price && <p className="err">{e.price}</p>}
                  </div>
                  <label className="admin-radio admin-svc-from">
                    <input type="checkbox" checked={s.from} onChange={(ev) => editService(s.key, 'from', ev.target.checked)} />
                    Starting price (shown as ${s.price.trim() || '0'}+)
                  </label>
                </div>
                <div className="field">
                  <label htmlFor={`${uid}-t-${s.key}`}>
                    Note <span className="hint">(optional, shown under the service)</span>
                  </label>
                  <input id={`${uid}-t-${s.key}`} value={s.note} aria-invalid={!!e.note} onChange={(ev) => editService(s.key, 'note', ev.target.value)} />
                  <p className="counter">
                    {s.note.length}/{NOTE_MAX}
                  </p>
                  {e.note && <p className="err">{e.note}</p>}
                </div>
                <div className="admin-svc-actions">
                  <button type="button" className="admin-box-btn" disabled={i === 0} onClick={() => move(i, -1)} aria-label={`Move ${s.name || 'this service'} up`}>
                    Move Up
                  </button>
                  <button type="button" className="admin-box-btn" disabled={i === draft.services.length - 1} onClick={() => move(i, 1)} aria-label={`Move ${s.name || 'this service'} down`}>
                    Move Down
                  </button>
                  <button type="button" className="admin-box-btn admin-box-danger" disabled={draft.services.length <= 1} onClick={() => remove(s.key)} aria-label={`Remove ${s.name || 'this service'}`}>
                    Remove
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
        <button type="button" className="btn" onClick={add} disabled={draft.services.length >= MAX_SERVICES}>
          Add a service
        </button>
        {draft.services.length >= MAX_SERVICES && <p className="admin-meta">That is the most you can list ({MAX_SERVICES}).</p>}
      </fieldset>

      <fieldset className="admin-settings-group">
        <legend>How long an appointment is</legend>
        <p className="admin-meta">
          Each day's times are cut into appointments of this length, from {SLOT_MIN} to {SLOT_MAX} minutes, in steps of {SLOT_STEP} (for example 25, 35 or 45).
        </p>
        <ul className="admin-slot-list">
          {WEEK_ORDER.map((day) => (
            <li key={day} className="admin-slot-row">
              <div className="admin-slot-day">
                <label htmlFor={`${uid}-d-${day}`}>{DAY_NAMES[day]}</label>
                <span className="admin-meta">{hoursText(day)}</span>
              </div>
              <div className="admin-slot-input">
                <input
                  id={`${uid}-d-${day}`}
                  type="number"
                  inputMode="numeric"
                  min={SLOT_MIN}
                  max={SLOT_MAX}
                  step={SLOT_STEP}
                  value={draft.slots[day]}
                  aria-invalid={!!errors.slots[day]}
                  aria-describedby={errors.slots[day] ? `${uid}-e-${day}` : undefined}
                  onChange={(ev) => touch((d) => ({ ...d, slots: { ...d.slots, [day]: ev.target.value } }))}
                />
                <span aria-hidden="true">min</span>
              </div>
              {errors.slots[day] && (
                <p className="err" id={`${uid}-e-${day}`}>
                  {errors.slots[day]}
                </p>
              )}
            </li>
          ))}
        </ul>
      </fieldset>

      <fieldset className="admin-settings-group">
        <legend>Reminders</legend>
        <p className="admin-meta">
          Tick when customers get a reminder before their appointment. They get it by email if they left one, and by text if they
          ticked the box to be texted. A reminder is never sent for a time that had already passed when the booking was made.
        </p>
        <ul className="admin-remind-list">
          {[...REMINDER_CHOICES].sort((a, b) => b - a).map((hours) => (
            <li key={hours}>
              <label className="admin-radio">
                <input type="checkbox" checked={draft.reminders.includes(hours)} onChange={() => touch((d) => toggleReminder(d, hours))} />
                {hours === 1 ? '1 hour before' : hours === 48 ? '2 days before' : hours === 24 ? '1 day before' : `${hours} hours before`}
              </label>
            </li>
          ))}
        </ul>
        {draft.reminders.length === 0 && <p className="admin-meta">No reminders will be sent.</p>}
      </fieldset>

      {failure && (
        <p className="err" role="alert">
          {failure}
        </p>
      )}
      {message && (
        <p className="admin-flash" role="status">
          {message}
        </p>
      )}

      <div className="actions">
        <button type="button" className="btn" onClick={onClose} disabled={saving}>
          {changed ? 'Discard and go back' : 'Back to schedule'}
        </button>
        <button type="submit" className="btn btn-primary" disabled={!changed || saving}>
          {saving ? 'Saving…' : 'Save settings'}
        </button>
      </div>
    </form>
  )
}
