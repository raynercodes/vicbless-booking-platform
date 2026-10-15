"""The things the shop deals with: bookings, blocked time, and their ids.

Plain frozen dataclasses. No web or AWS code in here.
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass
from datetime import date

from . import shop

# Booking codes skip look-alike characters (no 0/O, 1/I/L) so they are easy to read out over the phone.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

# The exact shape of an id we create. Anything else (a typo, an attack) is rejected before touching the database.
ID_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})\.(\d{4})\.([0-9a-f]{8})$")


def new_id(day: date, start: int) -> str:
    """'2026-10-12.0720.9f3a1c2b'. The date and start are inside it, so cancelling is a direct lookup."""
    return f"{day.isoformat()}.{shop.hhmm(start)}.{secrets.token_hex(4)}"


def parse_id(value: str) -> tuple[date, int] | None:
    """Returns (date, start minutes), or None if the id is not one we could have made."""
    m = ID_PATTERN.match(value or "")
    if not m:
        return None
    try:
        day = date.fromisoformat(m.group(1))
    except ValueError:
        return None
    hh, mm = int(m.group(2)[:2]), int(m.group(2)[2:])
    if hh > 23 or mm > 59:
        return None
    return day, hh * 60 + mm


def new_code() -> str:
    """A friendly code the customer keeps, like VB-K7M2QX. `secrets` (not `random`) so codes can't be predicted."""
    return "VB-" + "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))


@dataclass(frozen=True)
class Booking:
    """One customer's appointment. `id` is internal (used by Vic's dashboard); `code` is what the customer sees."""

    id: str
    code: str
    day: date
    start: int
    minutes: int
    service_id: str
    name: str
    phone: str
    email: str
    notes: str
    created_at: str
    # The service's name as it was when the customer booked, so a service Vic later renames or removes
    # still reads correctly on old bookings, emails and the dashboard.
    service_name: str = ""
    # The claims (5 minute units) the database really holds for this booking, read from its item. A booking made
    # before units existed holds fewer, and releasing exactly what is held is what keeps cancelling safe.
    held: tuple[int, ...] = ()
    # Did the customer tick "text me"? Texts to a customer go out only when they did.
    sms_consent: bool = False
    # When the booking was made or last moved (ISO, UTC). A reminder whose time had already passed by then is skipped.
    updated_at: str = ""
    # Which reminders were already sent, like "24h". Keeps a reminder from going out twice.
    reminders_sent: tuple[str, ...] = ()

    @property
    def claims(self) -> list[int]:
        """The 5 minute units this booking holds in the database."""
        return list(self.held) if self.held else shop.occupied_starts(self.start, self.minutes)

    def admin_view(self) -> dict:
        """What Vic's dashboard shows, contact details included."""
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "source": "online",
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
            "serviceName": self.service_name,
            "name": self.name,
            "phone": self.phone,
            "email": self.email,
            "notes": self.notes,
            "code": self.code,
            "smsConsent": self.sms_consent,
        }

    def public_view(self) -> dict:
        """What the customer gets back. The internal id is left out."""
        return {
            "code": self.code,
            "dateKey": self.day.isoformat(),
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
            "staffId": shop.STAFF_ID,
        }


@dataclass(frozen=True)
class Block:
    """Time Vic blocked off (lunch, a day off). `claims` are the 5 minute units it covers."""

    id: str
    day: date
    start: int
    end: int
    note: str
    whole: bool
    claims: tuple[int, ...]

    def admin_view(self) -> dict:
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "start": self.start,
            "end": self.end,
            "note": self.note,
            "whole": self.whole,
        }
