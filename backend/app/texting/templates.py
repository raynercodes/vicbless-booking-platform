"""The texts. Short and plain (no emoji, no links) so they send as few segments as possible and are never filtered.

Every text to a customer says who it is from and ends with the opt-out line carriers expect. Texts to Vic himself
do not need it. Everything a customer typed is flattened to one line first.

NO WEB ADDRESSES OR EMAIL ADDRESSES in a text. Textbelt refuses any message that looks like it holds a link ("ability to
send URLs via text is limited to verified accounts"), and "vicslegacy89@gmail.com" looks like one because of the ".com". So
the texts say "email Vic" and leave the address to the email and the website. A test checks that no text can contain one,
even when a customer types a name like "shop.com".
"""

from __future__ import annotations

import re

from ..core.brand import ADDRESS_LINES, BRAND_NAME
from ..domain import shop
from ..domain.models import Booking

OPT_OUT = "Reply STOP to opt out."


EMAIL_HINT = "To change it, email Vic (his address is on our site)."


def _line(text: str, limit: int) -> str:
    """One line, no control characters, and nothing that looks like a web or email address, cut to `limit` characters.
    A dot between letters or digits (shop.com) and an @ are turned into spaces so Textbelt never reads it as a link."""
    clean = "".join(c if c.isprintable() else " " for c in text)
    clean = re.sub(r"(?<=\w)[.@/:](?=\w)", " ", clean)
    return " ".join(clean.split())[:limit]


def _when(booking: Booking) -> str:
    """'Tue, Oct 13 at 12:45 pm'."""
    d = booking.day
    return f"{d:%a}, {d:%b} {d.day} at {shop.label(booking.start)}"


def _service(booking: Booking) -> str:
    if booking.service_name:
        return booking.service_name
    service = shop.DEFAULT_SETTINGS.service(booking.service_id)
    return service.name if service else booking.service_id


def _text(*parts: str) -> str:
    """Joins the parts of a text with line breaks; '' makes a blank line. Only our own wording passes through here,
    anything a customer typed has already been through `_line`, which removes line breaks."""
    return "\n".join(parts)


def owner_new_booking(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "New booking",
        "",
        f"{_line(booking.name, 40)}",
        f"{_line(_service(booking), 50)}",
        f"{_when(booking)}",
        "",
        f"Phone: {booking.phone}",
        f"Code: {booking.code}",
        f"Payment: {booking.payment_label}",
    )


def customer_confirmation(booking: Booking) -> str:
    first = _line(booking.name.split()[0] if booking.name.split() else "", 20)
    return _text(
        f"{BRAND_NAME}",
        f"You're booked, {first}!" if first else "You're booked!",
        "",
        f"{_when(booking)}",
        f"{_line(_service(booking), 50)} with Vic",
        f"Code: {booking.code}",
        "",
        "Paid online. Thank you!" if booking.payment == "paid" else "Pay at the shop.",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )


def customer_cancellation(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Your appointment was cancelled.",
        "",
        f"Was: {_when(booking)}",
        "",
        "Your online payment will be refunded to your card." if booking.payment == "paid" else "You can book a new time anytime on our site.",
        "",
        OPT_OUT,
    )


def customer_rescheduled(before: Booking, after: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Your appointment moved.",
        "",
        f"Now: {_when(after)}",
        f"Was: {_when(before)}",
        f"Code: {after.code}",
        "",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )


def customer_reminder(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Reminder: you're booked.",
        "",
        f"{_when(booking)}",
        f"{ADDRESS_LINES[0]}",
        f"Code: {booking.code}",
        "",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )
