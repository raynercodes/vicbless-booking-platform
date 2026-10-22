"""The emails. Everything a customer typed is HTML-escaped; subjects have line breaks removed.

Every email ends with the same branded block (VICBLESS BARBERSHOP, the tagline, the address and the contact
email), in both the HTML and the plain-text version, so a customer can always tell who it is from.
"""

from __future__ import annotations

from html import escape

from ..core.brand import ADDRESS_LINES, BRAND_NAME, BRAND_TAGLINE, CONTACT_EMAIL
from ..domain import shop
from ..domain.models import Booking
from . import EmailMessage


def _when(booking: Booking) -> str:
    """'Tuesday, October 13 at 12:00 pm'."""
    d = booking.day
    return f"{d:%A}, {d:%B} {d.day} at {shop.label(booking.start)}"


def _subject(text: str) -> str:
    """Subjects can't contain line breaks (a way to sneak extra email headers in), so squash them to spaces."""
    return " ".join(text.replace("\r", " ").replace("\n", " ").split())


def _service_name(booking: Booking) -> str:
    """The service as it was named when the customer booked. (Bookings made before the name was stored fall back to the
    shop's starting list, and as a last resort to the id.)"""
    if booking.service_name:
        return booking.service_name
    service = shop.DEFAULT_SETTINGS.service(booking.service_id)
    return service.name if service else booking.service_id


# The site's colors: a dark purple-black ground with the lavender accent, so the email feels like the website.
_INK = "#0a0612"
_ACCENT = "#c084fc"
_SOFT = "#e9e0f7"
_MUTED = "#b8a9d0"


def brand_text() -> str:
    """The branded ending of the plain-text version of every email."""
    return f"{BRAND_NAME}\n{BRAND_TAGLINE}\n{', '.join(ADDRESS_LINES)}\n{CONTACT_EMAIL}\n"


def brand_html() -> str:
    """The branded ending of the HTML version. A table with inline styles, because that is what email apps render reliably.

    Plain text on purpose, not an image: many email apps hide pictures until the reader allows them, and a logo that is
    switched off would leave this block empty.
    """
    address = " &middot; ".join(escape(line) for line in ADDRESS_LINES)
    mail = escape(CONTACT_EMAIL, quote=True)
    return (
        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="{_INK}" '
        f'style="margin-top:28px;background:{_INK};border-radius:12px"><tr><td align="center" style="padding:24px 16px">'
        f'<div style="font-family:Arial Black,Arial,sans-serif;font-weight:900;font-size:22px;letter-spacing:3px;'
        f'color:{_ACCENT}">{escape(BRAND_NAME)}</div>'
        f'<div style="margin-top:6px;font-size:13px;color:{_SOFT}">{escape(BRAND_TAGLINE)}</div>'
        f'<div style="margin-top:12px;font-size:12px;line-height:1.5;color:{_MUTED}">{address}<br>'
        f'<a href="mailto:{mail}" style="color:{_ACCENT};text-decoration:underline">{escape(CONTACT_EMAIL)}</a></div>'
        "</td></tr></table>"
    )


def _page(title: str, rows: list[tuple[str, str]], footer: str) -> str:
    body = "".join(
        f'<tr><td style="padding:4px 16px 4px 0;color:#666">{escape(k)}</td><td style="padding:4px 0">{v}</td></tr>'
        for k, v in rows
    )
    return (
        '<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#111">'
        f'<h2 style="margin:0 0 12px">{escape(title)}</h2>'
        f'<table style="border-collapse:collapse">{body}</table>'
        f'<p style="margin-top:16px;color:#444">{escape(footer)}</p>'
        f"{brand_html()}</div>"
    )


def customer_confirmation(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Barber", "Vic"),
        ("Your code", f"<strong>{escape(booking.code)}</strong>"),
    ]
    paying = "Paid online, thank you." if booking.payment == "paid" else "Pay at the shop."
    footer = f"{paying} Need to change something? Reply to this email or write to {CONTACT_EMAIL} and quote your code."
    text = (
        f"You're booked with Vic.\n\nWhen: {when}\nService: {_service_name(booking)}\nYour code: {booking.code}\n\n{footer}\n\n"
        f"{brand_text()}"
    )
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"You're booked: {when}"),
        text=text,
        html=_page("You're booked with Vic", rows, footer),
        reply_to=owner_email,
    )


def owner_notification(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    email_cell = (
        f'<a href="mailto:{escape(booking.email, quote=True)}">{escape(booking.email)}</a>' if booking.email else "none given"
    )
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Payment", escape(booking.payment_label)),
        ("Name", escape(booking.name)),
        ("Phone", escape(booking.phone)),
        ("Email", email_cell),
        ("Notes", escape(booking.notes).replace("\n", "<br>") or "none"),
        ("Code", escape(booking.code)),
    ]
    text = (
        f"New booking\n\nWhen: {when}\nService: {_service_name(booking)}\nPayment: {booking.payment_label}\nName: {booking.name}\n"
        f"Phone: {booking.phone}\nEmail: {booking.email or 'none given'}\n"
        f"Notes: {booking.notes or 'none'}\nCode: {booking.code}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=owner_email,
        subject=_subject(f"New booking: {booking.name}, {when}"),
        text=text,
        html=_page("New booking", rows, "It is already on your schedule."),
        reply_to=booking.email,
    )


def customer_cancellation(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    footer = "Sorry about the change. You can book a new time anytime on the site."
    if booking.payment == "paid":
        footer = f"Your online payment is being refunded to your card. It can take a few days to show up. {footer}"
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"Your appointment was cancelled: {when}"),
        text=f"Your appointment with Vic on {when} was cancelled.\n\n{footer}\n\n{brand_text()}",
        html=_page("Your appointment was cancelled", [("Was booked for", escape(when))], footer),
        reply_to=owner_email,
    )


def customer_rescheduled(before: Booking, after: Booking, owner_email: str) -> EmailMessage:
    """Sent to the customer when Vic moves their appointment. Shows the old and the new time."""
    old_when, new_when = _when(before), _when(after)
    footer = f"If this time doesn't work for you, reply to this email or write to {CONTACT_EMAIL}."
    rows = [
        ("New time", f"<strong>{escape(new_when)}</strong>"),
        ("Was", escape(old_when)),
        ("Service", escape(_service_name(after))),
        ("Your code", escape(after.code)),
    ]
    text = (
        f"Vic moved your appointment.\n\nNew time: {new_when}\nWas: {old_when}\n"
        f"Service: {_service_name(after)}\nYour code: {after.code}\n\n{footer}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=after.email,
        subject=_subject(f"Your appointment was moved: {new_when}"),
        text=text,
        html=_page("Your appointment was moved", rows, footer),
        reply_to=owner_email,
    )


def customer_reminder(booking: Booking, owner_email: str) -> EmailMessage:
    """'See you soon': the same details as the confirmation, sent a set time before the appointment."""
    when = _when(booking)
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Where", escape(", ".join(ADDRESS_LINES))),
        ("Your code", f"<strong>{escape(booking.code)}</strong>"),
    ]
    paying = "Already paid online." if booking.payment == "paid" else "Pay at the shop."
    footer = f"{paying} Need to change it? Write to {CONTACT_EMAIL} and quote your code."
    text = (
        f"A reminder of your appointment with Vic.\n\nWhen: {when}\nService: {_service_name(booking)}\n"
        f"Where: {', '.join(ADDRESS_LINES)}\nYour code: {booking.code}\n\n{footer}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"Reminder: your appointment {when}"),
        text=text,
        html=_page("See you soon", rows, footer),
        reply_to=owner_email,
    )
