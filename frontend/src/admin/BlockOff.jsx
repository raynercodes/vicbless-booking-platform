import { useMemo, useState } from 'react'
import { fmtTime, fromKey } from '../lib/availability.js'
import { dayGrid, describeRange, findConflicts, rangeFromChoice, wholeDayRange } from './blocks.js'
import { hoursFor, isAfterStart, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { addBlock } from './adminApi.js'

// "Block off time": part of the day or the whole day, with an optional note (Lunch, Phone booking...).
// It will not let Vic block over a booking or over time that is already blocked, and says which.
export default function BlockOff({ dateKey, items, blocks, onSaved, onClose }) {
  const shop = useShopSettings()
  const date = useMemo(() => fromKey(dateKey), [dateKey])
  const SLOT_MINUTES = slotFor(shop, date) // how long an appointment is on this day
  const hours = useMemo(() => hoursFor(shop), [shop]) // opening hours with the late appointments added
  const grid = useMemo(() => dayGrid({ date, hours, slotMinutes: SLOT_MINUTES }), [date, hours, SLOT_MINUTES])

  const [mode, setMode] = useState('part')
  const [from, setFrom] = useState(grid[0])
  const [until, setUntil] = useState(grid[0])
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const choice =
    mode === 'whole'
      ? wholeDayRange({ date, hours })
      : rangeFromChoice({ grid, fromStart: from, untilStart: until, slotMinutes: SLOT_MINUTES })
  const range = choice && !choice.error ? choice : null
  const rangeProblem = choice && choice.error ? choice.error : ''
  const conflicts = range ? findConflicts({ range, grid, items, blocks, slotMinutes: SLOT_MINUTES }) : { bookings: [], blocks: [] }
  const hasConflict = conflicts.bookings.length > 0 || conflicts.blocks.length > 0
  const canSave = !!range && !hasConflict && !saving

  async function submit(e) {
    e.preventDefault()
    if (!canSave) return
    setSaving(true)
    setError('')
    try {
      await addBlock({ dateKey, start: range.start, end: range.end, note, whole: mode === 'whole' })
      onSaved(
        mode === 'whole'
          ? 'Day off saved. Customers see the whole day as unavailable.'
          : `Blocked ${describeRange(range.start, range.end)}. Customers see it as unavailable.`,
      )
    } catch (ex) {
      setError(
        ex.code === 'CONFLICT'
          ? 'Something changed while you were choosing. Check the schedule and try again.'
          : 'Could not save. Try again.',
      )
      setSaving(false)
    }
  }

  return (
    <form className="admin-block-form" onSubmit={submit} noValidate aria-label="Block off time">
      <h3>Block off time</h3>

      <fieldset>
        <legend>What do you want to block?</legend>
        <label className="admin-radio">
          <input type="radio" name="block-mode" value="part" checked={mode === 'part'} onChange={() => setMode('part')} />
          Part of the day
        </label>
        <label className="admin-radio">
          <input type="radio" name="block-mode" value="whole" checked={mode === 'whole'} onChange={() => setMode('whole')} />
          The whole day
        </label>
      </fieldset>

      {mode === 'part' && (
        <div className="admin-block-times">
          <div className="field">
            <label htmlFor="block-from">From</label>
            <select
              id="block-from"
              value={from}
              onChange={(e) => {
                const value = Number(e.target.value)
                setFrom(value)
                if (until < value) setUntil(value)
              }}
            >
              {grid.map((s) => (
                <option key={s} value={s}>
                  {fmtTime(s)}
                  {isAfterStart(date, s) ? ' (after hours)' : ''}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="block-until">Until</label>
            <select id="block-until" value={until} onChange={(e) => setUntil(Number(e.target.value))}>
              {grid.map((s) => (
                <option key={s} value={s}>
                  {fmtTime(s + SLOT_MINUTES)}
                  {isAfterStart(date, s) ? ' (after hours)' : ''}
                </option>
              ))}
            </select>
          </div>
        </div>
      )}

      <div className="field">
        <label htmlFor="block-note">
          Note <span className="hint">(optional)</span>
        </label>
        <input
          id="block-note"
          value={note}
          maxLength={80}
          placeholder="Lunch, errand, phone booking..."
          onChange={(e) => setNote(e.target.value)}
        />
      </div>

      {rangeProblem && (
        <p className="err" role="alert">
          {rangeProblem}
        </p>
      )}

      {hasConflict && (
        <div className="admin-conflicts" role="alert">
          {conflicts.bookings.map((item) => (
            <p key={item.id}>
              {item.name} is booked at {fmtTime(item.start)}. Cancel that booking first, or pick other times.
            </p>
          ))}
          {conflicts.blocks.map((block) => (
            <p key={block.id}>{describeRange(block.start, block.end)} is already blocked. Remove that block first.</p>
          ))}
        </div>
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
        <button type="submit" className="btn btn-primary" disabled={!canSave}>
          {saving ? 'Saving…' : 'Block this time'}
        </button>
      </div>
    </form>
  )
}
