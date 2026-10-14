import { useEffect, useMemo, useRef, useState } from 'react'
import { HOURS } from '../config.js'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { formatPhone, mailtoHref, telHref } from '../lib/format.js'
import { findService, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import BlockOff from './BlockOff.jsx'
import ConfirmBox from './ConfirmBox.jsx'
import JumpToDate from './JumpToDate.jsx'
import MoveBooking from './MoveBooking.jsx'
import NoteText from './NoteText.jsx'
import { describeRange } from './blocks.js'
import { cancelBooking, getDay, removeBlock } from './adminApi.js'
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
  const shop = useShopSettings()
  // The name the customer booked, even if Vic has renamed or removed the service since.
  const service = findService(shop, item.serviceId)
  const serviceName = item.serviceName || (service ? service.name : 'Appointment')
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
          Cancel {item.name}'s {fmtTime(item.start)} {serviceName}? The time opens up for other customers. If they left an
          email, they are told it was cancelled.
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
  const shop = useShopSettings()
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
            slotMinutes: slotFor(shop, fromKey(dateKey)),
          })
        : null,
    [state, dateKey, shop],
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
