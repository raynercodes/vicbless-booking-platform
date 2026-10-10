"""The shop's rules: hours, services, the 35 minute grid, and what counts as a bookable time.

Pure functions with an injectable clock. Nothing here touches AWS, so every rule is easy to test.
This mirrors frontend/src/config.js and frontend/src/lib/availability.js. A test compares the two,
so the site and the API cannot quietly drift apart.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from ..core.errors import InvalidSlot, SlotUnavailable

# Vic's shop runs on this clock no matter where the server is. (Lambda's own clock is UTC.)
TIMEZONE = ZoneInfo("America/New_York")
STAFF_ID = "vic"
SLOT_MINUTES = 35  # Vic books in 35 minute blocks; every service takes one block (a longer one would take several)
DAYS_AHEAD = 14  # today plus the next 13 days, same as the booking page
LEAD_MINUTES = 30  # a time today must start more than this many minutes from now
MAX_BLOCK_DAYS_AHEAD = 365  # how far ahead Vic can block off time
MAX_RANGE_DAYS = 31  # the longest availability range one request may ask for


def at(hour: int, minute: int = 0) -> int:
    """at(12, 35) -> 755. Times are stored as minutes after midnight so they are easy to add and compare."""
    return hour * 60 + minute


# Opening hours per weekday. None = closed. A day can have several windows (Saturday has a lunch gap).
# Keyed by Python weekday: Monday = 0 ... Sunday = 6. (The frontend uses JavaScript's Sunday = 0;
# the contract test converts between the two, so a mix-up is caught.)
HOURS: dict[int, list[tuple[int, int]] | None] = {
    0: [(at(12), at(18))],
    1: [(at(12), at(18))],
    2: None,
    3: [(at(11), at(19))],
    4: [(at(11), at(19))],
    5: [(at(9), at(12)), (at(12, 35), at(17))],
    6: None,
}


@dataclass(frozen=True)
class Service:
    """One thing a customer can book. `minutes` is the real length; the API never trusts the site for it."""

    id: str
    name: str
    minutes: int


SERVICES: dict[str, Service] = {
    s.id: s
    for s in (
        Service("mens-cut", "Men's haircut", 35),
        Service("mens-design", "Men's haircut with design", 35),
        Service("mens-beard-eyebrow", "Men's haircut with beard and eyebrow", 35),
        Service("buzz-beard", "Head buzzed/shave and beard", 30),
        Service("kids-design", "Kids cut (12 and under) with design", 30),
    )
}


def now_local() -> datetime:
    """The current time in the shop's timezone. Tests replace this with a fixed clock."""
    return datetime.now(TIMEZONE)


def today(now: datetime) -> date:
    """Today's date in the shop's timezone (at 11 pm in Georgia it is already tomorrow in UTC)."""
    return now.astimezone(TIMEZONE).date()


def minutes_of_day(now: datetime) -> int:
    """What time it is in the shop, as minutes after midnight."""
    local = now.astimezone(TIMEZONE)
    return local.hour * 60 + local.minute


def hhmm(minutes: int) -> str:
    """440 -> '0720'. Used in sort keys so they sort in time order."""
    return f"{minutes // 60:02d}{minutes % 60:02d}"


def label(minutes: int) -> str:
    """Display time like '12:35 pm'."""
    h, m = divmod(minutes, 60)
    suffix = "am" if h < 12 else "pm"
    h12 = h % 12 or 12
    return f"{h12}:{m:02d} {suffix}"


def windows_for(day: date) -> list[tuple[int, int]]:
    """The opening windows for a date: [(open, close), ...], or [] if the shop is closed that day."""
    return HOURS[day.weekday()] or []


def is_open(day: date) -> bool:
    """Does Vic work that day at all?"""
    return bool(windows_for(day))


def grid_starts(day: date) -> list[int]:
    """Every block start of the day, across all opening windows (Saturday's break is not in it).

    Each window runs its own 35 minute grid from its opening time, and a block must end by closing.
    """
    out: list[int] = []
    for open_, close in windows_for(day):
        s = open_
        while s + SLOT_MINUTES <= close:
            out.append(s)
            s += SLOT_MINUTES
    return out


def blocks_for(minutes: int) -> int:
    """How many 35 minute blocks a service takes (always at least one)."""
    return max(1, -(-minutes // SLOT_MINUTES))


def occupied_starts(start: int, minutes: int) -> list[int]:
    """The block starts a booking holds. These become the "claims" in the database."""
    return [start + k * SLOT_MINUTES for k in range(blocks_for(minutes))]


def booking_window(now: datetime) -> tuple[date, date]:
    """The first and last day customers may book: today through 13 days from now."""
    first = today(now)
    return first, first + timedelta(days=DAYS_AHEAD - 1)


def fits(day: date, start: int, minutes: int) -> bool:
    """True if a service starting at `start` is on the grid and finishes inside one opening window.

    Same rule as the booking page: start + minutes <= closing time, and every block it covers is a
    real block of the day.
    """
    for open_, close in windows_for(day):
        if open_ <= start and start + minutes <= close and (start - open_) % SLOT_MINUTES == 0:
            valid = set(grid_starts(day))
            return all(s in valid for s in occupied_starts(start, minutes))
    return False


def check_bookable(day: date, start: int, minutes: int, now: datetime) -> None:
    """Raise InvalidSlot (can never work) or SlotUnavailable (not right now). Returns None if OK."""
    # 1. Structure: is this a real block of a real opening day? If not, no amount of waiting will fix it.
    if not fits(day, start, minutes):
        raise InvalidSlot()
    # 2. Timing: a real time can still be too early, too late, or too far away.
    first, last = booking_window(now)
    if day < first or day > last:
        raise SlotUnavailable()
    # Today only: Vic needs notice, so a time must start more than 30 minutes from now.
    if day == first and start <= minutes_of_day(now) + LEAD_MINUTES:
        raise SlotUnavailable()


def check_movable(day: date, start: int, minutes: int, now: datetime) -> None:
    """Rules for Vic moving a booking. Looser than for customers: no 14 day limit and no 30 minute notice.

    It still has to be a real block of an open day, it can't be in the past, and it can't be more than a year out.
    Raises InvalidSlot. (Whether the time is free is decided by the database, not here.)
    """
    if not fits(day, start, minutes):
        raise InvalidSlot()
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can move a booking to any open time from now up to a year ahead.")
    if day == first and start <= minutes_of_day(now):
        raise InvalidSlot("That time has already passed today. Pick a later one.")


def block_starts_in_range(day: date, start: int, end: int) -> list[int]:
    """The grid blocks a block-off covers: every block that starts at or after `start` and before `end`."""
    return [s for s in grid_starts(day) if start <= s < end]


def check_blockable(day: date, now: datetime) -> None:
    """Vic can only block an open day, from today up to a year ahead. Raises InvalidSlot otherwise."""
    if not is_open(day):
        raise InvalidSlot("The shop is already closed that day, so there is nothing to block.")
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can block time from today up to a year ahead.")
