"""The shop's rules: hours, the settings Vic can edit, and what counts as a bookable time.

Pure functions with an injectable clock. Nothing here touches AWS, so every rule is easy to test.

What is fixed here: the opening HOURS. What Vic edits in his dashboard (and is stored in the database):
the services and prices, and how long an appointment is on each weekday. Those live in a ShopSettings,
which the functions below receive, and DEFAULT_SETTINGS is what the shop starts with. The site has its own
copy of the defaults in frontend/src/config.js, and a test compares the two.

Time is counted in 5 minute UNITS. A booking (or blocked-off time) "claims" every unit it covers, so two things
can only share a unit if they overlap. That is what lets the appointment length change from day to day (or later)
without a double booking ever becoming possible.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from ..core.errors import InvalidSlot, SlotUnavailable

# Vic's shop runs on this clock no matter where the server is. (Lambda's own clock is UTC.)
TIMEZONE = ZoneInfo("America/New_York")
STAFF_ID = "vic"
UNIT_MINUTES = 5  # the smallest piece of time. Every appointment length is a whole number of these.
MIN_SLOT_MINUTES = 15  # the shortest appointment Vic can set
MAX_SLOT_MINUTES = 120  # the longest appointment Vic can set
REMINDER_CHOICES = (1, 2, 3, 4, 6, 12, 24, 48)  # the reminder times Vic can switch on (hours before the appointment)
DAYS_AHEAD = 14  # today plus the next 13 days, same as the booking page
LEAD_MINUTES = 30  # a time today must start more than this many minutes from now
MAX_BLOCK_DAYS_AHEAD = 365  # how far ahead Vic can block off time
MAX_RANGE_DAYS = 31  # the longest availability range one request may ask for
MAX_SERVICES = 12  # how many services Vic can list


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

# Weekday names used by the API (the frontend turns its own Sunday-first numbers into these).
WEEKDAY_KEYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


@dataclass(frozen=True)
class Service:
    """One thing a customer can book. `price` is whole dollars; from_price shows it as "$65+". The length is NOT
    here: every booking takes one appointment slot, and the slot length is a setting of the day."""

    id: str
    name: str
    price: int
    from_price: bool = False
    note: str = ""


@dataclass(frozen=True)
class ShopSettings:
    """Everything Vic can change from his dashboard."""

    slot_minutes: tuple[int, int, int, int, int, int, int]  # appointment length, Monday ... Sunday
    services: tuple[Service, ...]  # in the order they are shown
    # How many hours before an appointment a reminder goes out (each one is a separate reminder). Empty = no reminders.
    reminder_hours: tuple[int, ...] = (24, 2)

    def slot_for(self, day: date) -> int:
        """How long an appointment is on this date."""
        return self.slot_minutes[day.weekday()]

    def service(self, service_id: str) -> Service | None:
        for s in self.services:
            if s.id == service_id:
                return s
        return None


DEFAULT_SETTINGS = ShopSettings(
    # Monday and Tuesday are 45 minutes (Vic's request, 2026-10-13); every other day stays at 35.
    slot_minutes=(45, 45, 35, 35, 35, 35, 35),
    services=(
        Service("mens-cut", "Men's haircut", 55),
        Service("mens-design", "Men's haircut with design", 65, True, "Small or freestyle design"),
        Service(
            "mens-beard-eyebrow",
            "Men's haircut with beard and eyebrow",
            65,
            True,
            "Includes free hot towel if requested and hair styling",
        ),
        Service(
            "buzz-beard",
            "Head buzzed/shave and beard",
            40,
            False,
            "Same price for just beards. Tell Vic in person if you want it buzzed or shaved.",
        ),
        Service(
            "kids-design",
            "Kids cut (12 and under) with design",
            40,
            True,
            "$5 extra for a small design, $10 more for a bigger design",
        ),
    ),
)


def starts_at(day: date, start: int) -> datetime:
    """The exact moment an appointment begins, in the shop's timezone (so 'now' can be compared with it)."""
    return datetime(day.year, day.month, day.day, tzinfo=TIMEZONE) + timedelta(minutes=start)


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


def grid_starts(day: date, slot: int) -> list[int]:
    """Every appointment start of the day, across all opening windows (Saturday's break is not in it).

    Each window runs its own grid from its opening time, and an appointment must end by closing.
    """
    out: list[int] = []
    for open_, close in windows_for(day):
        s = open_
        while s + slot <= close:
            out.append(s)
            s += slot
    return out


def occupied_starts(start: int, minutes: int) -> list[int]:
    """The 5 minute units an appointment of `minutes` starting at `start` holds. These become the "claims" in the database."""
    return list(range(start, start + minutes, UNIT_MINUTES))


def booking_window(now: datetime) -> tuple[date, date]:
    """The first and last day customers may book: today through 13 days from now."""
    first = today(now)
    return first, first + timedelta(days=DAYS_AHEAD - 1)


def fits(day: date, start: int, slot: int) -> bool:
    """True if an appointment starting at `start` is on that day's grid and finishes inside one opening window."""
    for open_, close in windows_for(day):
        if open_ <= start and start + slot <= close and (start - open_) % slot == 0:
            return True
    return False


def check_bookable(day: date, start: int, slot: int, now: datetime) -> None:
    """Raise InvalidSlot (can never work) or SlotUnavailable (not right now). Returns None if OK."""
    # 1. Structure: is this a real slot of a real opening day? If not, no amount of waiting will fix it.
    if not fits(day, start, slot):
        raise InvalidSlot()
    # 2. Timing: a real time can still be too early, too late, or too far away.
    first, last = booking_window(now)
    if day < first or day > last:
        raise SlotUnavailable()
    # Today only: Vic needs notice, so a time must start more than 30 minutes from now.
    if day == first and start <= minutes_of_day(now) + LEAD_MINUTES:
        raise SlotUnavailable()


def check_movable(day: date, start: int, slot: int, now: datetime) -> None:
    """Rules for Vic moving a booking. Looser than for customers: no 14 day limit and no 30 minute notice.

    It still has to be a real slot of an open day, it can't be in the past, and it can't be more than a year out.
    Raises InvalidSlot. (Whether the time is free is decided by the database, not here.)
    """
    if not fits(day, start, slot):
        raise InvalidSlot()
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can move a booking to any open time from now up to a year ahead.")
    if day == first and start <= minutes_of_day(now):
        raise InvalidSlot("That time has already passed today. Pick a later one.")


def block_units(day: date, start: int, end: int) -> list[int]:
    """The 5 minute units a block-off covers: everything from `start` up to `end` that lies inside opening hours.

    The range is widened to whole units. Saturday's lunch gap is never included, so a whole-day block does not claim it.
    """
    first = start - start % UNIT_MINUTES
    last = end + (-end) % UNIT_MINUTES
    out: list[int] = []
    for open_, close in windows_for(day):
        out.extend(u for u in range(max(first, open_), min(last, close), UNIT_MINUTES))
    return out


def busy_slots(day: date, slot: int, taken_units: set[int]) -> list[int]:
    """The appointment starts of the day's grid that overlap anything taken (a booking or blocked time)."""
    return [s for s in grid_starts(day, slot) if any(u in taken_units for u in range(s, s + slot, UNIT_MINUTES))]


def check_blockable(day: date, now: datetime) -> None:
    """Vic can only block an open day, from today up to a year ahead. Raises InvalidSlot otherwise."""
    if not is_open(day):
        raise InvalidSlot("The shop is already closed that day, so there is nothing to block.")
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can block time from today up to a year ahead.")
