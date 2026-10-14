"""What the site is allowed to send us.

Every request body is checked and cleaned here, BEFORE any business logic runs:
  - anything not listed in a model is ignored (for example the `minutes` the site sends: the API
    works out the real length from the day's setting, so a customer can never choose how long a cut takes)
  - text is stripped of hidden control characters and extra spaces
  - the error messages are written for customers and for Vic, not for programmers. The site shows
    them as they are, so they must read like a person wrote them.

The limits below are mirrored in frontend/src/config.js (LIMITS). A test compares the two.
"""

from __future__ import annotations

import re
import unicodedata
from datetime import date

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, field_validator

from ..core.errors import ValidationFailed
from ..domain import shop

# --- limits (the frontend counter and maxLength use the same numbers) ---------------------------
NAME_MIN = 2
NAME_MAX = 50
NOTES_MAX = 500
NOTE_MAX = 80  # Vic's own label on a blocked-off time, like "Lunch"
EMAIL_MAX = 254  # the longest an email address can legally be
PHONE_MIN_DIGITS = 10
PHONE_MAX_DIGITS = 15  # the international maximum
SERVICE_NAME_MIN = 2
SERVICE_NAME_MAX = 60
SERVICE_NOTE_MAX = 120
SERVICE_PRICE_MAX = 999  # dollars
SERVICE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

# Deliberately simple: "something@something.something" with no spaces. Real validation of an email
# address means actually sending to it, so we only catch obvious typos here.
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# --- the friendly messages ---------------------------------------------------------------------
MSG_NAME = f"Please enter your name, between {NAME_MIN} and {NAME_MAX} characters."
MSG_PHONE = f"Please enter a mobile number with at least {PHONE_MIN_DIGITS} digits so Vic can reach you."
MSG_EMAIL = "That email doesn't look right. Use something like name@example.com, or leave it blank."
MSG_NOTES = f"Notes can be up to {NOTES_MAX} characters. Please shorten yours a little."
MSG_DATE = "That date isn't valid. Please pick a day from the calendar."
MSG_TIME = "Please pick a time from the list."
MSG_SERVICE = "Please pick a service from the list."
MSG_STAFF = "Please pick a barber from the list."
MSG_PASSWORD = "Please enter your password."
MSG_SERVICE_NAME = f"Each service needs a name, between {SERVICE_NAME_MIN} and {SERVICE_NAME_MAX} characters."
MSG_SERVICE_PRICE = f"A price has to be a whole number of dollars, from 0 to {SERVICE_PRICE_MAX}."
MSG_SERVICE_NOTE = f"A service note can be up to {SERVICE_NOTE_MAX} characters. Please shorten it a little."
MSG_SERVICE_ID = "Something is wrong with that service. Reload the dashboard and try again."
MSG_SERVICES_COUNT = f"List between 1 and {shop.MAX_SERVICES} services."
MSG_SERVICES_DUPLICATE = "Two services have the same name. Give each one its own name."
MSG_SLOTS = (
    f"Each appointment length has to be between {shop.MIN_SLOT_MINUTES} and {shop.MAX_SLOT_MINUTES} minutes, "
    f"in steps of {shop.UNIT_MINUTES}."
)
MSG_REMINDERS = "Pick reminder times from the list."
MSG_SLOT_DAYS = "Set an appointment length for every day of the week."


def clean_text(value: str, *, keep_newlines: bool = False) -> str:
    """Removes invisible control characters (they can break emails and logs) and turns tabs into spaces.

    With keep_newlines=True line breaks survive (used for notes), and Windows-style "\\r\\n" counts as
    ONE line break, the same way the browser counts it, so a 500-character note is 500 on both sides.
    """
    if keep_newlines:
        value = value.replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for ch in value:
        if ch == "\n" and keep_newlines:
            out.append(ch)
        elif ch == "\t":
            out.append(" ")
        elif unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp"):
            continue  # control, format, line/paragraph separator characters
        else:
            out.append(ch)
    return "".join(out)


def one_line(value: str) -> str:
    """Single-line text: cleaned, with runs of spaces and any line breaks squashed into one space."""
    return " ".join(clean_text(value).split())


def parse_date_key(value: str) -> date:
    """'2026-10-12' -> a date. Raises ValueError (what the validators below expect) if it is not a real day."""
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError(MSG_DATE)
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ValueError(MSG_DATE) from None  # e.g. 2026-02-31


def date_from_query(value: str) -> date:
    """Same as parse_date_key, but for dates in a URL (?date=...): failures become a 422 API error."""
    try:
        return parse_date_key(value)
    except ValueError as err:
        raise ValidationFailed(str(err)) from None


def normalize_phone(value: str) -> str:
    """'(555) 010-1234' or '+1 555 010 1234' -> '5550101234'. Digits only, US country code dropped.

    Storing digits only means the same person typing their number two different ways is still the same
    person (used for the "3 upcoming bookings" limit and for spotting a retried request).
    """
    digits = re.sub(r"\D", "", value)
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    if not PHONE_MIN_DIGITS <= len(digits) <= PHONE_MAX_DIGITS:
        raise ValueError(MSG_PHONE)
    return digits


class BookingIn(BaseModel):
    """A customer booking a time (POST /api/bookings)."""

    model_config = ConfigDict(extra="ignore")  # unknown fields (like `minutes`) are dropped, not trusted

    staffId: str = shop.STAFF_ID
    serviceId: str
    dateKey: str
    start: StrictInt  # StrictInt: "720" or true are refused instead of being quietly converted
    name: str
    phone: str
    email: str | None = None
    notes: str | None = None
    smsConsent: StrictBool = False  # ticked "text me" (texts to a customer go out only when this is true)

    @field_validator("staffId")
    @classmethod
    def _staff(cls, v: str) -> str:
        if v != shop.STAFF_ID:
            raise ValueError(MSG_STAFF)
        return v

    @field_validator("serviceId")
    @classmethod
    def _service(cls, v: str) -> str:
        # Only the shape is checked here. Whether it is one of Vic's CURRENT services is decided in services/bookings.py,
        # because Vic can change the list at any time.
        if not SERVICE_ID_PATTERN.match(v):
            raise ValueError(MSG_SERVICE)
        return v

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)  # only checks it is a real date; the booking rules check if it is bookable
        return v

    @field_validator("start")
    @classmethod
    def _start(cls, v: int) -> int:
        # Minutes after midnight. Whether it is a time Vic works is decided later by domain/shop.py.
        if not 0 <= v < 24 * 60:
            raise ValueError(MSG_TIME)
        return v

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = one_line(v)
        if not NAME_MIN <= len(v) <= NAME_MAX:
            raise ValueError(MSG_NAME)
        return v

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)

    @field_validator("email")
    @classmethod
    def _email(cls, v: str | None) -> str:
        v = one_line(v or "")
        if not v:
            return ""  # email is optional
        if len(v) > EMAIL_MAX or not EMAIL_PATTERN.match(v):
            raise ValueError(MSG_EMAIL)
        return v

    @field_validator("notes")
    @classmethod
    def _notes(cls, v: str | None) -> str:
        v = clean_text(v or "", keep_newlines=True).strip()
        if len(v) > NOTES_MAX:
            raise ValueError(MSG_NOTES)
        return v


class LoginIn(BaseModel):
    """Vic signing in (POST /api/admin/login)."""

    model_config = ConfigDict(extra="ignore")

    password: str

    @field_validator("password")
    @classmethod
    def _length(cls, v: str) -> str:
        # The upper limit stops someone sending a huge "password" just to make the server hash it.
        if not 1 <= len(v) <= 200:
            raise ValueError(MSG_PASSWORD)
        return v


class MoveIn(BaseModel):
    """Vic moving a booking to another day and time (PATCH /api/admin/bookings/{id})."""

    model_config = ConfigDict(extra="ignore")

    dateKey: str
    start: StrictInt

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)
        return v

    @field_validator("start")
    @classmethod
    def _start(cls, v: int) -> int:
        if not 0 <= v < 24 * 60:
            raise ValueError(MSG_TIME)
        return v


class BlockIn(BaseModel):
    """Vic blocking off time (POST /api/admin/blocks): either a range of the day, or the whole day."""

    model_config = ConfigDict(extra="ignore")

    dateKey: str
    start: StrictInt = 0  # minutes after midnight; ignored when whole is true
    end: StrictInt = 0
    note: str | None = None
    whole: bool = False

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)
        return v

    @field_validator("note")
    @classmethod
    def _note(cls, v: str | None) -> str:
        return one_line(v or "")[:NOTE_MAX]  # a long label is trimmed rather than refused


class ServiceIn(BaseModel):
    """One service in Vic's settings. A service that already exists keeps its `id`; a new one has none yet."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str | None = None
    name: str
    price: StrictInt
    # "from" is a Python keyword, so the field is called from_price and given its JSON name with alias.
    from_price: StrictBool = Field(default=False, alias="from")
    note: str | None = None

    @field_validator("id")
    @classmethod
    def _id(cls, v: str | None) -> str | None:
        if v in (None, ""):
            return None
        if not SERVICE_ID_PATTERN.match(v):
            raise ValueError(MSG_SERVICE_ID)
        return v

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = one_line(v)
        if not SERVICE_NAME_MIN <= len(v) <= SERVICE_NAME_MAX:
            raise ValueError(MSG_SERVICE_NAME)
        return v

    @field_validator("price")
    @classmethod
    def _price(cls, v: int) -> int:
        if not 0 <= v <= SERVICE_PRICE_MAX:
            raise ValueError(MSG_SERVICE_PRICE)
        return v

    @field_validator("note")
    @classmethod
    def _note(cls, v: str | None) -> str:
        v = one_line(v or "")
        if len(v) > SERVICE_NOTE_MAX:
            raise ValueError(MSG_SERVICE_NOTE)
        return v


class SettingsIn(BaseModel):
    """Vic saving his settings (PUT /api/admin/settings): the whole list of services, and an appointment length per day."""

    model_config = ConfigDict(extra="ignore")

    services: list[ServiceIn]
    slotMinutes: dict[str, StrictInt]  # {"mon": 45, "tue": 45, ...} every weekday, in minutes
    reminderHours: list[StrictInt] | None = None  # hours before an appointment; [] = none; left out = keep what is saved

    @field_validator("services")
    @classmethod
    def _services(cls, v: list[ServiceIn]) -> list[ServiceIn]:
        if not 1 <= len(v) <= shop.MAX_SERVICES:
            raise ValueError(MSG_SERVICES_COUNT)
        ids = [s.id for s in v if s.id]
        if len(ids) != len(set(ids)):
            raise ValueError(MSG_SERVICE_ID)
        names = [s.name.casefold() for s in v]
        if len(names) != len(set(names)):
            raise ValueError(MSG_SERVICES_DUPLICATE)
        return v

    @field_validator("reminderHours")
    @classmethod
    def _reminders(cls, v: list[int] | None) -> list[int] | None:
        if v is None:
            return None
        if len(set(v)) != len(v) or any(h not in shop.REMINDER_CHOICES for h in v):
            raise ValueError(MSG_REMINDERS)
        return v

    @field_validator("slotMinutes")
    @classmethod
    def _slots(cls, v: dict[str, int]) -> dict[str, int]:
        if set(v) != set(shop.WEEKDAY_KEYS):
            raise ValueError(MSG_SLOT_DAYS)
        for minutes in v.values():
            if not shop.MIN_SLOT_MINUTES <= minutes <= shop.MAX_SLOT_MINUTES or minutes % shop.UNIT_MINUTES:
                raise ValueError(MSG_SLOTS)
        return v
