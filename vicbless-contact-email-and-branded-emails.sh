#!/usr/bin/env bash
# Vicbless: contact email instead of the phone number, and a branded ending on every email (build 2026-10-14 a).
# Run from the REPO ROOT:  bash vicbless-contact-email-and-branded-emails.sh
#
#   SITE    wherever the phone number was shown (the shop info, the booking page's "Need to change it?" line and its
#           error line) now shows vicslegacy89@gmail.com as a tap-to-write link. PhoneLink.jsx becomes EmailLink.jsx.
#   EMAILS  all four emails (confirmation, new booking, cancelled, moved) end with a VICBLESS BARBERSHOP block
#           (name, tagline, address, email) in the HTML and plain-text versions, and say "write to vicslegacy89@gmail.com".
#   OTHER   the 'too many bookings' message says to email Vic; the search-engine data gains the email.
#   TESTS   new ones for the branding, the wording, and the email matching on the site and in the backend.
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
"""Who the shop is, in one place: the name, address and contact email that customers see.

Used by the emails (their branded footer) and by the error messages that tell a customer how to reach Vic.
Kept in core/ with no imports, so anything can use it. The site has its own copy in frontend/src/config.js,
and a test checks the two match.
"""

from __future__ import annotations

BRAND_NAME = "VICBLESS BARBERSHOP"
BRAND_TAGLINE = "Every cut isn't just a cut. It's a blessing."
CONTACT_EMAIL = "vicslegacy89@gmail.com"
ADDRESS_LINES: tuple[str, ...] = ("656 S Main St, Suite C", "Baxley, GA 31513")
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
"""Errors the API turns into the JSON shape { "error": { "code", "message" } }.

Each error carries three things the site needs:
  status   the HTTP status code
  code     a short stable word the frontend can branch on (for example "slot_taken")
  message  a sentence that is safe to show a customer or Vic as it is, so keep them friendly and plain
Raise one of these from anywhere in the app; core/web.py turns it into the response.
"""

from .brand import CONTACT_EMAIL


class ApiError(Exception):
    status = 400
    code = "bad_request"

    def __init__(self, message: str | None = None, *, code: str | None = None):
        super().__init__(message or self.default_message)
        self.message = message or self.default_message
        if code:
            self.code = code

    default_message = "Something went wrong with that request. Please try again."


class ValidationFailed(ApiError):
    status = 422
    code = "validation_error"
    default_message = "Some of the details aren't valid. Please check them and try again."


class InvalidSlot(ApiError):
    """The time can never be booked: closed day, off the grid, or does not fit in the day."""

    status = 422
    code = "invalid_slot"
    default_message = "That isn't a time Vic takes bookings for. Please pick another."


class SlotUnavailable(ApiError):
    """The time could be booked in general but not right now: past, too soon, or too far ahead."""

    status = 409
    code = "slot_unavailable"
    default_message = "That time is no longer available. Please pick another."


class SlotTaken(ApiError):
    status = 409
    code = "slot_taken"
    default_message = "Sorry, that time was just taken. Please pick another."


class Conflict(ApiError):
    status = 409
    code = "conflict"
    default_message = "That overlaps a booking or time you already blocked off."


class NotFound(ApiError):
    status = 404
    code = "not_found"
    default_message = "We couldn't find that."


class Unauthorized(ApiError):
    status = 401
    code = "unauthorized"
    default_message = "Please sign in to continue."


class TooManyBookings(ApiError):
    status = 429
    code = "too_many_bookings"
    default_message = f"This phone number already has the most upcoming bookings we allow. Please email Vic at {CONTACT_EMAIL} to change one."


class TooManyAttempts(ApiError):
    status = 429
    code = "too_many_attempts"
    default_message = "Too many tries. Please wait about 15 minutes, then try again."


class NotConfigured(ApiError):
    status = 503
    code = "not_configured"
    default_message = "This part of the service isn't set up yet."
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
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
    service = shop.SERVICES.get(booking.service_id)
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
    footer = f"Pay at the shop. Need to change something? Reply to this email or write to {CONTACT_EMAIL} and quote your code."
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
        ("Name", escape(booking.name)),
        ("Phone", escape(booking.phone)),
        ("Email", email_cell),
        ("Notes", escape(booking.notes).replace("\n", "<br>") or "none"),
        ("Code", escape(booking.code)),
    ]
    text = (
        f"New booking\n\nWhen: {when}\nService: {_service_name(booking)}\nName: {booking.name}\n"
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
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Booking rules in action: what happens when a customer asks for a time.

This layer decides WHAT should happen and in which order. It calls the shop rules (domain/shop.py)
to ask "is this a valid time?" and the database layer to actually store it. It knows nothing about
web requests or DynamoDB details, which is what keeps it easy to read and easy to test.
"""

from __future__ import annotations

from datetime import date, datetime

from ..core.brand import CONTACT_EMAIL
from ..core.errors import NotFound, SlotTaken, TooManyBookings, ValidationFailed
from ..database import bookings as bookings_db
from ..database import schedule
from ..domain import shop
from ..domain.models import Booking, new_code
from ..schemas.requests import BookingIn, MoveIn, parse_date_key

# Anti-spam: one phone number can hold at most this many upcoming bookings at a time.
MAX_UPCOMING_PER_PHONE = 3


def get_availability(first: date, last: date) -> dict[str, dict]:
    """Which times are taken, day by day, for the booking page's grid. Works for up to 31 days at once."""
    if last < first:
        raise ValidationFailed("The end date can't be before the start date.")
    if (last - first).days + 1 > shop.MAX_RANGE_DAYS:
        raise ValidationFailed(f"Please ask for {shop.MAX_RANGE_DAYS} days or fewer at a time.")
    return schedule.availability(first, last)


def _same_request(existing: Booking | None, data: BookingIn, day: date) -> Booking | None:
    """Is `existing` the booking THIS request already made?

    A customer who double-taps the button, or whose phone loses signal right after the booking went
    through, sends the same request twice. The second one should get their booking back, not an
    error that says the time was taken (by them). "Same request" means the same person, service and time.
    """
    if (
        existing
        and existing.day == day
        and existing.start == data.start
        and existing.phone == data.phone
        and existing.service_id == data.serviceId
        and existing.name.casefold() == data.name.casefold()
    ):
        return existing
    return None


def create_booking(data: BookingIn, now: datetime) -> tuple[Booking, bool]:
    """Books the time. Returns (booking, created); created is False when this exact request had already succeeded.

    Order matters:
      1. is it a time Vic could ever take, and is it open right now?  (shop rules, no database)
      2. does this phone number already hold too many upcoming bookings?  (anti-spam)
      3. try to claim the time. The database refuses if anyone got there first.
    """
    day = parse_date_key(data.dateKey)
    minutes = shop.SERVICES[data.serviceId].minutes  # the length comes from the service, never from the client
    shop.check_bookable(day, data.start, minutes, now)

    def earlier_attempt() -> Booking | None:
        # Look at who owns this exact time right now, and check if it is this same request.
        return _same_request(bookings_db.booking_holding(day, data.start), data, day)

    if bookings_db.upcoming_for_phone(data.phone, shop.today(now)) >= MAX_UPCOMING_PER_PHONE:
        # The cap is reached, but a retry of an already-made booking must still be answered with it.
        replay = earlier_attempt()
        if replay:
            return replay, False
        raise TooManyBookings(
            f"This phone number already has {MAX_UPCOMING_PER_PHONE} upcoming bookings, which is the most we allow. "
            f"Please email Vic at {CONTACT_EMAIL} if you need to change one."
        )
    try:
        booking = bookings_db.create_booking(
            day=day,
            start=data.start,
            service_id=data.serviceId,
            minutes=minutes,
            name=data.name,
            phone=data.phone,
            email=data.email or "",
            notes=data.notes or "",
            code=new_code(),
        )
    except SlotTaken:
        # Someone holds the time. If that someone is this very request (a retry), hand it back.
        replay = earlier_attempt()
        if replay:
            return replay, False
        raise
    return booking, True


def cancel_booking(booking_id: str) -> Booking:
    """Vic cancels a booking. Frees every block it held, and returns it so the customer can be told."""
    return bookings_db.cancel_booking(booking_id)


def move_booking(booking_id: str, data: MoveIn, now: datetime) -> tuple[Booking, Booking]:
    """Vic moves a booking to another time. Returns (before, after) so the customer can be told both.

    The customer keeps the same code. The booking gets a new id, because the id contains the day and time.
    """
    before = bookings_db.get_booking(booking_id)
    if not before:
        raise NotFound("That booking was not found. It may already be cancelled.")
    day = parse_date_key(data.dateKey)
    if (day, data.start) == (before.day, before.start):
        raise ValidationFailed("That booking is already at that time. Pick a different one.")
    shop.check_movable(day, data.start, before.minutes, now)
    after = bookings_db.move_booking(before, day=day, start=data.start)  # raises SlotTaken if the time is not free
    return before, after
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""The site and the API must agree on hours, services and the slot grid. This reads the real frontend config."""

import re
from pathlib import Path

from app.domain import shop

CONFIG = Path(__file__).resolve().parents[2] / "frontend" / "src" / "config.js"


def source() -> str:
    assert CONFIG.exists(), f"Expected the frontend config at {CONFIG}. The contract test needs the whole repo."
    return CONFIG.read_text()


def block(text: str, start: str, end: str) -> str:
    i = text.index(start)
    return text[i : text.index(end, i)]


def test_slot_minutes_and_days_ahead():
    text = source()
    assert int(re.search(r"export const SLOT_MINUTES = (\d+)", text).group(1)) == shop.SLOT_MINUTES
    assert int(re.search(r"export const DAYS_AHEAD = (\d+)", text).group(1)) == shop.DAYS_AHEAD


def test_staff():
    assert "id: 'vic'" in block(source(), "export const STAFF", "\n")


def test_hours_match():
    body = block(source(), "export const HOURS = {", "\n}")
    body = re.sub(r"//[^\n]*", "", body).split("{", 1)[1]
    body = re.sub(r"at\((\d+),\s*(\d+)\)", r"(\1*60+\2)", body)
    body = re.sub(r"at\((\d+)\)", r"(\1*60)", body)
    js_hours = eval("{" + body.replace("null", "None") + "}", {"__builtins__": {}})  # our own repo file
    assert set(js_hours) == set(range(7))
    for js_day, windows in js_hours.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        expected = [tuple(w) for w in windows] if windows else None
        assert shop.HOURS[py_day] == expected, f"JS day {js_day}"


def test_services_match():
    body = block(source(), "export const SERVICES = [", "\n]")
    found = {sid: int(minutes) for sid, minutes in re.findall(r"id:\s*'([^']+)'.*?minutes:\s*(\d+)", body, re.S)}
    assert found, "No services found in the frontend config"
    assert found == {s.id: s.minutes for s in shop.SERVICES.values()}


def test_input_limits_match():
    """The booking form's character limits (and the 0/500 counter) must be the same numbers the API enforces."""
    from app.schemas import requests

    match = re.search(r"export const LIMITS = \{\s*name:\s*(\d+),\s*notes:\s*(\d+)\s*\}", source())
    assert match, "frontend/src/config.js has no LIMITS yet. Run update-vicbless-notes-counter.sh (from inside frontend/) first."
    assert (int(match.group(1)), int(match.group(2))) == (requests.NAME_MAX, requests.NOTES_MAX)


def test_contact_email_matches():
    """The email customers are told to write to is the same on the site and in the emails and error messages."""
    from app.core.brand import CONTACT_EMAIL

    match = re.search(r"email:\s*'([^']+)'", block(source(), "export const BUSINESS", "\n}"))
    assert match and match.group(1) == CONTACT_EMAIL
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
import io
import json
import urllib.error

import pytest

from app.emailing import EmailMessage, NullSender, get_sender, resend, templates
from app.services import notifications as notify
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_body, booking_model


def test_templates_escape_what_customers_type():
    evil = booking_model(name="<script>alert(1)</script>", notes="<img src=x onerror=alert(1)>", email='a"b@example.com')
    msg = templates.owner_notification(evil, "vic@example.com")
    assert "<script>" not in msg.html and "&lt;script&gt;" in msg.html
    assert "<img" not in msg.html
    assert 'href="mailto:a&quot;b@example.com"' in msg.html


def test_subject_has_no_line_breaks():
    msg = templates.owner_notification(booking_model(name="Bad\r\nBcc: x@evil.com"), "vic@example.com")
    assert "\n" not in msg.subject and "\r" not in msg.subject


def test_customer_confirmation_content():
    msg = templates.customer_confirmation(booking_model(), "vic@example.com")
    assert msg.to == "m@example.com" and msg.reply_to == "vic@example.com"
    assert "Tuesday, October 13 at 12:00 pm" in msg.text and "VB-ABC234" in msg.html and "Men's haircut" in msg.text


def test_owner_notification_replies_go_to_the_customer():
    msg = templates.owner_notification(booking_model(), "vic@example.com")
    assert msg.to == "vic@example.com" and msg.reply_to == "m@example.com"
    assert templates.owner_notification(booking_model(email=""), "vic@example.com").reply_to == ""


def all_emails():
    """One of every email the app can send, so a rule about emails is checked against all of them."""
    before, after = booking_model(), booking_model(start=12 * 60 + 35)
    return [
        templates.customer_confirmation(before, "vic@example.com"),
        templates.owner_notification(before, "vic@example.com"),
        templates.customer_cancellation(before, "vic@example.com"),
        templates.customer_rescheduled(before, after, "vic@example.com"),
    ]


def test_every_email_ends_with_the_shop_brand():
    """Vic asked for his brand at the end of the emails. Both the HTML and the plain-text version carry it."""
    for msg in all_emails():
        assert "VICBLESS BARBERSHOP" in msg.html and "VICBLESS BARBERSHOP" in msg.text
        assert "656 S Main St, Suite C" in msg.html and "Baxley, GA 31513" in msg.text
        assert 'href="mailto:vicslegacy89@gmail.com"' in msg.html
        # the brand is the last thing in the email, not buried in the middle
        assert msg.text.rstrip().endswith("vicslegacy89@gmail.com")
        assert msg.html.rstrip().endswith("</table></div>")


def test_emails_point_customers_to_the_contact_email_not_a_phone():
    for msg in all_emails():
        assert "call Vic" not in msg.text and "call Vic" not in msg.html and "tel:" not in msg.html
    assert "vicslegacy89@gmail.com and quote your code" in templates.customer_confirmation(booking_model(), "v@example.com").text


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return b'{"id":"1"}'


def message():
    return EmailMessage(to="c@example.com", subject="Hi", text="t", html="<p>t</p>", reply_to="vic@example.com")


def test_resend_request_shape(monkeypatch):
    seen = {}

    def fake(req, timeout):
        seen.update(
            url=req.full_url,
            method=req.get_method(),
            headers=dict(req.header_items()),
            body=json.loads(req.data),
            timeout=timeout,
        )
        return FakeResponse()

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    resend.ResendSender("re_key", "Vicbless <onboarding@resend.dev>").send(message())
    assert seen["url"] == "https://api.resend.com/emails" and seen["method"] == "POST"
    assert seen["headers"]["Authorization"] == "Bearer re_key" and seen["headers"]["User-agent"].startswith("vicbless")
    assert seen["body"] == {
        "from": "Vicbless <onboarding@resend.dev>",
        "to": ["c@example.com"],
        "subject": "Hi",
        "html": "<p>t</p>",
        "text": "t",
        "reply_to": ["vic@example.com"],
    }
    assert seen["timeout"] <= 10


def http_error(code):
    return urllib.error.HTTPError("u", code, "x", {"retry-after": "0"}, io.BytesIO(b"{}"))


def test_resend_retries_once_on_429(monkeypatch):
    calls = []

    def fake(req, timeout):
        calls.append(1)
        if len(calls) == 1:
            raise http_error(429)
        return FakeResponse()

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    monkeypatch.setattr(resend.time, "sleep", lambda s: None)
    resend.ResendSender("k", "f").send(message())
    assert len(calls) == 2


@pytest.mark.parametrize("failure", [http_error(403), http_error(500), urllib.error.URLError("down"), TimeoutError()])
def test_resend_failures_raise_our_error(monkeypatch, failure):
    def fake(req, timeout):
        raise failure

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    with pytest.raises(resend.EmailSendError):
        resend.ResendSender("k", "f").send(message())


def test_factory_without_config_is_null():
    assert isinstance(get_sender(), NullSender)


def test_factory_with_config_is_resend():
    put_param("resend-api-key", "re_key")
    put_param("email-from", "Vicbless <onboarding@resend.dev>", secure=False)
    assert isinstance(get_sender(), resend.ResendSender)


def test_unknown_provider_is_null(monkeypatch):
    monkeypatch.setenv("EMAIL_PROVIDER", "ses")
    assert isinstance(get_sender(), NullSender)


def test_failed_email_never_fails_the_booking(client, monkeypatch):
    class Broken:
        def send(self, m):
            raise RuntimeError("provider down")

    monkeypatch.setattr(notify, "get_sender", lambda: Broken())
    put_param("owner-email", "vic@example.com", secure=False)
    r = client.post("/api/bookings", json=booking_body(email="m@example.com"))
    assert r.status_code == 201


def test_owner_always_notified_customer_only_with_email(client, sent):
    client.post("/api/bookings", json=booking_body())
    assert [m.to for m in sent] == ["vic@example.com"]
    sent.clear()
    client.post("/api/bookings", json=booking_body(start=755, email="m@example.com", phone="5550102222", name="Other One"))
    assert sorted(m.to for m in sent) == ["m@example.com", "vic@example.com"]


def test_no_owner_email_configured_still_confirms_customer(client, monkeypatch):
    box = []

    class Recorder:
        def send(self, m):
            box.append(m)

    monkeypatch.setattr(notify, "get_sender", lambda: Recorder())
    client.post("/api/bookings", json=booking_body(email="m@example.com"))
    assert [m.to for m in box] == ["m@example.com"]
VICBLESS_EOF
cat > "$STAGE/6" <<'VICBLESS_EOF'
"""The words people read. Every error the site can show must be a plain sentence a customer or Vic understands."""

import pytest

from app.schemas import requests
from tests.helpers.api import book
from tests.helpers.constants import ADMIN_PASSWORD, TUESDAY

JARGON = ("Value error", "Input should", "validation error", "pydantic", "Traceback", "NoneType", "KeyError")


def message_of(response) -> str:
    return response.json()["error"]["message"]


def test_bad_email_says_what_a_good_one_looks_like(client):
    r = book(client, email="not-an-email")
    assert r.status_code == 422
    assert message_of(r) == "That email doesn't look right. Use something like name@example.com, or leave it blank."
    assert r.json()["error"]["field"] == "email"


@pytest.mark.parametrize(
    "over,expected",
    [
        ({"name": "A"}, "Please enter your name, between 2 and 50 characters."),
        ({"name": "x" * 51}, "Please enter your name, between 2 and 50 characters."),
        ({"phone": "12345"}, "Please enter a mobile number with at least 10 digits so Vic can reach you."),
        ({"notes": "x" * 501}, "Notes can be up to 500 characters. Please shorten yours a little."),
        ({"serviceId": "free-cut"}, "Please pick a service from the list."),
        ({"dateKey": "2026-02-31"}, "That date isn't valid. Please pick a day from the calendar."),
        ({"start": 5000}, "Please pick a time from the list."),
    ],
)
def test_field_messages_are_friendly(client, over, expected):
    r = book(client, **over)
    assert r.status_code == 422 and message_of(r) == expected


@pytest.mark.parametrize("over", [{"start": "noon"}, {"start": True}, {"serviceId": 5}, {"phone": None}])
def test_even_type_mistakes_have_no_programmer_wording(client, over):
    r = book(client, **over)
    assert r.status_code == 422
    assert not any(word.lower() in message_of(r).lower() for word in JARGON)
    assert message_of(r) == "Some of the details aren't valid. Please check them and try again."


def test_missing_body_has_no_jargon(client):
    r = client.post("/api/bookings", json={})
    assert r.status_code == 422 and not any(w.lower() in message_of(r).lower() for w in JARGON)


def test_wrong_password_message(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": "nope"})
    assert r.status_code == 401
    assert message_of(r) == "That password isn't right. Check it and try again."


def test_empty_password_message(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": ""})
    assert r.status_code == 422 and message_of(r) == "Please enter your password."


def test_lockout_message_says_how_long(client, admin_setup):
    for _ in range(5):
        client.post("/api/admin/login", json={"password": "bad"})
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 429 and message_of(r) == "Too many tries. Please wait about 15 minutes, then try again."


def test_sign_in_not_set_up_message(client):
    r = client.post("/api/admin/login", json={"password": "x"})
    assert r.status_code == 503 and message_of(r) == "Sign-in isn't set up yet."


def test_signed_out_and_expired_messages(client, admin_setup):
    r = client.get(f"/api/admin/schedule?date={TUESDAY}")
    assert r.status_code == 401 and message_of(r) == "Please sign in to continue."
    r = client.get(f"/api/admin/schedule?date={TUESDAY}", headers={"Authorization": "Bearer garbage"})
    assert message_of(r) == "Your session ended. Please sign in again."


def test_phone_cap_message_mentions_the_limit(client):
    plan = [("2026-10-13", 12 * 60), ("2026-10-15", 11 * 60), ("2026-10-16", 11 * 60)]
    for day, start in plan:
        book(client, dateKey=day, start=start)
    r = book(client, dateKey="2026-10-20", start=12 * 60)
    assert r.status_code == 429 and "3 upcoming bookings" in message_of(r) and "email Vic at vicslegacy89@gmail.com" in message_of(r)


def test_slot_taken_message(client):
    book(client)
    r = book(client, name="Someone Else", phone="5550109999")
    assert message_of(r) == "Sorry, that time was just taken. Please pick another."


def test_name_limit_boundaries(client):
    assert book(client, name="x" * 50).status_code == 201
    assert requests.NAME_MAX == 50 and requests.NAME_MIN == 2


def test_notes_limit_boundaries(client):
    assert book(client, notes="n" * 500).status_code == 201
    assert book(client, start=755, phone="5550102222", notes="n" * 501).status_code == 422


def test_windows_line_breaks_count_once_like_the_browser(client, auth):
    # The browser counts "\r\n" in a textarea as ONE character. This note is exactly 500 to the browser
    # (250 letters + 249 line breaks + 1 more letter). If the API counted \r\n as two it would wrongly refuse it.
    notes = ("a\r\n" * 250)[:-2] + "b"
    assert len(notes) > 500  # 750 raw characters
    assert book(client, notes=notes).status_code == 201
    stored = client.get(f"/api/admin/schedule?date={TUESDAY}", headers=auth).json()["items"][0]["notes"]
    assert "\r" not in stored and len(stored) == 500
    # and one more character is over the limit, as it is for the browser
    assert book(client, start=755, phone="5550102222", notes=notes + "c").status_code == 422


def test_every_error_message_in_the_code_is_a_plain_sentence():
    """No message may end without punctuation, shout, or use words only programmers say."""
    import inspect

    from app.core import errors

    for _, cls in inspect.getmembers(errors, inspect.isclass):
        message = getattr(cls, "default_message", "")
        assert message.endswith((".", "!", "?")), f"{cls.__name__}: {message!r}"
        assert not any(word.lower() in message.lower() for word in JARGON), cls.__name__
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#0A0612" />
    <script>
      // Applies the saved theme and motion choice before the page paints, so there is no flash.
      // Keep in step with src/lib/settings.js.
      try {
        var saved = JSON.parse(localStorage.getItem('vicbless.settings') || '{}')
        var root = document.documentElement
        var osReduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
        root.dataset.theme = saved.theme === 'light' ? 'light' : 'dark'
        root.dataset.motion = saved.motion === 'on' || saved.motion === 'off' ? saved.motion : osReduce ? 'off' : 'on'
      } catch (e) {}
    </script>
    <title>Vicbless Barbershop | Barber in Baxley, GA</title>
    <meta name="description" content="Vicbless Barbershop in Baxley, GA. Men's haircuts, designs, beard and eyebrow work, and kids cuts. Book your time online." />
    <link rel="canonical" href="https://vicbless.com/" />
    <meta name="robots" content="index, follow, max-image-preview:large" />
    <!-- Icons. The .ico is for old browsers, the .svg for modern ones, the apple one for iPhone home screens. -->
    <link rel="icon" href="/favicon.ico" sizes="48x48" />
    <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
    <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
    <link rel="manifest" href="/site.webmanifest" />
    <!-- Link previews (iMessage, Instagram, Facebook, X, Slack, WhatsApp). The image address has to be absolute. -->
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Vicbless Barbershop" />
    <meta property="og:title" content="Vicbless Barbershop" />
    <meta property="og:description" content="Book a haircut online. Baxley, GA." />
    <meta property="og:url" content="https://vicbless.com/" />
    <meta property="og:image" content="https://vicbless.com/og-image.png" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content="Vicbless Barbershop, Baxley, GA" />
    <meta name="twitter:card" content="summary_large_image" />

    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,100..900&display=swap" rel="stylesheet" />
    <!-- What Google reads to understand the business (name, address, hours). src/lib/seo.test.js checks it against config.js. -->
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "BarberShop",
        "name": "Vicbless Barbershop",
        "url": "https://vicbless.com/",
        "image": "https://vicbless.com/og-image.png",
        "logo": "https://vicbless.com/icon-512.png",
        "description": "Barbershop in Baxley, GA. Men's haircuts, designs, beard and eyebrow work, and kids cuts. Book online.",
        "address": {
          "@type": "PostalAddress",
          "streetAddress": "656 S Main St, Suite C",
          "addressLocality": "Baxley",
          "addressRegion": "GA",
          "postalCode": "31513",
          "addressCountry": "US"
        },
        "openingHoursSpecification": [
          { "@type": "OpeningHoursSpecification", "dayOfWeek": ["Monday", "Tuesday"], "opens": "12:00", "closes": "18:00" },
          { "@type": "OpeningHoursSpecification", "dayOfWeek": ["Thursday", "Friday"], "opens": "11:00", "closes": "19:00" },
          { "@type": "OpeningHoursSpecification", "dayOfWeek": "Saturday", "opens": "09:00", "closes": "12:00" },
          { "@type": "OpeningHoursSpecification", "dayOfWeek": "Saturday", "opens": "12:35", "closes": "17:00" }
        ],
        "email": "vicslegacy89@gmail.com",
        "sameAs": ["https://www.tiktok.com/@vicblesss", "https://www.instagram.com/vicblessss"]
      }
    </script>
  </head>
  <body>
    <div id="root"></div>
    <noscript>
      <h1>Vicbless Barbershop, Baxley, GA</h1>
      <p>Men's haircuts, designs, beard and eyebrow work, and kids cuts. 656 S Main St, Suite C, Baxley, GA 31513.</p>
      <p>Booking needs JavaScript. Turn it on to book a time online.</p>
    </noscript>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
import { BUSINESS } from '../config.js'
import { mailtoHref } from '../lib/format.js'

// The shop's contact email as a tap-to-write link. Use this anywhere customers are told how to reach Vic,
// so the address only ever has to be changed in config.js. (It keeps the "phone-link" style name so it looks
// like the other links on the site.)
export default function EmailLink() {
  return (
    <a className="phone-link" href={mailtoHref(BUSINESS.email)}>
      {BUSINESS.email}
    </a>
  )
}
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
import EmailLink from './EmailLink.jsx'
import Reveal from './Reveal.jsx'
import { BUSINESS, CTA_TEXT, HOURS, SERVICES } from '../config.js'
import { fmtTime } from '../lib/availability.js'
import { priceLabel } from '../lib/format.js'

// Monday first, the way people read a week.
const DAYS = [
  [1, 'Monday'],
  [2, 'Tuesday'],
  [3, 'Wednesday'],
  [4, 'Thursday'],
  [5, 'Friday'],
  [6, 'Saturday'],
  [0, 'Sunday'],
]

export default function ShopInfo() {
  return (
    <section className="info" aria-label="Services and hours">
      <div className="info-grid">
        <div>
          <Reveal as="h2">Services</Reveal>
          <ul className="menu">
            {SERVICES.map((s, i) => (
              <Reveal as="li" key={s.id} delay={i * 80}>
                <div className="menu-row">
                  <span className="menu-name">{s.name}</span>
                  <span className="menu-leader" />
                  <span className="menu-price">{priceLabel(s)}</span>
                </div>
                <p className="menu-meta">
                  {s.minutes} min{s.note ? `. ${s.note}` : ''}
                </p>
                <a className="svc-cta" href={`#/book?service=${s.id}`}>
                  {CTA_TEXT}
                </a>
              </Reveal>
            ))}
          </ul>
        </div>

        <div>
          <Reveal as="h2">Hours</Reveal>
          <Reveal as="ul" className="hours" delay={80}>
            {DAYS.map(([i, name]) => {
              const windows = HOURS[i]
              return (
                <li key={i}>
                  <span>{name}</span>
                  <span className={windows ? '' : 'closed'}>
                    {windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'}
                  </span>
                </li>
              )
            })}
          </Reveal>

          <Reveal as="h2">Vic's Shop Location</Reveal>
          <Reveal as="address" delay={80}>
            {BUSINESS.address.map((line) => (
              <span key={line}>
                {line}
                <br />
              </span>
            ))}
            <EmailLink />
          </Reveal>
        </div>
      </div>

      <Reveal className="info-cta">
        <a className="btn btn-primary" href="#/book">
          {CTA_TEXT}
        </a>
      </Reveal>
    </section>
  )
}
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
// Everything business-specific lives here.
// Hours, services, address and social links are Vic's real ones. The phone number is still a PLACEHOLDER.

export const BUSINESS = {
  name: 'Vicbless Barbershop',
  // How customers reach Vic. The site shows this email wherever it used to show the phone number.
  email: 'vicslegacy89@gmail.com',
  phone: '(555) 010-0123', // PLACEHOLDER, not shown anywhere on the site right now
  address: ['656 S Main St, Suite C', 'Baxley, GA 31513'],
}

export const SOCIAL = {
  tiktok: 'https://www.tiktok.com/@vicblesss',
  instagram: 'https://www.instagram.com/vicblessss',
}

// Vic is the only staff for now. Add more entries later and the booking
// payload already carries a staffId, so the data model will not change.
export const STAFF = [{ id: 'vic', name: 'Vic' }]

// Opening windows per weekday, in minutes after midnight. 0 = Sunday.
// null = closed. A day can have several windows (Saturday has a break).
const at = (h, m = 0) => h * 60 + m

export const HOURS = {
  0: null, // Sunday: closed
  1: [[at(12), at(18)]], // Monday 12:00 pm to 6:00 pm
  2: [[at(12), at(18)]], // Tuesday 12:00 pm to 6:00 pm
  3: null, // Wednesday: closed
  4: [[at(11), at(19)]], // Thursday 11:00 am to 7:00 pm
  5: [[at(11), at(19)]], // Friday 11:00 am to 7:00 pm
  6: [
    [at(9), at(12)], // Saturday 9:00 am to 12:00 pm
    [at(12, 35), at(17)], // and 12:35 pm to 5:00 pm
  ],
}

// price is the starting price. from: true shows it as "$65+".
export const SERVICES = [
  { id: 'mens-cut', name: "Men's haircut", minutes: 35, price: 55 },
  {
    id: 'mens-design',
    name: "Men's haircut with design",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Small or freestyle design',
  },
  {
    id: 'mens-beard-eyebrow',
    name: "Men's haircut with beard and eyebrow",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Includes free hot towel if requested and hair styling',
  },
  {
    id: 'buzz-beard',
    name: 'Head buzzed/shave and beard',
    minutes: 30,
    price: 40,
    note: 'Same price for just beards. Tell Vic in person if you want it buzzed or shaved.',
  },
  {
    id: 'kids-design',
    name: 'Kids cut (12 and under) with design',
    minutes: 30,
    price: 40,
    from: true,
    note: '$5 extra for a small design, $10 more for a bigger design',
  },
]

// Vic books in 35 minute blocks (Saturday's 12:35 restart follows the same rhythm).
// Every service fits in one block, longer ones would take several.
export const SLOT_MINUTES = 35
export const DAYS_AHEAD = 14

// The branded call to action. Used on every booking button.
export const CTA_TEXT = 'Book here to get blessed'

// The photo section under the video: headline, paragraph, and the words stacked over the photo.
export const STATEMENT = {
  headline: "EVERY CUT ISN'T JUST A CUT. IT'S A BLESSING.",
  body: 'Consistent precision cuts with clean detail and a personalized cut experience to give you confidence and blessings.',
  words: ['Quality', 'Detail', 'Consistency', 'Baxley, GA'],
}

// Call to action in the middle of the photo section (exact wording from Vic).
export const STATEMENT_CTA = 'Book Here to get blessed'

// Small credit in the footer.
export const CREDIT = { text: 'Website By RaynerCodes Cloud Solutions', url: 'https://raynercodes.dev' }

// Big headline on the screen shown after a booking is confirmed (exact wording from Vic).
// Two lines; the second one is shown in the purple accent colour.
export const SUCCESS_HEADLINE = ['If you wanna get fresh..', 'Come to Vicbless']

// Words shown at the top of the home page video, right under the logo. A TEST for Vic.
// One entry per line. The last line is shown in the purple accent colour.
// To hide it, change the list to just an empty pair of brackets.
export const HOME_TAGLINE = ['If you wanna get fresh,', 'come to VicBless']

// The most a customer may type. The booking form enforces these and shows the notes counter; the API
// enforces the same numbers, and a backend test fails if the two ever differ.
export const LIMITS = { name: 50, notes: 500 }

// Which comes first on the home page, a TEST for Vic (change this one word to compare the two looks):
//   'photo-first'  the photo section (headline, paragraph, stacked words) is the first thing under the logo, then the video
//   'video-first'  the video first, then the photo section (how it was)
export const HOME_ORDER = 'photo-first'
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
// Keeps the search-engine data in index.html honest: the structured data Google reads about the shop must say the
// same thing as config.js (address, hours, social links), so changing one without the other fails here.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { BUSINESS, HOURS, SOCIAL } from '../config.js'

const html = readFileSync(new URL('../../index.html', import.meta.url), 'utf8')
const jsonLd = () => {
  const match = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)
  expect(match, 'index.html has no application/ld+json block').toBeTruthy()
  return JSON.parse(match[1])
}

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const hhmm = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`

describe('structured data (JSON-LD)', () => {
  it('describes a barber shop with the name and the address from config.js', () => {
    const data = jsonLd()
    expect(data['@type']).toBe('BarberShop')
    expect(data.name).toBe(BUSINESS.name)
    const [street, cityLine] = BUSINESS.address
    const [city, rest] = cityLine.split(', ')
    const [region, zip] = rest.split(' ')
    expect(data.address).toMatchObject({ '@type': 'PostalAddress', streetAddress: street, addressLocality: city, addressRegion: region, postalCode: zip, addressCountry: 'US' })
  })

  it('lists exactly the opening hours in config.js', () => {
    const expected = []
    for (const [day, windows] of Object.entries(HOURS)) {
      for (const [open, close] of windows || []) expected.push(`${DAY_NAMES[day]} ${hhmm(open)}-${hhmm(close)}`)
    }
    const listed = []
    for (const spec of jsonLd().openingHoursSpecification) {
      for (const day of [].concat(spec.dayOfWeek)) listed.push(`${day} ${spec.opens}-${spec.closes}`)
    }
    expect(listed.sort()).toEqual(expected.sort())
  })

  it('links the social profiles from config.js', () => {
    expect([...jsonLd().sameAs].sort()).toEqual(Object.values(SOCIAL).sort())
  })

  it('lists the contact email from config.js', () => {
    expect(jsonLd().email).toBe(BUSINESS.email)
  })

  it('does not publish the placeholder phone number', () => {
    // BUSINESS.phone is still a placeholder. Add "telephone" to the JSON-LD only once it is Vic's real number.
    if (/PLACEHOLDER|\(555\)/.test(BUSINESS.phone)) expect(jsonLd()).not.toHaveProperty('telephone')
  })
})

describe('page head', () => {
  it('has one title, a description, a canonical address, and allows indexing', () => {
    expect(html.match(/<title>/g)).toHaveLength(1)
    expect(html).toMatch(/<meta name="description" content="[^"]{50,170}"/)
    expect(html).toContain('<link rel="canonical" href="https://vicbless.com/" />')
    expect(html).toMatch(/<meta name="robots" content="index, follow/)
  })
})
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, SERVICES, SLOT_MINUTES, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'

const STEPS = ['Service', 'Time', 'Details']
const REFRESH_MS = 30000 // how often the time grid re-checks while it is open
const payLine = (s) =>
  s.from
    ? `Pay at the shop. Starts at $${s.price}, the final price depends on what you get.`
    : `Pay at the shop. $${s.price} total.`

function buildDays() {
  const start = new Date()
  start.setHours(0, 0, 0, 0)
  return Array.from({ length: DAYS_AHEAD }, (_, i) => {
    const d = new Date(start)
    d.setDate(start.getDate() + i)
    return d
  })
}

function dayLabel(d) {
  const today = new Date()
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

  // For each day: the taken times, and whether the whole day is off.
  const [availability, setAvailability] = useState(null)
  const busy = useMemo(
    () => availability && Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy])),
    [availability],
  )
  const [loadError, setLoadError] = useState(false)
  // A service link on the home page (#/book?service=mens-design) arrives with the service chosen.
  const [preselected] = useState(() => serviceIdFromHash(window.location.hash, SERVICES))
  const [step, setStep] = useState(preselected ? 1 : 0)
  const [serviceId, setServiceId] = useState(preselected)
  const [dateKey, setDateKey] = useState(null)
  const [time, setTime] = useState(null)
  const [form, setForm] = useState({ name: '', phone: '', email: '', notes: '' })
  const [errors, setErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [notice, setNotice] = useState('')
  const [done, setDone] = useState(null)

  const service = SERVICES.find((s) => s.id === serviceId) || null

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
    const now = new Date()
    const out = {}
    for (const d of days) {
      const k = keyOf(d)
      out[k] = slotsForDay({
        date: d,
        minutes: service.minutes,
        hours: HOURS,
        busy: busy[k] || [],
        now,
        slotMinutes: SLOT_MINUTES,
      })
    }
    return out
  }, [busy, service, days])

  // Preselect the first day that has openings when the time step opens.
  useEffect(() => {
    if (step !== 1 || dateKey) return
    const first = days.find((d) => (slotsByDay[keyOf(d)] || []).length > 0)
    if (first) setDateKey(keyOf(first))
  }, [step, dateKey, slotsByDay, days])

  // If the time you picked gets taken while the page is open, say so and let you pick again.
  useEffect(() => {
    if (time === null || !dateKey || !busy) return
    if (!(slotsByDay[dateKey] || []).includes(time)) {
      setTime(null)
      setNotice('That time was just taken. Pick another time.')
    }
  }, [slotsByDay])

  const reach = !service ? 0 : time === null ? 1 : 2

  function chooseService(id) {
    if (id !== serviceId) setTime(null)
    setServiceId(id)
    setStep(1)
  }

  function updateField(e) {
    setForm((f) => ({ ...f, [e.target.name]: e.target.value }))
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
        minutes: service.minutes,
        name: form.name.trim(),
        phone: form.phone.trim(),
        email: form.email.trim(),
        notes: form.notes.trim(),
      })
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
    } finally {
      setSubmitting(false)
    }
  }

  if (done) {
    const booked = SERVICES.find((s) => s.id === done.serviceId)
    return (
      <main className="book book-done">
        <section className="done" aria-live="polite">
          <Reveal as="h1" from="above" className="done-headline">
            <span>{SUCCESS_HEADLINE[0]}</span> <span className="done-line-2">{SUCCESS_HEADLINE[1]}</span>
          </Reveal>
          <h2 className="book-title done-booked">You're booked, {done.name.split(' ')[0]}.</h2>
          <p className="code" aria-label="Confirmation code">{done.code}</p>
          <p>
            <strong>{booked.name}</strong> with {staff.name}
          </p>
          <p>
            {dayLabel(fromKey(done.dateKey))} at {fmtTime(done.start)}
          </p>
          <p>{payLine(booked)}</p>
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
      ? startsForDay({ date: selectedDay, minutes: service.minutes, hours: HOURS, slotMinutes: SLOT_MINUTES })
      : []

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
              className="opt"
              aria-pressed={serviceId === s.id}
              onClick={() => chooseService(s.id)}
            >
              <span className="name">{s.name}</span>
              <span className="meta">{s.minutes} min</span>
              <span className="leader" />
              <span className="price">{priceLabel(s)}</span>
              {s.note && <span className="note">{s.note}</span>}
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
                  const closed = !HOURS[d.getDay()] || !!availability[k]?.dayOff // shop closed that weekday, or Vic took the day off
                  const free = (slotsByDay[k] || []).length
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
                      <span className="tag">{closed ? 'Closed' : free ? '' : 'Full'}</span>
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
                          className="time"
                          aria-pressed={time === m}
                          disabled={!open}
                          onClick={() => {
                            setTime(m)
                            setNotice('')
                          }}
                        >
                          {fmtTime(m)}
                          {!open && <span className="sr-only"> (unavailable)</span>}
                        </button>
                      )
                    })}
                  </div>
                  {daySlots.length < dayStarts.length && <p className="times-note">Greyed-out times are not available.</p>}
                </>
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
                {service.name} ({service.minutes} min), {priceLabel(service)}
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
            <p className="muted">Pay at the shop. No card needed to book.</p>
            <div className="actions">
              <button type="button" className="btn" onClick={() => setStep(1)}>
                Back
              </button>
              <button type="submit" className="btn btn-primary" disabled={submitting}>
                {submitting ? 'Confirming…' : 'Confirm booking'}
              </button>
            </div>
          </form>
        </section>
      )}
    </main>
  )
}
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
/* Vicbless: dark purple-black ground, light lavender ink, small purple accents. */
:root {
  --bg: #0a0612;
  --surface: #130c21;
  --ink: #f6efff;
  --muted: #b3a5c9;
  --line: #2f2347;
  --purple: #a855f7;
  --accent: #c084fc;
  --on-accent: #0a0612;
  --danger: #ff8aa0;
  --header-bg: rgba(10, 6, 18, 0.92);
  /* Text and accent that sit on top of photos and video. Always light, in either theme. */
  --on-media: #f6efff;
  --accent-media: #c084fc;
  --font: 'Archivo', 'Arial Narrow', system-ui, -apple-system, 'Segoe UI', sans-serif;
  color-scheme: dark;
}

/* Light theme. Switched with the Dark mode setting (see src/lib/settings.js). */
html[data-theme='light'] {
  --bg: #f8f4fd;
  --surface: #ffffff;
  --ink: #1b1030;
  --muted: #5a4a73;
  --line: #ddd0ee;
  --purple: #7e22ce;
  --accent: #7c3aed;
  --on-accent: #ffffff;
  --danger: #b3123b;
  --header-bg: rgba(248, 244, 253, 0.92);
  color-scheme: light;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font);
  font-size: 1rem;
  line-height: 1.5;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

button,
input,
textarea {
  font: inherit;
  color: inherit;
}

button {
  cursor: pointer;
}

:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- Home: pinned logo bar, video hero, shop info, footer ---------- */
:root {
  --brand-h: calc(84px + env(safe-area-inset-top, 0px));
}

/* Logo bar. Sticky, so it follows the page while scrolling. The logo sits in the
   middle column and the social links on the right. */
.brand {
  position: sticky;
  top: 0;
  z-index: 10;
  height: var(--brand-h);
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  padding: env(safe-area-inset-top, 0px) 16px 0;
  background: var(--header-bg);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}

.logo {
  margin: 0;
  width: min(100%, 880px);
}

.brand .logo {
  grid-column: 2;
  width: auto;
  height: 60px;
}

.logo svg {
  display: block;
  width: 100%;
  height: auto;
  filter: drop-shadow(0 0 3px var(--purple));
}

.brand .logo svg {
  width: auto;
  height: 100%;
}

.logo-link {
  display: block;
  height: 100%;
  color: inherit;
  border-radius: 6px;
}

.logo path {
  fill: var(--ink);
  stroke: var(--purple);
  stroke-width: 6;
  stroke-linejoin: round;
  paint-order: stroke;
}

.brand .socials {
  grid-column: 3;
  justify-self: end;
}

.socials {
  display: flex;
  align-items: center;
  gap: 2px;
}

.social {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  color: var(--ink);
  border-radius: 50%;
}

.social:hover {
  color: var(--accent);
}

/* The hero fills whatever is left of the first screen under the pinned bar. */
.hero {
  position: relative;
  height: calc(100vh - var(--brand-h));
  height: calc(100svh - var(--brand-h));
  min-height: 440px;
  overflow: hidden;
  background: var(--bg);
}

/* Blurred, dimmed poster fills the sides when the screen is wider than the video. */
.hero-backdrop {
  position: absolute;
  top: -48px;
  left: -48px;
  width: calc(100% + 96px);
  height: calc(100% + 96px);
  object-fit: cover;
  filter: blur(36px) brightness(0.5) saturate(1.2);
}

.hero-video {
  position: absolute;
  top: 0;
  left: 50%;
  /* Much taller than the window (165%): --pan (0 to 1, set while scrolling) slides the
     footage up through the extra 65% (that is 39.4% of the video's own height), so the
     view travels from the top of the video to the bottom. */
  transform: translate3d(-50%, calc(var(--pan, 0) * -39.4%), 0);
  will-change: transform;
  height: 165%;
  width: auto;
  max-width: 100%;
  aspect-ratio: 720 / 1084;
  object-fit: cover;
  background: var(--surface);
}

/* Soft shade behind the button so it reads over any frame of the video. */
.hero::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse 60% 40% at 50% 50%, rgba(10, 6, 18, 0.55), rgba(10, 6, 18, 0) 70%);
}

/* Words at the top of the video, right under the logo. A dark fade behind them keeps them readable
   on any frame. They use fixed light colours (like the other text on the video), so they look the
   same in dark and light mode, and they slide down into place when the page opens. */
.hero-tagline {
  position: absolute;
  top: 0;
  right: 0;
  left: 0;
  z-index: 1;
  margin: 0;
  padding: 18px 16px 48px;
  font-size: clamp(1.5rem, 6.2vw, 2.7rem);
  font-weight: 900;
  line-height: 1;
  letter-spacing: -0.01em;
  text-align: center;
  font-variation-settings: 'wdth' 70;
  color: var(--on-media);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.55);
  background: linear-gradient(to bottom, rgba(10, 6, 18, 0.72), rgba(10, 6, 18, 0));
  pointer-events: none;
}

.hero-tagline span {
  display: block;
  animation: tagline-in 0.8s cubic-bezier(0.2, 0.7, 0.2, 1) both;
  animation-delay: calc(0.3s + var(--i, 0) * 0.16s);
}

.hero-tagline .hero-tagline-accent {
  color: var(--accent-media);
}

@keyframes tagline-in {
  from {
    opacity: 0;
    transform: translateY(-22px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

.hero-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  pointer-events: none;
}

.hero .book-now {
  pointer-events: auto;
  max-width: min(88vw, 460px);
  padding: 20px 44px;
  font-size: clamp(1.15rem, 4.6vw, 1.5rem);
  line-height: 1.15;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  animation: ring 2.8s ease-out infinite;
}

@keyframes ring {
  0% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  }
  70%,
  100% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 22px rgba(192, 132, 252, 0);
  }
}

.hero-toggle {
  position: absolute;
  right: 14px;
  bottom: 14px;
  z-index: 2;
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--on-media);
  background: rgba(10, 6, 18, 0.6);
  border: 2px solid rgba(246, 239, 255, 0.7);
  border-radius: 50%;
}

.hero-toggle:hover {
  border-color: var(--on-media);
}

.info {
  max-width: 960px;
  margin: 0 auto;
  padding: 72px 20px 48px;
}

.info-grid {
  display: grid;
  grid-template-columns: 1.2fr 1fr;
  gap: 48px;
}

.info h2 {
  margin: 0 0 14px;
  font-size: 1.5rem;
  font-weight: 800;
  font-variation-settings: 'wdth' 85;
}

.menu,
.hours {
  margin: 0 0 32px;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.menu li {
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
}

.menu-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.menu-name {
  font-weight: 700;
}

.menu-leader {
  flex: 1;
  min-width: 12px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.menu-price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.menu-meta {
  margin: 2px 0 0;
  font-size: 0.9rem;
  color: var(--muted);
}

.hours li {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
}

.hours li span:last-child {
  text-align: right;
}

.hours .closed {
  color: var(--muted);
}

.info address {
  font-style: normal;
  color: var(--muted);
}

/* Contact links (the shop's email). A long address may break onto a second line on a narrow phone instead of running off the side. */
.phone-link {
  overflow-wrap: anywhere;
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.phone-link:hover {
  text-decoration-thickness: 2px;
}

.info address .phone-link {
  display: inline-block;
  padding: 8px 0;
}

.notice .phone-link {
  color: inherit;
}

.info-cta {
  display: flex;
  justify-content: center;
  margin-top: 40px;
}

.site-foot {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 32px 20px calc(36px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.9rem;
}

.site-foot .copy {
  margin: 0;
  font-weight: 700;
  letter-spacing: 0.04em;
}

/* Quiet credit: small, muted, faint underline. Still readable, just out of the way. */
.site-foot .credit {
  margin: 4px 0 0;
  font-size: 0.74rem;
}

.site-foot .credit a {
  display: inline-block;
  padding: 6px 4px;
  color: var(--muted);
  text-decoration: underline;
  text-decoration-color: var(--line);
  text-underline-offset: 3px;
}

.site-foot .credit a:hover {
  color: var(--ink);
  text-decoration-color: currentColor;
}

/* Social links along the bottom of the video. */
.hero-socials {
  position: absolute;
  left: 50%;
  bottom: 14px;
  z-index: 2;
  transform: translateX(-50%);
}

.hero-socials .socials {
  padding: 2px 8px;
  background: rgba(10, 6, 18, 0.6);
  border: 1px solid rgba(246, 239, 255, 0.25);
  border-radius: 999px;
}

.hero-socials .social {
  color: var(--on-media);
}

.hero-socials .social:hover {
  color: var(--accent-media);
}

/* Scroll reveal: content below the video fades up as it enters the screen. */
.reveal {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0.7, 0.2, 1);
  transition-delay: var(--d, 0ms);
}

.reveal.in {
  opacity: 1;
  transform: none;
}

/* Branded CTA on each haircut type: a purple box, matching the other booking buttons. */
.svc-cta {
  display: inline-block;
  margin-top: 12px;
  padding: 12px 24px;
  font-weight: 800;
  text-align: center;
  color: var(--on-accent);
  text-decoration: none;
  background: var(--accent);
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.svc-cta:hover {
  filter: brightness(1.08);
}

/* Menu: three-line button on the left of the pinned bar, opens a panel under it. */
.brand .site-menu {
  grid-column: 1;
  justify-self: start;
}

.menu-toggle {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--ink);
  background: none;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.menu-toggle:hover {
  border-color: var(--accent);
}

/* The bar is the positioned parent, so the panel hangs just under it. */
.menu-panel {
  position: absolute;
  top: calc(100% + 6px);
  left: 12px;
  z-index: 20;
  width: min(330px, calc(100vw - 24px));
  max-height: calc(100vh - var(--brand-h) - 24px);
  max-height: calc(100svh - var(--brand-h) - 24px);
  padding: 8px;
  overflow-y: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.45);
}

.menu-group + .menu-group {
  margin-top: 4px;
}

.menu-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  font-size: 1.05rem;
  font-weight: 800;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.menu-head:hover {
  background: var(--bg);
}

.menu-head .chev {
  transition: transform 0.2s ease;
}

.menu-head[aria-expanded='true'] .chev {
  transform: rotate(180deg);
}

.menu-sub {
  padding: 2px 4px 8px;
}

.menu-link {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 48px;
  padding: 10px 12px;
  font-weight: 600;
  color: var(--ink);
  text-decoration: none;
  border-radius: 8px;
}

.menu-link:hover {
  color: var(--accent);
  background: var(--bg);
}

.setting {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  min-height: 56px;
  padding: 8px 12px;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.setting:hover {
  background: var(--bg);
}

.setting-text {
  display: flex;
  flex: 1;
  flex-direction: column;
}

.setting-label {
  font-weight: 700;
}

.setting-hint {
  font-size: 0.82rem;
  color: var(--muted);
}

.switch-state {
  min-width: 2em;
  font-size: 0.9rem;
  font-weight: 700;
  text-align: right;
  color: var(--muted);
}

.switch-track {
  position: relative;
  flex: none;
  width: 46px;
  height: 26px;
  background: var(--line);
  border: 2px solid var(--line);
  border-radius: 999px;
  transition: background 0.2s ease, border-color 0.2s ease;
}

.switch-track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 18px;
  height: 18px;
  background: var(--ink);
  border-radius: 50%;
  transition: transform 0.2s ease;
}

.setting[aria-checked='true'] .switch-track {
  background: var(--accent);
  border-color: var(--accent);
}

.setting[aria-checked='true'] .switch-track::after {
  background: var(--on-accent);
  transform: translateX(20px);
}

/* Extra rows at the bottom of the menu (the dashboard's View site and Sign out). */
.menu-extra {
  margin-top: 4px;
  padding-top: 4px;
  border-top: 1px solid var(--line);
}

button.menu-link {
  width: 100%;
  text-align: left;
  background: none;
  border: 0;
}

/* Words that drop down into place instead of lifting up. */
.reveal-down {
  transform: translateY(-28px);
}

/* Photo section under the video. The photo is 130% of the section's height and slides
   through it with --pan (see Statement.jsx), so it has its own parallax. The headline sits
   at the top and the stacked words at the bottom, which keeps the faces clear in the middle. */
.statement {
  position: relative;
  color: var(--on-media);
  display: flex;
  min-height: 780px;
  min-height: max(780px, 100svh);
  padding: 56px 20px 48px;
  overflow: hidden;
  background: var(--bg);
}

.statement-img {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 130%;
  object-fit: cover;
  object-position: 20% 50%;
  transform: translate3d(0, calc(var(--pan, 0.5) * -23.1%), 0);
  will-change: transform;
}

/* Darkens the top and bottom where the text sits, leaves the middle (the faces) clear. */
.statement::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(
    to bottom,
    rgba(10, 6, 18, 0.78) 0%,
    rgba(10, 6, 18, 0.35) 28%,
    rgba(10, 6, 18, 0) 45%,
    rgba(10, 6, 18, 0) 55%,
    rgba(10, 6, 18, 0.55) 72%,
    rgba(10, 6, 18, 0.9) 100%
  );
}

.statement-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 32px;
  width: 100%;
  max-width: 1100px;
  margin: 0 auto;
}

.statement h2 {
  max-width: 18ch;
  margin: 0 0 14px;
  font-size: clamp(1.5rem, 5.2vw, 2.6rem);
  font-weight: 900;
  line-height: 1.08;
  letter-spacing: 0.01em;
  font-variation-settings: 'wdth' 85;
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.6);
}

.statement p {
  max-width: 44ch;
  margin: 0;
  font-size: clamp(1rem, 2.6vw, 1.2rem);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.7);
}

.statement-words {
  margin: 0;
  padding: 0;
  list-style: none;
}

.statement-words li {
  font-size: clamp(2.7rem, 13vw, 6.8rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-shadow: 0 4px 24px rgba(0, 0, 0, 0.55);
}

.statement-words .statement-place {
  color: var(--accent-media);
}

/* Centred call to action over the photo: a see-through box with a light outline.
   Fixed light colours, so it reads the same in dark and light mode. */
.statement-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  padding: 0 20px;
  pointer-events: none;
}

.statement-cta-link {
  display: block;
  max-width: min(86vw, 440px);
  padding: 18px 36px;
  font-size: clamp(1.1rem, 4.6vw, 1.4rem);
  font-weight: 800;
  line-height: 1.15;
  text-align: center;
  color: var(--on-media);
  text-decoration: none;
  background: rgba(10, 6, 18, 0.28);
  border: 2px solid rgba(246, 239, 255, 0.85);
  border-radius: 14px;
  -webkit-backdrop-filter: blur(3px);
  backdrop-filter: blur(3px);
  pointer-events: auto;
  transition: background 0.2s ease, color 0.2s ease, border-color 0.2s ease;
}

.statement-cta-link:hover {
  color: #0a0612;
  background: var(--accent-media);
  border-color: var(--accent-media);
}

@media (min-width: 900px) {
  /* Taller section and slightly smaller words on wide screens, so the centred button always
     has a free band to sit in between the paragraph above and the words below. */
  .statement {
    min-height: max(840px, 92svh);
  }

  .statement-words li {
    font-size: clamp(3.4rem, 5.4vw, 4.8rem);
  }

  /* On wide screens the words sit on the left, so shade the left side as well. */
  .statement::after {
    background: linear-gradient(90deg, rgba(10, 6, 18, 0.75) 0%, rgba(10, 6, 18, 0.4) 40%, rgba(10, 6, 18, 0) 70%),
      linear-gradient(
        to bottom,
        rgba(10, 6, 18, 0.6) 0%,
        rgba(10, 6, 18, 0) 30%,
        rgba(10, 6, 18, 0) 60%,
        rgba(10, 6, 18, 0.7) 100%
      );
  }
}

@media (max-width: 760px) {
  .info-grid {
    grid-template-columns: 1fr;
    gap: 36px;
  }
}

@media (max-width: 520px) {
  .hero .book-now {
    padding: 16px 32px;
  }
}

/* Motion off: the Motion setting (which starts from the visitor's system setting). */
html[data-motion='off'] .hero .book-now,
html[data-motion='off'] .hero-tagline span {
  animation: none;
}

html[data-motion='off'] .reveal,
html[data-motion='off'] .reveal-down {
  opacity: 1;
  transform: none;
  transition: none;
}

html[data-motion='off'] .chev,
html[data-motion='off'] .switch-track,
html[data-motion='off'] .switch-track::after {
  transition: none;
}

/* ---------- Buttons ---------- */
.btn {
  display: inline-block;
  padding: 13px 24px;
  border: 2px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--ink);
  font-weight: 700;
  text-align: center;
  text-decoration: none;
}

.btn:not(:disabled):hover {
  border-color: var(--accent);
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.btn-primary:not(:disabled):hover {
  filter: brightness(1.08);
}

.book-now {
  padding: 18px 64px;
  border-radius: 999px;
  font-size: 1.35rem;
  font-weight: 800;
  letter-spacing: 0.01em;
}

/* ---------- Booking ---------- */
.book {
  max-width: 640px;
  margin: 0 auto;
  padding: calc(24px + env(safe-area-inset-top, 0px)) 20px 72px;
}

.back {
  display: inline-block;
  margin-bottom: 8px;
  color: var(--muted);
  text-decoration: none;
  padding: 6px 0;
}

.back:hover {
  color: var(--ink);
}

.book-title {
  margin: 0 0 20px;
  font-size: clamp(2rem, 7vw, 2.8rem);
  font-weight: 900;
  line-height: 1.05;
  font-variation-settings: 'wdth' 85;
}

.steps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.steps button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: none;
  border: 2px solid var(--line);
  border-radius: 999px;
  color: var(--muted);
  font-weight: 600;
  font-size: 0.92rem;
}

.steps button[aria-current='step'] {
  border-color: var(--accent);
  color: var(--ink);
}

.steps button.done {
  color: var(--ink);
}

.steps button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.steps .n {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--line);
  font-size: 0.8rem;
}

.steps [aria-current='step'] .n {
  background: var(--accent);
  color: var(--on-accent);
}

.panel {
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
  padding: 22px;
}

.panel h2 {
  margin: 0 0 16px;
  font-size: 1.4rem;
  font-weight: 800;
}

.opt {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  width: 100%;
  margin-bottom: 10px;
  padding: 14px;
  text-align: left;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.opt:hover {
  border-color: var(--accent);
}

.opt[aria-pressed='true'] {
  border-color: var(--accent);
  box-shadow: inset 4px 0 0 var(--accent);
}

.opt .name {
  font-weight: 700;
}

.opt .meta {
  color: var(--muted);
  font-size: 0.9rem;
}

.opt .leader {
  flex: 1;
  min-width: 16px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.opt .price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.opt .note {
  flex-basis: 100%;
  margin-top: 2px;
  font-size: 0.88rem;
  font-weight: 400;
  color: var(--muted);
}

.days {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 2px 2px 12px;
  overflow-x: auto;
}

.day {
  flex: none;
  width: 72px;
  padding: 10px 6px;
  text-align: center;
  line-height: 1.2;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.day .dow {
  display: block;
  font-size: 0.85rem;
  color: var(--muted);
}

.day .dom {
  display: block;
  font-size: 1.4rem;
  font-weight: 800;
}

.day .tag {
  display: block;
  min-height: 1em;
  font-size: 0.75rem;
  color: var(--muted);
}

.day[aria-pressed='true'] {
  border-color: var(--accent);
}

.day:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(98px, 1fr));
  gap: 8px;
  margin: 12px 0 4px;
}

.time {
  padding: 10px 6px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.time:hover:not(:disabled) {
  border-color: var(--accent);
}

/* Times that are taken or blocked stay visible, greyed out and struck through. */
.time:disabled {
  color: var(--muted);
  text-decoration: line-through;
  opacity: 0.45;
  cursor: not-allowed;
}

.times-note {
  margin: 8px 0 0;
  font-size: 0.85rem;
  color: var(--muted);
}

.time[aria-pressed='true'] {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.empty {
  padding: 18px;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

.summary {
  margin: 0 0 20px;
  padding: 14px 16px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.summary div + div {
  margin-top: 10px;
}

.summary dt {
  font-size: 0.85rem;
  color: var(--muted);
}

.summary dd {
  margin: 0;
  font-weight: 600;
}

.field {
  margin-bottom: 14px;
}

.field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}

.field input,
.field textarea {
  width: 100%;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.field input:focus,
.field textarea:focus {
  border-color: var(--accent);
}

.field input[aria-invalid='true'] {
  border-color: var(--danger);
}

.hint {
  font-weight: 400;
  font-size: 0.85rem;
  color: var(--muted);
}

.err {
  min-height: 1.3em;
  margin: 4px 0 0;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--danger);
}

.notice {
  margin: 0 0 16px;
  padding: 12px 14px;
  font-weight: 600;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.muted {
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 20px;
}

.done {
  padding-top: 24px;
}

.done p {
  margin: 0 0 8px;
}

.code {
  display: inline-block;
  margin: 4px 0 16px !important;
  padding: 6px 14px;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.done .btn {
  margin-top: 16px;
}

/* Big headline on the booking success screen. */
.done-headline {
  margin: 0 0 28px;
  font-size: clamp(2.6rem, 11vw, 4.6rem);
  font-weight: 900;
  line-height: 0.95;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.done-headline span {
  display: block;
}

.done-headline .done-line-2 {
  color: var(--accent);
}

.book-title.done-booked {
  margin: 0 0 12px;
  font-size: clamp(1.5rem, 5.5vw, 2rem);
}

/* The success screen is wider than the booking steps, so the headline can be big. */
.book.book-done {
  max-width: 960px;
}

.book-done .done p {
  max-width: 60ch;
}

@media (max-width: 520px) {
  .book-now {
    padding: 16px 48px;
  }
  .panel {
    padding: 16px;
  }
}

html[data-motion='off'] {
  scroll-behavior: auto;
}

/* The "0/500" under the notes box. Quiet until the person is close to the limit. */
.counter {
  margin: 4px 0 0;
  text-align: right;
  font-size: 0.85rem;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}

.counter-near {
  color: var(--danger);
  font-weight: 600;
}

/* ---------- Logo coin spin (the logo in the home page's top bar) ----------
   Stands still for 2.5 s, then turns around its upright middle line like a coin spinning on a table: two full
   turns over 3 s, a little quicker at first and slowing down, then it is standing straight again. Repeats forever.
   Nothing about the letters changes. Only the whole logo is turned.
   To change it: the 5.5s (whole cycle = standing still + spinning) and the 45.45% (the share of the cycle spent
   standing still: 2.5 / 5.5) below. The spin lasts the rest, 3 s. 720deg is two turns; 360deg is one. */
.brand .logo {
  perspective: 700px; /* gives the turn some depth: the near edge looks bigger as it comes round */
}

.logo-coin {
  display: block;
  position: relative;
  height: 100%;
  transform-style: preserve-3d;
  animation: logo-coin 5.5s infinite;
}

.logo-face {
  display: block;
  height: 100%;
  -webkit-backface-visibility: hidden;
  backface-visibility: hidden;
}

/* The back face sits on top of the front one, turned around, so it shows when the coin is turned. */
.logo-face-back {
  position: absolute;
  inset: 0;
  transform: rotateY(180deg);
}

@keyframes logo-coin {
  0%,
  45.45% {
    transform: rotateY(0deg);
    animation-timing-function: cubic-bezier(0.3, 0.45, 0.3, 1); /* gentle start, slow settle */
  }
  100% {
    transform: rotateY(720deg);
  }
}

/* Motion off in the menu (which starts from the visitor's system setting): the logo just stays still. */
html[data-motion='off'] .logo-coin {
  animation: none;
}
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/app/core/brand.py\", \"base\": null, \"new\": 0}, {\"path\": \"backend/app/core/errors.py\", \"base\": \"4cdf67c0dc621c6b5d6cb797be42037aac233b5d32f01180df0d39c3e579571e\", \"new\": 1}, {\"path\": \"backend/app/emailing/templates.py\", \"base\": \"9bfe781b222178e0ab0a2b174bf9c8a94c5d088a243423a0ee47e075517c185e\", \"new\": 2}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"8c11fcd8d7c41ace5a30d20599b3fb471173bbea29daa3d5b87665fae2256861\", \"new\": 3}, {\"path\": \"backend/tests/test_contract.py\", \"base\": \"a997849d53c6237ee9ef904db311bed5654adcf7edaefeec6ebb9e69097d4d1a\", \"new\": 4}, {\"path\": \"backend/tests/test_email.py\", \"base\": \"211a767797b901cd704ff75e311ba59b03968bc4b635e77e31541133f7136f23\", \"new\": 5}, {\"path\": \"backend/tests/test_messages.py\", \"base\": \"3250ea7ecbe299c4e405a4230527ad2b04a8b28eaec935c08d122094766c1368\", \"new\": 6}, {\"path\": \"frontend/index.html\", \"base\": \"e18e65d6f3580f0b6ca9daa24bb6c2e6ec39f745105d467f7640272b1beca640\", \"new\": 7}, {\"path\": \"frontend/src/components/EmailLink.jsx\", \"base\": null, \"new\": 8}, {\"path\": \"frontend/src/components/PhoneLink.jsx\", \"base\": \"544ec79e2745e03e92031a9cd6cf2fe8c86533476514b48fb6018fab50e468da\", \"new\": null}, {\"path\": \"frontend/src/components/ShopInfo.jsx\", \"base\": \"a0d0e34290f86681b126c18f65d69c28a2c86b6e94bde63db90222aaba3486e6\", \"new\": 10}, {\"path\": \"frontend/src/config.js\", \"base\": \"48c16d4274089c7852034d80007d6474981d02435cdb546f3d37e3910fb851eb\", \"new\": 11}, {\"path\": \"frontend/src/lib/seo.test.js\", \"base\": \"f19e05ef7fe482eee806c6c4f65895a9ce5a3e4b48114603d31c32eb0d0d5734\", \"new\": 12}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"55f9658c69a4b9146f9de0296264d966304f429384d9ba9e5e107a6dea758ab9\", \"new\": 13}, {\"path\": \"frontend/src/styles.css\", \"base\": \"b33817b98c0e6b12ffd459eb1ae04fee3032439ce45b07165b82b0ef88f3998b\", \"new\": 14}]")

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
echo "Next: (cd backend and python -m pytest) and (cd frontend and npm test), then commit and push to dev."
