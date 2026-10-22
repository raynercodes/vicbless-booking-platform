#!/usr/bin/env bash
# Booking times follow Eastern time
# Run from the REPO ROOT:  bash vicbless-eastern-time-slots.sh
#
# Times that have passed in Eastern time are greyed out on the booking form for every visitor, wherever they are.
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
from datetime import date, datetime

import pytest

from app.core.errors import InvalidSlot, SlotUnavailable
from app.domain import shop
from tests.helpers.constants import NOW

TUE = date(2026, 10, 13)
WED = date(2026, 10, 14)
SAT = date(2026, 10, 17)
SUN = date(2026, 10, 18)
at = shop.at


def test_weekday_mapping():
    # 2026-10-12 is a Monday; each day of that week
    expected_open = {12: True, 13: True, 14: False, 15: True, 16: True, 17: True, 18: False}
    for day, is_open in expected_open.items():
        assert shop.is_open(date(2026, 10, day)) is is_open


def test_tuesday_grid_runs_from_opening_in_35_minute_steps():
    grid = shop.grid_starts(TUE, 35)
    assert grid[0] == at(12) and grid[1] == at(12, 35)
    assert len(grid) == 10
    assert grid[-1] + 35 <= at(18)


def test_thursday_friday_have_13_blocks():
    assert len(shop.grid_starts(date(2026, 10, 15), 35)) == 13
    assert len(shop.grid_starts(date(2026, 10, 16), 35)) == 13


def test_saturday_has_two_windows_and_a_gap():
    grid = shop.grid_starts(SAT, 35)
    assert grid[0] == at(9) and at(12, 35) in grid
    assert at(12) not in grid
    for s in grid:
        assert (at(9) <= s and s + 35 <= at(12)) or (at(12, 35) <= s and s + 35 <= at(17))


def test_closed_days_have_no_grid():
    assert shop.grid_starts(WED, 35) == [] and shop.grid_starts(SUN, 35) == []


def test_the_grid_follows_the_slot_length():
    # Monday and Tuesday at 45 minutes: 12:00, 12:45, 1:30 ... eight appointments, the last ending exactly at 6:00 pm
    grid = shop.grid_starts(TUE, 45)
    assert grid == [at(12) + 45 * k for k in range(8)] and grid[-1] + 45 == at(18)
    assert len(shop.grid_starts(TUE, 25)) == 14 and len(shop.grid_starts(TUE, 120)) == 3


def test_the_real_defaults_make_monday_and_tuesday_45_minutes():
    from tests.fixtures.settings import REAL_DEFAULTS

    mon, tue = date(2026, 10, 12), date(2026, 10, 13)
    assert REAL_DEFAULTS.slot_for(mon) == 45 and REAL_DEFAULTS.slot_for(tue) == 45
    for day in (14, 15, 16, 17, 18):
        assert REAL_DEFAULTS.slot_for(date(2026, 10, day)) == 35  # every other day is unchanged
    assert [s.id for s in REAL_DEFAULTS.services] == ["mens-cut", "mens-design", "mens-beard-eyebrow", "buzz-beard", "kids-design"]
    assert REAL_DEFAULTS.service("mens-cut").price == 55 and REAL_DEFAULTS.service("nope") is None


def test_occupied_units_are_five_minute_steps():
    assert shop.occupied_starts(at(12), 45) == [at(12) + 5 * k for k in range(9)]
    assert shop.occupied_starts(at(12, 35), 35) == [at(12, 35) + 5 * k for k in range(7)]
    # two appointments share a unit only if they really overlap
    assert not set(shop.occupied_starts(at(12), 35)) & set(shop.occupied_starts(at(12, 35), 35))
    assert set(shop.occupied_starts(at(12), 45)) & set(shop.occupied_starts(at(12, 35), 35))


def test_fits_matches_grid_and_closing():
    assert shop.fits(TUE, at(12), 35)
    assert not shop.fits(TUE, at(12, 10), 35)  # off the grid
    assert not shop.fits(TUE, at(17, 50), 35)  # would run past closing
    assert not shop.fits(WED, at(12), 35)
    assert not shop.fits(SAT, at(12), 35)  # inside Saturday's gap
    assert shop.fits(TUE, at(12, 45), 45) and not shop.fits(TUE, at(12, 35), 45)  # each day's slot length is its own grid


def test_an_appointment_must_stay_inside_one_window():
    assert shop.fits(SAT, at(11, 15), 45)  # 9:00, 9:45, 10:30, 11:15: the last one ends at noon sharp
    assert not shop.fits(SAT, at(11, 30), 50)  # a 50 minute appointment there would cross noon
    assert shop.fits(SAT, at(11, 20), 35)  # the last 35 minute start in the morning ends at 11:55, five minutes before noon


@pytest.mark.parametrize(
    "when,start,error",
    [
        (date(2026, 10, 13), at(12), None),
        (date(2026, 10, 14), at(12), InvalidSlot),  # closed Wednesday
        (date(2026, 10, 13), at(12, 5), InvalidSlot),  # off grid
        (date(2026, 10, 10), at(9), SlotUnavailable),  # past Saturday
        (date(2026, 10, 26), at(12), SlotUnavailable),  # 14 days ahead is outside 0..13
        (date(2026, 10, 25), at(12), None),  # last day in the window (a Sunday... closed)
    ],
)
def test_check_bookable(when, start, error):
    if when == date(2026, 10, 25):
        error = InvalidSlot  # Sunday is closed, so structure fails first
    if error is None:
        shop.check_bookable(when, start, 35, NOW)
    else:
        with pytest.raises(error):
            shop.check_bookable(when, start, 35, NOW)


def test_last_bookable_day_is_13_days_out():
    # Monday 2026-10-12 + 13 = Sunday the 25th (closed); Saturday the 24th is inside the window
    shop.check_bookable(date(2026, 10, 24), at(9), 35, NOW)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 26), at(12), 35, NOW)


def test_lead_time_today():
    now = datetime(2026, 10, 12, 12, 5, tzinfo=shop.TIMEZONE)  # Monday 12:05
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12), 35, now)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12, 35), 35, now)  # 12:35 is exactly now + 30, so too soon
    shop.check_bookable(date(2026, 10, 12), at(13, 10), 35, now)  # 13:10 is fine


def test_today_uses_shop_timezone_not_utc():
    # 11 pm Monday in New York is already Tuesday in UTC; "today" must still be Monday
    late = datetime(2026, 10, 12, 23, 0, tzinfo=shop.TIMEZONE)
    assert shop.today(late) == date(2026, 10, 12)
    utc = late.astimezone(__import__("datetime").timezone.utc)
    assert shop.today(utc) == date(2026, 10, 12)


def test_dst_day_still_gives_normal_minutes():
    # Daylight saving ends 2026-11-01 (a Sunday); Monday after is a normal day
    now = datetime(2026, 11, 2, 9, 0, tzinfo=shop.TIMEZONE)
    shop.check_bookable(date(2026, 11, 2), at(12), 35, now)


def test_block_range_and_whole_day():
    assert shop.block_units(TUE, at(12), at(12, 35) + 35) == list(range(at(12), at(12, 35) + 35, 5))
    assert shop.block_units(TUE, at(12), at(12)) == []
    assert shop.block_units(TUE, at(11), at(12, 10)) == [at(12), at(12, 5)]  # only the part inside opening hours
    assert shop.block_units(TUE, at(12, 3), at(12, 8)) == [at(12), at(12, 5)]  # widened to whole 5 minute units
    with pytest.raises(InvalidSlot):
        shop.check_blockable(WED, NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2026, 10, 9), NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2027, 10, 20), NOW)
    shop.check_blockable(date(2026, 10, 13), NOW)


def test_labels():
    assert shop.label(at(12, 35)) == "12:35 pm"
    assert shop.label(at(9)) == "9:00 am"
    assert shop.hhmm(at(7, 20)) == "0720"


def test_a_whole_saturday_skips_the_lunch_gap():
    units = shop.block_units(SAT, at(9), at(17))
    assert at(12) not in units and at(12, 30) not in units and at(12, 35) in units
    assert len(units) == (at(12) - at(9)) // 5 + (at(17) - at(12, 35)) // 5


def test_busy_slots_are_the_grid_slots_that_overlap_something_taken():
    # a 35 minute booking at 12:35 (units 12:35-13:05) sits across two 45 minute slots (12:00-12:45 and 12:45-13:30)
    taken = set(shop.occupied_starts(at(12, 35), 35))
    assert shop.busy_slots(TUE, 45, taken) == [at(12), at(12, 45)]
    assert shop.busy_slots(TUE, 35, taken) == [at(12, 35)]
    assert shop.busy_slots(TUE, 45, set()) == []
    assert shop.busy_slots(WED, 45, taken) == []  # a closed day has no grid


def test_a_time_that_passed_in_eastern_time_is_refused_even_when_the_clock_is_in_utc():
    utc_now = datetime(2026, 10, 12, 18, 0, tzinfo=__import__("datetime").timezone.utc)  # 2:00 pm in New York
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12), 35, utc_now)
    shop.check_bookable(date(2026, 10, 12), at(14, 55), 35, utc_now)
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
// Pure scheduling logic. No browser or network access, so it is easy to test.

export const pad = (n) => String(n).padStart(2, '0')

export const keyOf = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`

export const SHOP_TIMEZONE = 'America/New_York'

// The shop's clock. Vic is in Eastern time, so "today" and "the time passed" mean Eastern time wherever the customer is.
// Returns a Date whose local fields (getHours, getDate ...) read the Eastern wall clock, so the rest of the code can
// keep using keyOf() and getHours() on it.
export function shopNow(at = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', { timeZone: SHOP_TIMEZONE, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' })
      .formatToParts(at)
      .map((p) => [p.type, Number(p.value)]),
  )
  return new Date(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second)
}

export const fromKey = (k) => {
  const [y, m, d] = k.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export const fmtTime = (minutes) => {
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return `${h % 12 || 12}:${pad(m)} ${h >= 12 ? 'pm' : 'am'}`
}

// How many grid blocks a service occupies.
export const blocksFor = (minutes, slotMinutes) => Math.max(1, Math.ceil(minutes / slotMinutes))

// Every block start on a day. Each opening window runs its own grid from its
// opening time, so Saturday's afternoon grid starts at 12:35, not 12:00.
export function slotStarts(date, hours, slotMinutes) {
  const windows = hours[date.getDay()]
  if (!windows) return []
  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + slotMinutes <= close; s += slotMinutes) out.push(s)
  }
  return out
}

// Start times (minutes after midnight) a service of `minutes` can begin on `date`.
//   hours   map of dayIndex -> [[open, close], ...] | null   (minutes after midnight)
//   busy    array of busy block starts
//   now     the shop's current time (see shopNow), used to hide times that already passed
export function slotsForDay({ date, minutes, hours, busy = [], now = shopNow(), slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) return []

  const busySet = new Set(busy)
  const blocks = blocksFor(minutes, slotMinutes)
  const isToday = keyOf(date) === keyOf(now)
  const nowMinutes = now.getHours() * 60 + now.getMinutes()

  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + minutes <= close; s += slotMinutes) {
      if (isToday && s <= nowMinutes + 30) continue
      let free = true
      for (let k = 0; k < blocks; k++) {
        if (busySet.has(s + k * slotMinutes)) {
          free = false
          break
        }
      }
      if (free) out.push(s)
    }
  }
  return out
}

// Every start time a service of `minutes` could begin on `date`, whether or not it is free.
// Used to show the whole day with the unavailable times greyed out instead of hidden.
export function startsForDay({ date, minutes, hours, slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) return []
  const out = []
  for (const [open, close] of windows) {
    for (let s = open; s + minutes <= close; s += slotMinutes) out.push(s)
  }
  return out
}
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { slotsForDay, slotStarts, startsForDay, blocksFor, fmtTime, keyOf, fromKey, shopNow } from './availability.js'

const at = (h, m = 0) => h * 60 + m
const HOURS = {
  0: null,
  1: [[at(12), at(18)]],
  2: [[at(12), at(18)]],
  3: null,
  4: [[at(11), at(19)]],
  5: [[at(11), at(19)]],
  6: [
    [at(9), at(12)],
    [at(12, 35), at(17)],
  ],
}
const SLOT = 35
const SUNDAY = new Date(2026, 9, 4)
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const EARLIER = new Date(2026, 9, 1, 8, 0)

const run = (date, minutes, extra = {}) =>
  slotsForDay({ date, minutes, hours: HOURS, now: EARLIER, slotMinutes: SLOT, ...extra })

describe('slotsForDay', () => {
  it('returns nothing on closed days', () => {
    expect(run(SUNDAY, 35)).toEqual([])
    expect(run(WEDNESDAY, 35)).toEqual([])
  })

  it('runs a 35 minute grid from opening time', () => {
    const slots = run(TUESDAY, 35)
    expect(slots[0]).toBe(at(12))
    expect(slots[1]).toBe(at(12, 35))
    expect(slots).toHaveLength(10)
    expect(slots[slots.length - 1]).toBe(at(12) + 9 * 35)
  })

  it('keeps 30 minute services on the same grid', () => {
    expect(run(TUESDAY, 30)).toEqual(run(TUESDAY, 35))
  })

  it('never runs past closing time', () => {
    for (const s of run(TUESDAY, 35)) expect(s + 35).toBeLessThanOrEqual(at(18))
  })

  it('handles Saturday as two separate windows', () => {
    const slots = run(SATURDAY, 35)
    expect(slots[0]).toBe(at(9))
    expect(slots).toContain(at(12, 35))
    expect(slots).not.toContain(at(12)) // lunch gap
    for (const s of slots) {
      const inMorning = s >= at(9) && s + 35 <= at(12)
      const inAfternoon = s >= at(12, 35) && s + 35 <= at(17)
      expect(inMorning || inAfternoon).toBe(true)
    }
  })

  it('excludes a block that is already busy', () => {
    const slots = run(TUESDAY, 35, { busy: [at(12, 35)] })
    expect(slots).not.toContain(at(12, 35))
    expect(slots).toContain(at(12))
    expect(slots).toContain(at(13, 10))
  })

  it('needs every block free for a longer service', () => {
    const slots = run(TUESDAY, 70, { busy: [at(12, 35)] })
    expect(slots).not.toContain(at(12)) // second block is busy
    expect(slots).not.toContain(at(12, 35))
    expect(slots).toContain(at(13, 10))
  })

  it('hides times that already passed today', () => {
    const now = new Date(2026, 9, 6, 13, 0)
    const slots = run(TUESDAY, 35, { now })
    expect(slots[0]).toBe(at(13, 45)) // 13:10 is within 30 min of 13:00
  })
})

describe('helpers', () => {
  it('lists block starts per window', () => {
    const starts = slotStarts(SATURDAY, HOURS, SLOT)
    expect(starts[0]).toBe(at(9))
    expect(starts).toContain(at(12, 35))
  })

  it('counts blocks', () => {
    expect(blocksFor(30, SLOT)).toBe(1)
    expect(blocksFor(35, SLOT)).toBe(1)
    expect(blocksFor(70, SLOT)).toBe(2)
  })

  it('formats times', () => {
    expect(fmtTime(0)).toBe('12:00 am')
    expect(fmtTime(at(12))).toBe('12:00 pm')
    expect(fmtTime(at(12, 35))).toBe('12:35 pm')
  })

  it('round-trips date keys', () => {
    expect(keyOf(fromKey('2026-10-06'))).toBe('2026-10-06')
  })
})

describe('startsForDay (the whole day, free or not)', () => {
  const all = (date, minutes) => startsForDay({ date, minutes, hours: HOURS, slotMinutes: SLOT })

  it('lists every start in the open windows, including times that are taken or already past', () => {
    const open = run(TUESDAY, 35, { busy: [at(12, 35), at(14, 20)] })
    const every = all(TUESDAY, 35)
    expect(every).toHaveLength(10)
    expect(open).toHaveLength(8)
    for (const s of open) expect(every).toContain(s)
    expect(every).toContain(at(12, 35)) // taken, but still part of the day
  })

  it('is empty on closed days', () => {
    expect(all(SUNDAY, 35)).toEqual([])
    expect(all(WEDNESDAY, 35)).toEqual([])
  })

  it('follows each window on a split day', () => {
    const every = all(SATURDAY, 35)
    expect(every[0]).toBe(at(9))
    expect(every).toContain(at(12, 35))
    expect(every).not.toContain(at(12))
  })

  it('leaves out starts where a longer service would run past closing', () => {
    expect(all(TUESDAY, 70).at(-1)).toBeLessThan(all(TUESDAY, 35).at(-1))
    for (const s of all(TUESDAY, 70)) expect(s + 70).toBeLessThanOrEqual(at(18))
  })

  it('never lists a start that slotsForDay offers but startsForDay does not', () => {
    const open = run(TUESDAY, 35)
    const every = all(TUESDAY, 35)
    for (const s of open) expect(every).toContain(s)
  })
})

describe('the shop clock (Eastern time)', () => {
  it('reads Eastern wall time whatever the customer\'s timezone is', () => {
    const summer = shopNow(new Date('2026-10-22T18:00:00Z')) // EDT, UTC-4
    expect([keyOf(summer), summer.getHours(), summer.getMinutes()]).toEqual(['2026-10-22', 14, 0])
    const winter = shopNow(new Date('2026-12-01T18:00:00Z')) // EST, UTC-5
    expect([keyOf(winter), winter.getHours()]).toEqual(['2026-12-01', 13])
  })

  it('uses the Eastern date, even when it is already tomorrow in UTC', () => {
    const late = shopNow(new Date('2026-10-23T02:30:00Z'))
    expect([keyOf(late), late.getHours(), late.getMinutes()]).toEqual(['2026-10-22', 22, 30])
  })

  it('hides 11 am on a day it is already 2 pm in Eastern time', () => {
    const thursday = new Date(2026, 9, 22)
    const now = shopNow(new Date('2026-10-22T18:00:00Z'))
    const slots = slotsForDay({ date: thursday, minutes: 35, hours: HOURS, now, slotMinutes: SLOT })
    expect(slots[0]).toBeGreaterThan(at(14, 30)) // more than 30 minutes from 2 pm
    expect(slots).not.toContain(at(11))
  })
})
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import LogoCheckerboard from '../components/LogoCheckerboard.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, LIMITS, SMS_CONSENT, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, shopNow, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'
import { clearPending, loadPending, readReturn, savePending, tabStorage } from '../lib/paymentReturn.js'
import { AFTER_HOURS_ID, afterCount, afterDays, bookableServices, hoursFor, isAfterStart, slotFor } from '../lib/shopSettings.js'
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
  const start = shopNow()
  start.setHours(0, 0, 0, 0)
  return Array.from({ length: DAYS_AHEAD }, (_, i) => {
    const d = new Date(start)
    d.setDate(start.getDate() + i)
    return d
  })
}

function dayLabel(d) {
  const today = shopNow()
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
  const SERVICES = bookableServices(shop) // Vic's services, then After Hours Cuts
  const hours = useMemo(() => hoursFor(shop), [shop]) // opening hours with the late appointments added

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
  const [preselected] = useState(() => (resumed ? resumed.request.serviceId : serviceIdFromHash(window.location.hash, SERVICES)))
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
  const isAfter = !!service && service.afterHours === true // After Hours Cuts books only the late times, the others only regular ones
  const kindOf = (d, start) => isAfterStart(d, start) === isAfter

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
    const now = shopNow()
    const out = {}
    for (const d of days) {
      const k = keyOf(d)
      out[k] = slotsForDay({
        date: d,
        minutes: slotFor(shop, d),
        hours,
        busy: busy[k] || [],
        now,
        slotMinutes: slotFor(shop, d),
      }).filter((start) => isAfterStart(d, start) === isAfter)
    }
    return out
  }, [busy, service, days, shop, hours, isAfter])

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

  function chooseService(id, keepDay = false) {
    if (id !== serviceId) {
      setTime(null)
      // late times are on different days than regular ones, so the first day with openings is picked again
      if (!keepDay && (id === AFTER_HOURS_ID) !== (serviceId === AFTER_HOURS_ID)) setDateKey(null)
    }
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
      ? startsForDay({ date: selectedDay, minutes: slotFor(shop, selectedDay), hours, slotMinutes: slotFor(shop, selectedDay) }).filter((m) => kindOf(selectedDay, m))
      : []
  const lateService = SERVICES.find((s) => s.afterHours) || null
  // On a day that has late times, someone looking at the regular times is told, with a way to see them.
  const lateHint = !isAfter && lateService && selectedDay && afterCount(shop, selectedDay) > 0

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
              className={s.afterHours ? 'opt opt-after' : 'opt'}
              aria-pressed={serviceId === s.id}
              onClick={() => chooseService(s.id)}
            >
              <span className="name">{s.name}</span>
              {s.afterHours && <span className="after-badge">After hours</span>}
              <span className="leader" />
              <span className="price">{priceLabel(s)}</span>
              {s.note && <span className="note">{s.note}</span>}
              {s.afterHours && <span className="note">After closing on {afterDays(shop).join(' and ')}.</span>}
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
                  const closed = !hours[d.getDay()] || !!availability[k]?.dayOff // shop closed that weekday, or Vic took the day off
                  const free = (slotsByDay[k] || []).length
                  const none = isAfter && !closed && afterCount(shop, d) === 0 // no late times that weekday
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
                      <span className="tag">{closed ? 'Closed' : none ? 'None' : free ? '' : 'Full'}</span>
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
                          className={isAfter ? 'time time-after' : 'time'}
                          aria-pressed={time === m}
                          disabled={!open}
                          onClick={() => {
                            setTime(m)
                            setNotice('')
                          }}
                        >
                          {fmtTime(m)}
                          {isAfter && <span className="time-tag">After hours</span>}
                          {!open && <span className="sr-only"> (unavailable)</span>}
                        </button>
                      )
                    })}
                  </div>
                  {daySlots.length < dayStarts.length && <p className="times-note">Greyed-out times are not available.</p>}
                  {isAfter && (
                    <p className="times-note">
                      After hours cuts are ${service.price}, any service included. Just need a regular cut?{' '}
                      <button type="button" className="link-btn" onClick={() => chooseService(SERVICES.find((s) => !s.afterHours).id)}>
                        Pick a regular service
                      </button>
                    </p>
                  )}
                </>
              )}
              {lateHint && (
                <div className="late-hint">
                  <span className="after-badge">After hours</span>
                  <p>
                    Need a later time? {lateService.name} are after closing, {priceLabel(lateService)}, any service included.
                  </p>
                  <button type="button" className="btn" onClick={() => chooseService(lateService.id, true)}>
                    See late times
                  </button>
                </div>
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
                <span>
                  {service.name} ({slotFor(shop, fromKey(dateKey))} min), {priceLabel(service)}
                </span>
                {isAfter && <span className="after-badge after-badge-below">After hours</span>}
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
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/tests/test_shop.py\", \"base\": \"c404913d181edc4722a127e788676763149116d2dcdcd50e79e6f5a7b047f5d7\", \"new\": 0}, {\"path\": \"frontend/src/lib/availability.js\", \"base\": \"266760e0eb5e05a810c199c7eef60ac43f2d196d949bbc0418c3d60e39e1f9fc\", \"new\": 1}, {\"path\": \"frontend/src/lib/availability.test.js\", \"base\": \"1ebd47bf1381017b212d156103f73fc73b6fe46699aa14f4d739db8978153b8c\", \"new\": 2}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"2fba36028011bdc1b57f740863773585a8e0108f188362c9d26f0e1a0d6e1ee5\", \"new\": 3}]")

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
echo "Deploy the frontend. The backend already checked Eastern time, so no backend deploy is needed."
