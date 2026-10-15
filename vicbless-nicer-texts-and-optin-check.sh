#!/usr/bin/env bash
# Nicer texts, clearer cancel message, opt-in check
# Run from the REPO ROOT:  bash vicbless-nicer-texts-and-optin-check.sh
#
# Reformats the texts into short lines, makes the cancel confirmation say who is told,
# and shows a Texts OK / No texts mark beside the phone number on Vic's booking cards.
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
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
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
        "Pay at the shop.",
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
        "You can book a new time anytime on our site.",
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
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
import time

import jwt
import pytest

from app.core import security
from tests.helpers.api import schedule_of
from tests.helpers.builders import booking_body
from tests.helpers.constants import ADMIN_PASSWORD, JWT_SECRET, TUESDAY

D = TUESDAY


def test_login_wrong_password(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": "nope"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"


def test_login_not_configured(client):
    r = client.post("/api/admin/login", json={"password": "x"})
    assert r.status_code == 503 and r.json()["error"]["code"] == "not_configured"


def test_login_ok_returns_a_12_hour_token(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 200 and r.json()["expiresIn"] == 43200
    claims = jwt.decode(r.json()["token"], JWT_SECRET, algorithms=["HS256"], audience="vicbless-admin")
    assert claims["exp"] - claims["iat"] == 43200 and claims["sub"] == "vic"


def test_lockout_after_five_failures_then_correct_password_is_refused(client, admin_setup):
    for _ in range(5):
        assert client.post("/api/admin/login", json={"password": "bad"}).status_code == 401
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 429 and r.json()["error"]["code"] == "too_many_attempts"


def test_success_resets_the_counter(client, admin_setup):
    for _ in range(4):
        client.post("/api/admin/login", json={"password": "bad"})
    assert client.post("/api/admin/login", json={"password": ADMIN_PASSWORD}).status_code == 200
    for _ in range(4):
        assert client.post("/api/admin/login", json={"password": "bad"}).status_code == 401


ADMIN_ROUTES = [
    ("get", f"/api/admin/schedule?date={D}"),
    ("delete", f"/api/admin/bookings/{D}.0720.abcdef12"),
    ("post", "/api/admin/blocks"),
    ("delete", f"/api/admin/blocks/{D}.0720.abcdef12"),
]


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_need_a_token(client, admin_setup, method, path):
    r = getattr(client, method)(path) if method != "post" else client.post(path, json={})
    assert r.status_code == 401


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_reject_bad_tokens(client, admin_setup, method, path):
    expired = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "iat": int(time.time()) - 90000, "exp": int(time.time()) - 10},
        JWT_SECRET,
        algorithm="HS256",
    )
    wrong_key = security.issue_token("z" * 40)
    none_alg = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "exp": int(time.time()) + 999}, key=None, algorithm="none"
    )
    good = security.issue_token(JWT_SECRET)
    wrong_audience = jwt.encode(
        {"iss": "vicbless", "aud": "other", "sub": "vic", "iat": 1, "exp": int(time.time()) + 999}, JWT_SECRET, algorithm="HS256"
    )
    for token in (expired, wrong_key, none_alg, wrong_audience, good[:-3] + "abc", "garbage"):
        headers = {"Authorization": f"Bearer {token}"}
        r = client.request(method.upper(), path, headers=headers, json={} if method == "post" else None)
        assert r.status_code == 401, token


def test_non_bearer_scheme_rejected(client, admin_setup):
    token = security.issue_token(JWT_SECRET)
    r = client.get(f"/api/admin/schedule?date={D}", headers={"Authorization": f"Basic {token}"})
    assert r.status_code == 401


def test_schedule_shows_booking_with_contact_details(client, auth):
    client.post("/api/bookings", json=booking_body(email="m@example.com", notes="Short on the sides"))
    day = schedule_of(client, auth)
    [item] = day["items"]
    assert item["name"] == "Marcus Jones" and item["email"] == "m@example.com" and item["notes"] == "Short on the sides"
    assert item["source"] == "online" and item["code"].startswith("VB-") and item["start"] == 720 and item["dateKey"] == D
    assert item["smsConsent"] is False and day["blocks"] == []


def test_schedule_shows_whether_the_customer_agreed_to_texts(client, auth):
    client.post("/api/bookings", json=booking_body(smsConsent=True))
    [item] = schedule_of(client, auth)["items"]
    assert item["smsConsent"] is True


def test_cancel_frees_the_time_and_emails_the_customer(client, auth, sent):
    client.post("/api/bookings", json=booking_body(email="m@example.com"))
    sent.clear()
    [item] = schedule_of(client, auth)["items"]
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 200
    assert schedule_of(client, auth)["items"] == []
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D]["busy"] == []
    assert [m.to for m in sent] == ["m@example.com"] and "cancelled" in sent[0].subject
    assert client.post("/api/bookings", json=booking_body(name="New Person", phone="5550107777")).status_code == 201


def test_cancel_unknown_or_malformed_id_is_404(client, auth):
    for bad in (f"{D}.0720.abcdef12", "nonsense", "..%2F..", f"{D}.9999.abcdef12"):
        r = client.delete(f"/api/admin/bookings/{bad}", headers=auth)
        assert r.status_code == 404, bad


def test_cancel_twice_second_is_404(client, auth):
    client.post("/api/bookings", json=booking_body())
    [item] = schedule_of(client, auth)["items"]
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 200
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 404


def test_part_day_block_hides_times(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 790, "note": "Lunch"})
    assert r.status_code == 201
    block = r.json()
    assert block["whole"] is False and block["note"] == "Lunch" and block["start"] == 720 and block["end"] == 790
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D] == {"busy": [720, 755], "dayOff": False, "slotMinutes": 35}
    assert client.post("/api/bookings", json=booking_body()).status_code == 409
    assert schedule_of(client, auth)["blocks"][0]["id"] == block["id"]
    assert client.delete(f"/api/admin/blocks/{block['id']}", headers=auth).status_code == 200
    assert client.post("/api/bookings", json=booking_body()).status_code == 201


def test_whole_day_off_shows_closed(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "whole": True})
    assert r.status_code == 201 and r.json()["start"] == 720 and r.json()["end"] == 1080
    day = client.get(f"/api/availability?from={D}&to={D}").json()[D]
    assert day["dayOff"] is True and len(day["busy"]) == 10
    assert client.post("/api/bookings", json=booking_body()).status_code == 409


def test_whole_saturday_covers_both_windows(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": "2026-10-17", "whole": True})
    assert r.status_code == 201
    day = client.get("/api/availability?from=2026-10-17&to=2026-10-17").json()["2026-10-17"]
    assert 540 in day["busy"] and 755 in day["busy"] and 720 not in day["busy"]


def test_block_over_a_booking_is_conflict_and_changes_nothing(client, auth):
    client.post("/api/bookings", json=booking_body(start=755))  # 12:35
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 900})
    assert r.status_code == 409 and r.json()["error"]["code"] == "conflict"
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D]["busy"] == [755]
    assert schedule_of(client, auth)["blocks"] == []


def test_overlapping_blocks_conflict(client, auth):
    assert client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 790}).status_code == 201
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 755, "end": 825})
    assert r.status_code == 409


@pytest.mark.parametrize(
    "body,status",
    [
        ({"dateKey": "2026-10-14", "whole": True}, 422),  # closed day
        ({"dateKey": "2026-10-09", "whole": True}, 422),  # past
        ({"dateKey": "2027-12-31", "whole": True}, 422),  # too far
        ({"dateKey": D, "start": 800, "end": 700}, 422),
        ({"dateKey": D, "start": 0, "end": 60}, 422),  # outside hours
        ({"dateKey": "bad", "whole": True}, 422),
    ],
)
def test_block_validation(client, auth, body, status):
    assert client.post("/api/admin/blocks", headers=auth, json=body).status_code == status


def test_block_can_be_a_year_ahead(client, auth):
    # 2027-10-12 is a Tuesday and exactly 365 days from the fixed "today"
    assert client.post("/api/admin/blocks", headers=auth, json={"dateKey": "2027-10-12", "whole": True}).status_code == 201


def test_remove_unknown_block_404(client, auth):
    assert client.delete(f"/api/admin/blocks/{D}.0720.abcdef12", headers=auth).status_code == 404


@pytest.mark.parametrize("header", [None, "", "Bearer", "Bearer   ", "Basic abc", "Token abc", "abc"])
def test_check_bearer_rejects_headers_that_are_not_a_bearer_token(admin_setup, header):
    from app.core.errors import Unauthorized
    from app.services import auth as auth_service

    with pytest.raises(Unauthorized):
        auth_service.check_bearer(header)


def test_check_bearer_accepts_a_valid_token_in_any_letter_case(admin_setup):
    from app.services import auth as auth_service

    token = security.issue_token(JWT_SECRET)
    auth_service.check_bearer(f"Bearer {token}")
    auth_service.check_bearer(f"bearer {token}")
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Texts: the Textbelt bridge, who gets a text and when, and the wording."""

import io
import json
import urllib.error
import urllib.parse
import urllib.request

import pytest

from app.core import config
from app.texting import NullSender, SmsMessage, get_sender, templates, us_number
from app.texting.textbelt import SmsSendError, TextbeltSender
from tests.fixtures.sms import OWNER_PHONE
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_model

# --- numbers ----------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("(555) 010-0777", "5550100777"),
        ("+1 555 010 0777", "5550100777"),
        ("15550100777", "5550100777"),
        ("5550100777", "5550100777"),
        ("010-0777", None),  # too short
        ("+44 7700 900123", None),  # not a US number
        ("0125550100", None),  # US area codes never start with 0 or 1
        ("", None),
        (None, None),
    ],
)
def test_us_number(raw, expected):
    assert us_number(raw) == expected


# --- the Textbelt bridge --------------------------------------------------------------------------------------


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def fake_urlopen(monkeypatch, answer=None, raises=None):
    """Replaces the network. Returns the list of requests that were made."""
    made = []

    def urlopen(request, timeout=None):
        made.append((request, timeout))
        if raises:
            raise raises
        return FakeResponse(json.dumps(answer).encode())

    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    return made


def test_a_text_is_posted_to_textbelt_with_the_key_in_the_form(monkeypatch):
    made = fake_urlopen(monkeypatch, {"success": True, "quotaRemaining": 99, "textId": "1"})
    TextbeltSender(api_key="secret-key").send(SmsMessage(to="5550100777", body="Hello there"))
    request, timeout = made[0]
    assert request.full_url == "https://textbelt.com/text" and request.get_method() == "POST" and timeout == 5
    form = urllib.parse.parse_qs(request.data.decode())
    assert form["phone"] == ["5550100777"] and form["message"] == ["Hello there"] and form["key"] == ["secret-key"]
    assert form["sender"] == ["Vicbless Barbershop"]
    assert "secret-key" not in request.full_url  # never in the address


@pytest.mark.parametrize(
    "kwargs",
    [
        {"answer": {"success": False, "error": "Out of quota"}},
        {"answer": ["not", "a", "dict"]},
        {"raises": urllib.error.URLError("down")},
        {"raises": TimeoutError()},
        {"raises": urllib.error.HTTPError("https://textbelt.com/text", 500, "boom", {}, None)},
    ],
)
def test_a_refused_or_unreachable_textbelt_raises_sms_send_error(monkeypatch, kwargs):
    fake_urlopen(monkeypatch, **kwargs)
    with pytest.raises(SmsSendError):
        TextbeltSender(api_key="k").send(SmsMessage(to="5550100777", body="x"))


def watch_logs(monkeypatch):
    """Replaces the bridge's logger with a list of (event, fields)."""
    from app.texting import textbelt

    seen = []
    monkeypatch.setattr(textbelt, "log", lambda event, **fields: seen.append((event, fields)))
    return seen


def test_logs_never_contain_the_key_or_the_number(monkeypatch):
    seen = watch_logs(monkeypatch)
    fake_urlopen(monkeypatch, {"success": False, "error": "Out of quota"})
    with pytest.raises(SmsSendError):
        TextbeltSender(api_key="super-secret").send(SmsMessage(to="5550100777", body="hi"))
    assert seen == [("sms_failed", {"provider": "textbelt", "reason": "Out of quota"})]
    assert "super-secret" not in str(seen) and "5550100777" not in str(seen)


def test_a_low_quota_is_noted_in_the_logs(monkeypatch):
    seen = watch_logs(monkeypatch)
    fake_urlopen(monkeypatch, {"success": True, "quotaRemaining": 4})
    TextbeltSender(api_key="k").send(SmsMessage(to="5550100777", body="x"))
    assert "sms_quota_low" in [event for event, _ in seen]
    assert "sms_accepted" in [event for event, _ in seen]


# --- picking the provider ---------------------------------------------------------------------------------


def test_without_a_key_texts_are_skipped():
    assert isinstance(get_sender(), NullSender)


def test_with_a_key_textbelt_is_used():
    put_param("textbelt-key", "abc123")
    assert isinstance(get_sender(), TextbeltSender)


def test_an_unknown_provider_means_no_texts(monkeypatch):
    monkeypatch.setenv("SMS_PROVIDER", "carrier-pigeon")
    config.params.reset()
    assert isinstance(get_sender(), NullSender)


# --- the wording ----------------------------------------------------------------------------------------------


def test_customer_texts_name_the_shop_and_carry_the_opt_out():
    b = booking_model()
    for body in (
        templates.customer_confirmation(b),
        templates.customer_cancellation(b),
        templates.customer_rescheduled(b, booking_model(start=765)),
        templates.customer_reminder(b),
    ):
        assert body.startswith("VICBLESS BARBERSHOP\n") and body.endswith("Reply STOP to opt out.")
        assert "\n\n" in body and len(body) < 300  # short lines with blank lines between the parts


def test_the_texts_have_the_details_a_customer_needs():
    b = booking_model()
    assert "Tue, Oct 13 at 12:00 pm" in templates.customer_confirmation(b) and "VB-ABC234" in templates.customer_confirmation(b)
    assert "Marcus" in templates.customer_confirmation(b)
    moved = templates.customer_rescheduled(b, booking_model(start=765))
    assert "12:45 pm" in moved and "Was: Tue, Oct 13 at 12:00 pm" in moved
    assert "656 S Main St" in templates.customer_reminder(b)


def test_the_owner_text_has_no_opt_out_and_shows_the_phone():
    body = templates.owner_new_booking(booking_model())
    assert "STOP" not in body and "5550101234" in body and "Marcus Jones" in body and "Men's haircut" in body


def test_what_a_customer_typed_cannot_break_a_text_into_lines():
    b = booking_model(name="Mal\nlory\r\n" + "x" * 80, service_name="Cut\x00\x07 and" + "y" * 100)
    body = templates.owner_new_booking(b)
    name_and_service = body.split("\n")[3:5]  # the lines carrying what the customer typed stay one line each
    assert len(name_and_service) == 2 and all("\r" not in line for line in name_and_service)
    assert "Mal lory" in body and "\x00" not in body and "x" * 41 not in body and "y" * 51 not in body


# --- who gets a text, and when ---------------------------------------------------------------------------------


def numbers(texts):
    return sorted(m.to for m in texts)


def test_vic_is_texted_about_every_booking_and_a_customer_only_if_they_agreed(client, texts):
    assert book(client).status_code == 201  # no consent given
    assert numbers(texts) == ["5550100777"]
    assert "New booking" in texts[0].body
    texts.clear()
    assert book(client, start=12 * 60 + 35, phone="(555) 010-9999", smsConsent=True).status_code == 201
    assert numbers(texts) == ["5550109999", "5550100777"] or numbers(texts) == sorted(["5550109999", "5550100777"])
    assert any("You're booked" in m.body and m.to == "5550109999" for m in texts)


def test_without_vics_number_only_the_customer_is_texted(client, texts):
    put_param("owner-phone", " ", secure=False)
    book(client, smsConsent=True)
    assert numbers(texts) == ["5550101234"]


def test_a_number_that_is_not_a_us_mobile_is_skipped_quietly(client, texts):
    r = book(client, phone="+44 7700 900123", smsConsent=True)
    assert r.status_code == 201
    assert numbers(texts) == ["5550100777"]  # only Vic


def test_sms_consent_must_be_true_or_false(client, texts):
    assert book(client, smsConsent="yes").status_code == 422
    assert texts == []


def test_a_failing_text_provider_never_fails_the_booking(client, monkeypatch):
    from app.services import notifications

    class Broken:
        def send(self, message):
            raise SmsSendError("down")

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Broken())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    assert book(client, smsConsent=True).status_code == 201


def test_cancel_and_move_text_only_customers_who_agreed(client, auth, texts):
    book(client, smsConsent=True)
    book(client, start=12 * 60 + 35, phone="(555) 010-7777", name="No Texts")
    texts.clear()
    first, second = schedule_of(client, auth)["items"]
    assert client.patch(f"/api/admin/bookings/{first['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660}).status_code == 200
    assert [m.to for m in texts] == ["5550101234"] and "moved" in texts[0].body
    texts.clear()
    assert client.delete(f"/api/admin/bookings/{second['id']}", headers=auth).status_code == 200
    assert texts == []  # this customer never agreed to texts
    moved_id = [i for i in schedule_of(client, auth, "2026-10-15")["items"]][0]["id"]
    assert client.delete(f"/api/admin/bookings/{moved_id}", headers=auth).status_code == 200
    assert [m.to for m in texts] == ["5550101234"] and "cancelled" in texts[0].body


def test_consent_survives_a_move(client, auth, texts):
    book(client, smsConsent=True)
    item = schedule_of(client, auth)["items"][0]
    client.patch(f"/api/admin/bookings/{item['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    from app.database import bookings as bookings_db

    moved = schedule_of(client, auth, "2026-10-15")["items"][0]
    assert bookings_db.get_booking(moved["id"]).sms_consent is True


# --- the reminder email -------------------------------------------------------------------------------------


def test_the_reminder_email_is_branded_and_has_the_details():
    from app.emailing import templates as email_templates

    message = email_templates.customer_reminder(booking_model(), "vic@example.com")
    assert message.to == "m@example.com" and message.reply_to == "vic@example.com"
    assert "Reminder" in message.subject and "Tuesday, October 13 at 12:00 pm" in message.subject
    for part in (message.text, message.html):
        assert "VB-ABC234" in part and "VICBLESS BARBERSHOP" in part and "656 S Main St" in part


# --- Textbelt refuses anything that looks like a link -----------------------------------------------------------


def looks_like_a_link(body: str) -> bool:
    import re

    return bool(re.search(r"[\w-]\.[A-Za-z]{2,}|@|https?:|www\.", body))


def test_no_text_can_contain_something_that_looks_like_a_web_or_email_address():
    hostile = booking_model(name="Shop.com Bob@mail.net", service_name="Visit www.deal.io/now: cut")
    other = booking_model(start=765)
    bodies = [
        templates.owner_new_booking(hostile),
        templates.customer_confirmation(hostile),
        templates.customer_cancellation(hostile),
        templates.customer_rescheduled(hostile, other),
        templates.customer_reminder(hostile),
        templates.customer_confirmation(booking_model()),
        templates.customer_reminder(booking_model()),
    ]
    for body in bodies:
        assert not looks_like_a_link(body), body
    assert "vicslegacy89" not in " ".join(bodies)


def test_textbelts_own_reason_is_logged_in_full(monkeypatch):
    seen = watch_logs(monkeypatch)
    reason = "Sorry, ability to send URLs via text is limited to verified accounts. Please go to the verification page."
    fake_urlopen(monkeypatch, {"success": False, "error": reason})
    with pytest.raises(SmsSendError):
        TextbeltSender(api_key="k").send(SmsMessage(to="5550100777", body="x"))
    assert seen[0][1]["reason"] == reason
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
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
import { cancelMessage, textsLabel } from './notify.js'

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
  const texts = textsLabel(item)
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
      {item.source !== 'sample' && item.code && <p className="admin-code">Code {item.code}</p>}
      {item.phone && (
        <div className="admin-phone-row">
          {tel ? (
            <a className="phone-link" href={tel}>
              {formatPhone(item.phone)}
            </a>
          ) : (
            <span>{formatPhone(item.phone)}</span>
          )}
          <span className={`texts-badge ${texts.on ? 'texts-on' : 'texts-off'}`} title={texts.on ? 'Agreed to texts' : "Didn't agree to texts"}>
            <span aria-hidden="true">{texts.mark}</span> {texts.words}
          </span>
        </div>
      )}
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
          {cancelMessage(item, fmtTime(item.start), serviceName)}
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
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
/* Admin screens. Every rule starts with .admin so nothing here can touch the public pages. */

.admin {
  max-width: 720px;
  margin: 0 auto;
  padding: calc(16px + env(safe-area-inset-top, 0px)) 16px calc(48px + env(safe-area-inset-bottom, 0px));
}

/* The big welcome line, the page heading. Vic's name is picked out in the accent colour. */
.admin-greeting {
  margin: 20px 0 8px;
  font-size: clamp(2.1rem, 9vw, 3.3rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.admin-name {
  color: var(--accent);
}

.admin-lede {
  margin: 0 0 24px;
  color: var(--muted);
}

/* ---- The logo: goes around an oval like a carousel and turns as it goes ----
   Facing you at the front of the oval, edge-on at the sides, facing away at the back (where the writing
   reads backwards, like a mirror). Bigger at the front, smaller at the back. Always flat.
   To adjust, change these on .admin-loop:
     --orbit-time  seconds for one lap (3.5s now)
     --ax          how wide the oval is, as a % of the logo's own width
     --by          how tall the oval is, as a % of the logo's own height
     --depth       how much bigger at the front / smaller at the back (0.28 = 28%)
   --persp (set per spot below) is how strong the 3D looks: smaller means stronger.
   The logo's size in each spot is the width on its .admin-loop-orbit rule. A bigger logo needs a bigger
   frame, because the whole lap has to fit inside it. */
.admin-loop {
  --orbit-time: 3.5s;
  --ax: 28;
  --by: 20;
  --depth: 0.28;
}

/* Anything outside the frame is cut off, so the frame is sized to hold the whole lap.
   The front of the oval swings low and big, so the logo sits a little higher in its frame (--lift)
   to give that swing room. */
.admin-loop-frame {
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: center;
  padding-bottom: calc(var(--lift) * 2);
  overflow: hidden;
}

.admin-loop-orbit {
  animation: admin-orbit var(--orbit-time) linear infinite;
}

.admin-loop-still {
  animation: none;
  transform: none;
}

.admin-loop .logo {
  width: 100%;
}

/* Sign-in: a little smaller than the old still logo, to leave room for the lap. The frame is the full
   width of the screen (it cancels the page's 16px side padding). */
.admin-loop-hero {
  --persp: 880px;
  --lift: 13px;
  width: calc(100% + 32px);
  height: 160px;
  margin: 0 -16px 8px;
}

.admin-loop-hero .admin-loop-frame {
  width: 100%;
  height: 100%;
}

/* 260px, but on a narrower phone it shrinks so the whole lap (about 1.45 times the logo's width)
   still fits on the screen. */
.admin-loop-hero .admin-loop-orbit {
  width: min(260px, calc((100vw - 12px) / 1.5));
}

/* Dashboard top bar: the logo's place in the bar is this tall, but its frame is the whole width of the bar. */
.admin-loop-bar {
  --persp: 490px;
  --lift: 7px;
  width: 144px;
  height: 94px;
}

.admin-loop-bar .admin-loop-frame {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 14px;
  left: 0;
  pointer-events: none;
}

.admin-loop-bar .admin-loop-orbit {
  width: 144px;
}

.admin-bar .menu-toggle {
  position: relative;
  z-index: 3;
  background: var(--bg);
}

@keyframes admin-orbit {
  0% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(0deg);
  }

  2.0833% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(7.5deg);
  }

  4.1667% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(15deg);
  }

  6.25% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(22.5deg);
  }

  8.3333% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(30deg);
  }

  10.4167% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(37.5deg);
  }

  12.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(45deg);
  }

  14.5833% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(52.5deg);
  }

  16.6667% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(60deg);
  }

  18.75% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(67.5deg);
  }

  20.8333% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(75deg);
  }

  22.9167% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(82.5deg);
  }

  25% {
    transform: translate(calc(var(--ax) * -1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(90deg);
  }

  27.0833% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(97.5deg);
  }

  29.1667% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(105deg);
  }

  31.25% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(112.5deg);
  }

  33.3333% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(120deg);
  }

  35.4167% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(127.5deg);
  }

  37.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(135deg);
  }

  39.5833% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(142.5deg);
  }

  41.6667% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(150deg);
  }

  43.75% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(157.5deg);
  }

  45.8333% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(165deg);
  }

  47.9167% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(172.5deg);
  }

  50% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * -1%)) scale(calc(1 + var(--depth) * -1)) perspective(var(--persp)) rotateY(180deg);
  }

  52.0833% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(187.5deg);
  }

  54.1667% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(195deg);
  }

  56.25% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(202.5deg);
  }

  58.3333% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(210deg);
  }

  60.4167% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(217.5deg);
  }

  62.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(225deg);
  }

  64.5833% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(232.5deg);
  }

  66.6667% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(240deg);
  }

  68.75% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(247.5deg);
  }

  70.8333% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(255deg);
  }

  72.9167% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(262.5deg);
  }

  75% {
    transform: translate(calc(var(--ax) * 1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(270deg);
  }

  77.0833% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(277.5deg);
  }

  79.1667% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(285deg);
  }

  81.25% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(292.5deg);
  }

  83.3333% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(300deg);
  }

  85.4167% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(307.5deg);
  }

  87.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(315deg);
  }

  89.5833% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(322.5deg);
  }

  91.6667% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(330deg);
  }

  93.75% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(337.5deg);
  }

  95.8333% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(345deg);
  }

  97.9167% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(352.5deg);
  }

  100% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(360deg);
  }
}

/* Sign-in is a single centred column. */
.admin-signin {
  max-width: 440px;
  text-align: center;
}

.admin-signin form {
  text-align: left;
}

.admin-signin .btn {
  width: 100%;
}

.admin-signin a {
  color: var(--accent);
}

.admin-foot {
  margin-top: 40px;
  padding-top: 20px;
  font-size: 0.85rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-align: center;
  color: var(--muted);
  border-top: 1px solid var(--line);
}

.admin-preview-note {
  margin: 12px 0 20px;
  padding: 10px 12px;
  font-size: 0.88rem;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

/* Top bar: menu on the left, logo in the middle (the same arrangement as the public site). */
.admin-bar {
  position: relative; /* the menu panel hangs just under the bar */
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  gap: 12px;
  padding-bottom: 14px;
  border-bottom: 2px solid var(--accent);
}

.admin-bar .site-menu {
  justify-self: start;
}

.admin-bar .menu-panel {
  left: 0;
  max-height: calc(100vh - 120px);
  max-height: calc(100svh - 120px);
}

/* ---- day navigation ---- */
.admin-day-nav {
  display: grid;
  grid-template-columns: 48px 1fr 48px;
  gap: 8px;
  align-items: center;
  margin-bottom: 12px;
}

.admin-icon-btn {
  display: grid;
  place-items: center;
  width: 48px;
  height: 48px;
  padding: 0;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-icon-btn:hover {
  border-color: var(--accent);
}

.admin-day-title {
  text-align: center;
}

.admin-day-title h2 {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 800;
}

/* Under the date: Today (or Back to today) and the Pick a date button. */
.admin-day-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 10px;
  margin-top: 8px;
}

/* Pick a date: a big pill. The real date field is invisible and covers all of it, so any tap opens the
   phone's own date picker. 16px text stops iPhones from zooming in. */
.admin-jump {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 48px;
  padding: 0 18px;
  font-weight: 800;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--accent);
  border-radius: 999px;
  cursor: pointer;
}

.admin-jump:hover {
  background: var(--bg);
}

.admin-jump:focus-within {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.admin-jump input[type='date'] {
  position: absolute;
  inset: -2px; /* reaches over the pill's own 2px outline too, so every part of it is the real field */
  width: calc(100% + 4px);
  height: calc(100% + 4px);
  margin: 0;
  padding: 0;
  font-size: 16px;
  opacity: 0;
  cursor: pointer;
}

.admin-jump input[type='date']::-webkit-calendar-picker-indicator {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0;
  cursor: pointer;
}

.admin-today-tag {
  display: inline-block;
  margin-top: 2px;
  padding: 1px 10px;
  font-size: 0.78rem;
  font-weight: 700;
  color: var(--on-accent);
  background: var(--accent);
  border-radius: 999px;
}

.admin-link-btn {
  min-height: 44px;
  padding: 8px 12px;
  font-size: 0.85rem;
  font-weight: 600;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
  background: none;
  border: 0;
}

.admin-status {
  color: var(--muted);
}

.admin-summary {
  margin: 0 0 8px;
  color: var(--muted);
  font-weight: 600;
}

/* ---- the day ---- */
.admin-rows {
  margin: 0;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.admin-row {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  align-items: start;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-time {
  padding-top: 2px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.admin-open-label,
.admin-continues {
  margin: 0;
  padding: 4px 0;
  color: var(--muted);
}

.admin-open .admin-time {
  color: var(--muted);
  font-weight: 600;
}

.admin-card {
  padding: 10px 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-card h3 {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 800;
}

.admin-card p {
  margin: 2px 0 0;
}

.admin-meta {
  font-size: 0.92rem;
  color: var(--muted);
}

.admin-notes {
  font-size: 0.92rem;
  font-style: italic;
}

.admin-card .phone-link,
.admin-card .email-link {
  display: block;
  width: fit-content;
  max-width: 100%;
  padding: 6px 0;
  overflow-wrap: anywhere;
}

.admin-card .email-link {
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-card span.email-link {
  color: var(--ink);
  text-decoration: none;
}

.admin-sample-badge {
  margin-left: 8px;
  padding: 1px 8px;
  font-size: 0.7rem;
  font-weight: 600;
  vertical-align: middle;
  color: var(--muted);
  border: 1px solid var(--line);
  border-radius: 999px;
}

.admin-break {
  padding: 10px 0;
  font-size: 0.85rem;
  text-align: center;
  color: var(--muted);
  border-bottom: 1px dashed var(--line);
}

.admin-unmatched {
  margin-top: 24px;
}

.admin-unmatched h3 {
  margin: 0 0 4px;
}

.admin-row-lone {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  margin-top: 10px;
}

/* ---- actions: cancel, block off time ---- */
.admin-summary-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin: 0 0 8px;
}

.admin-summary-row .admin-summary {
  margin: 0;
}

.admin-summary-row .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

/* Cancel and Remove block: real boxes with a big, easy tap target. */
.admin-box-btn {
  display: block;
  width: 100%;
  max-width: 280px;
  min-height: 52px;
  margin-top: 12px;
  padding: 12px 18px;
  font-size: 1rem;
  font-weight: 800;
  text-align: center;
  color: var(--ink);
  background: transparent;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-box-btn:hover {
  border-color: var(--ink);
}

.admin-box-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-box-danger:hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-confirm {
  margin-top: 10px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-confirm-text {
  margin: 0 0 14px;
  font-size: 0.95rem;
}

.admin-confirm-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.admin-confirm-actions .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

.admin-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-danger:not(:disabled):hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-card-block {
  background: transparent;
  border-style: dashed;
  border-left: 5px solid var(--muted);
}

.admin-blocked-continues .admin-time,
.admin-blocked .admin-time {
  color: var(--muted);
}

.admin-flash-wrap {
  min-height: 0;
}

.admin-flash {
  margin: 0 0 12px;
  padding: 10px 12px;
  font-weight: 600;
  border: 2px solid var(--accent);
  border-radius: 8px;
}

/* ---- block off time form ---- */
.admin-block-form {
  margin: 4px 0 16px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-block-form h3 {
  margin: 0 0 8px;
  font-size: 1.2rem;
  font-weight: 800;
}

.admin-block-form fieldset {
  margin: 0 0 8px;
  padding: 0;
  border: 0;
}

.admin-block-form legend {
  margin-bottom: 4px;
  padding: 0;
  font-weight: 700;
}

.admin-radio {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 44px;
}

.admin-radio input {
  width: 20px;
  height: 20px;
  accent-color: var(--accent);
}

.admin-block-times {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.admin-block-form select {
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-block-form select:focus {
  border-color: var(--accent);
}

.admin-conflicts {
  margin: 0 0 12px;
  padding: 10px 12px;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-conflicts p {
  margin: 0;
  font-weight: 600;
}

.admin-conflicts p + p {
  margin-top: 6px;
}

/* ---- Phones: a roomier "Block off time" ----
   Bigger time pickers, radio buttons and buttons, because the compact sizes that suit a mouse are small for a
   thumb. This applies to phones and touch tablets only; computers keep the compact sizes. */
@media (max-width: 640px), (pointer: coarse) {
  .admin-summary-row {
    flex-wrap: wrap;
    gap: 10px;
  }

  .admin-summary-row .btn {
    min-height: 56px;
    padding: 12px 20px;
    font-size: 1.05rem;
    white-space: nowrap;
  }

  .admin-block-form {
    padding: 18px;
  }

  .admin-block-form legend,
  .admin-block-form .field label {
    font-size: 1.05rem;
  }

  .admin-radio {
    gap: 14px;
    min-height: 58px;
    font-size: 1.1rem;
  }

  .admin-radio input {
    width: 28px;
    height: 28px;
  }

  .admin-block-times {
    gap: 14px;
  }

  .admin-block-form select {
    min-height: 64px;
    padding: 14px 16px;
    font-size: 1.15rem;
    font-weight: 700;
  }

  .admin-block-form .field input {
    min-height: 60px;
    font-size: 1.1rem;
  }

  .admin-block-form .actions .btn {
    flex: 1;
    min-height: 60px;
    font-size: 1.1rem;
  }
}

/* On the narrowest phones the From and Until pickers stack, so each one is full width and big. */
@media (max-width: 380px) {
  .admin-block-times {
    grid-template-columns: 1fr;
  }

  .admin-summary-row .btn {
    flex: 1 1 100%;
  }
}

/* On phones the two buttons at the bottom of the form stack, one per row, so each label fits on one line. */
@media (max-width: 480px) {
  .admin-block-form .actions {
    flex-direction: column;
  }
}

/* ---- long notes: wrap inside the card, fold behind "Show more" ---- */

/* A grid column can't shrink below its widest word unless told it may. This is what stopped a long note
   (or one long unbroken string) from pushing the page sideways. */
.admin-row,
.admin-row-lone {
  grid-template-columns: 84px minmax(0, 1fr);
}

.admin-slot,
.admin-row-lone > :last-child,
.admin-card {
  min-width: 0;
}

.admin-notes {
  white-space: pre-line; /* keep the customer's line breaks, wrap everything else */
  overflow-wrap: anywhere;
}

.admin-notes-folded {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  overflow: hidden;
}

.admin-notes-toggle {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 44px;
  margin-top: 2px;
  padding: 0 6px 0 0;
  font-size: 0.92rem;
  font-weight: 700;
  color: var(--accent);
  background: transparent;
  border: 0;
  cursor: pointer;
}

.admin-notes-toggle:hover {
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-chevron {
  transition: transform 0.15s ease;
}

.admin-chevron.open {
  transform: rotate(180deg);
}

@media (prefers-reduced-motion: reduce) {
  .admin-chevron {
    transition: none;
  }
}

/* ---- Change time / Cancel buttons, and the Change time panel ---- */
.admin-card-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 12px;
}

.admin-card-actions .admin-box-btn {
  flex: 1 1 140px;
  width: auto;
  max-width: none;
  margin-top: 0;
}

.admin-move-form {
  margin: 12px 0 0;
  background: var(--bg);
}

.admin-move-form h3 {
  margin: 0 0 2px;
}

.admin-move-form .field input[type='date'] {
  width: 100%;
}

.admin-move-times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(104px, 1fr));
  gap: 8px;
  margin: 0 0 12px;
}

.admin-move-time {
  position: relative;
  min-height: 52px;
  padding: 8px 6px;
  font-size: 1rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.admin-move-time:not(:disabled):hover {
  border-color: var(--accent);
}

.admin-move-time[aria-pressed='true'] {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

.admin-move-time:disabled {
  cursor: not-allowed;
  color: var(--muted);
  background: transparent;
  opacity: 0.55;
}

.admin-move-taken,
.admin-move-past {
  text-decoration: line-through;
}

.admin-move-now {
  display: block;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.admin-move-summary {
  margin: 0 0 12px;
  font-weight: 600;
}

/* ---- shop settings (Menu > Settings > Shop settings) ---- */
.admin-settings {
  margin: 12px 0 24px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-settings-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px 12px;
}

.admin-settings h2 {
  margin: 0;
  font-size: 1.4rem;
  font-weight: 800;
}

.admin-settings-group {
  margin: 20px 0 0;
  padding: 0;
  border: 0;
}

.admin-settings-group legend {
  margin-bottom: 8px;
  padding: 0;
  font-size: 1.1rem;
  font-weight: 800;
}

.admin-svc-list,
.admin-slot-list {
  margin: 0 0 12px;
  padding: 0;
  list-style: none;
}

.admin-svc {
  margin-bottom: 12px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-svc .field input {
  min-height: 48px;
}

.admin-svc-price {
  display: grid;
  grid-template-columns: minmax(96px, 140px) 1fr;
  gap: 4px 14px;
  align-items: start;
}

.admin-svc-from {
  margin-top: 26px;
}

.admin-svc-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.admin-slot-row {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 4px 12px;
  align-items: center;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-slot-day label {
  display: block;
  font-weight: 700;
}

.admin-slot-input {
  display: flex;
  align-items: center;
  gap: 8px;
}

.admin-slot-input input {
  width: 92px;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-slot-input input:focus {
  border-color: var(--accent);
}

.admin-slot-input input[aria-invalid='true'] {
  border-color: var(--danger);
}

.admin-slot-row .err {
  grid-column: 1 / -1;
  min-height: 0;
}

.admin-svc-actions .admin-box-btn {
  flex: 1 1 0;
  width: auto;
  min-width: 0;
}

.admin-remind-list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.admin-svc-actions .admin-box-btn {
  padding-inline: 8px;
  font-size: 0.95rem;
  white-space: nowrap;
}

.admin-code {
  font-size: 0.92rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  color: var(--muted);
}

.admin-phone-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 12px;
}

.texts-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 10px;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.82rem;
  font-weight: 700;
  white-space: nowrap;
}

.texts-on {
  color: #5fd18a;
}

.texts-off {
  color: var(--muted);
}
VICBLESS_EOF
cat > "$STAGE/6" <<'VICBLESS_EOF'
// MOCK admin data layer. Replace with calls to the real backend later. Shapes to keep:
//   signIn(password)        ->  POST   /admin/login
//   getDay(dateKey)         ->  GET    /admin/schedule?date=YYYY-MM-DD   { items, blocks } for that day
//   cancelBooking(item)     ->  DELETE /admin/bookings/{id}              (frees the time)
//   addBlock(block)         ->  POST   /admin/blocks                     (409 if it overlaps a booking or block)
//   removeBlock(id)         ->  DELETE /admin/blocks/{id}
//   getAdminSettings()      ->  GET    /admin/settings
//   saveSettings(body)      ->  PUT    /admin/settings
//   moveBooking(item, {dateKey, start})  ->  PATCH /admin/bookings/{id}   body { dateKey, start }
//                                         (409 if the time is taken; the booking comes back with a NEW id)
//
// For now it shows real bookings made through the site in this browser, plus sample bookings for the
// blocks the public mock marks as taken, so the schedule and the customer-facing time grid always
// agree. Sample ones are marked so they are never mistaken for real customers.

import { HOURS } from '../config.js'
import { getBusy } from '../lib/mockApi.js'
import { fromKey, slotStarts } from '../lib/availability.js'
import { fromApi, toApi } from '../lib/shopSettings.js'
import {
  blockedStartsFor,
  overlaps,
  readBlocks,
  readBookings,
  readCancelledSamples,
  readShopSettings,
  slotMinutesOn,
  writeBlocks,
  writeBookings,
  writeCancelledSamples,
  writeShopSettings,
} from '../lib/mockStore.js'
import { findConflicts } from './blocks.js'

const SESSION_KEY = 'vicbless.admin.session'
const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export function isSignedIn() {
  try {
    return localStorage.getItem(SESSION_KEY) === 'preview'
  } catch {
    return false
  }
}

export async function signIn(password) {
  await delay(300)
  if (!String(password ?? '').trim()) throw new Error('Please enter your password.')
  try {
    localStorage.setItem(SESSION_KEY, 'preview')
  } catch {
    /* storage blocked: the session just will not survive a reload */
  }
}

export function signOut() {
  try {
    localStorage.removeItem(SESSION_KEY)
  } catch {
    /* nothing to clear */
  }
}

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

const FIRST = ['Marcus', 'Dre', 'Tyrell', 'Jamal', 'Chris', 'Devon', 'Andre', 'Malik', 'Terrence', 'Jordan', 'Isaiah', 'Cameron']
const LAST = ['J.', 'W.', 'B.', 'H.', 'T.', 'R.', 'M.', 'G.']
const NOTES = ['Wants it shorter on the sides', 'Bringing his son next', 'Regular, same as last time', 'Beard line-up too if there is time']

function sampleItem(dateKey, start) {
  const h = hash(`${dateKey}|sample|${start}`)
  const services = readShopSettings().services
  const service = services[h % services.length]
  return {
    id: `sample-${dateKey}-${start}`,
    dateKey,
    source: 'sample',
    start,
    minutes: slotMinutesOn(dateKey),
    serviceId: service.id,
    serviceName: service.name,
    name: `${FIRST[h % FIRST.length]} ${LAST[(h >>> 4) % LAST.length]}`,
    phone: `(555) 010-${String(100 + (h % 90)).padStart(4, '0').slice(-4)}`,
    // about two in three sample customers left an email, so the layout can be seen with and without
    email: h % 3 === 0 ? '' : `${FIRST[h % FIRST.length].toLowerCase()}${h % 97}@example.com`,
    notes: h % 4 === 0 ? NOTES[(h >>> 8) % NOTES.length] : '',
    // about half of the sample customers agreed to texts
    smsConsent: (h >>> 3) % 2 === 0,
    code: 'VB-SAMPLE',
  }
}

export async function getDay(dateKey) {
  const busyByDay = await getBusy([dateKey])
  const busy = busyByDay[dateKey] || []
  const real = readBookings().filter((b) => b.dateKey === dateKey)

  const items = real.map((b) => ({
    id: b.code,
    dateKey,
    source: 'online',
    start: b.start,
    minutes: b.minutes,
    serviceId: b.serviceId,
    serviceName: b.serviceName || '',
    name: b.name,
    phone: b.phone,
    email: b.email || '',
    notes: b.notes || '',
    smsConsent: b.smsConsent === true,
    code: b.code,
  }))

  // real bookings and blocked time are never shown as sample bookings
  const slot = slotMinutesOn(dateKey)
  const covered = new Set(blockedStartsFor(dateKey))
  for (const start of busy) {
    if (real.some((b) => overlaps(start, start + slot, b.start, b.start + b.minutes))) covered.add(start)
  }
  for (const start of [...busy].sort((a, b) => a - b)) {
    if (!covered.has(start)) items.push(sampleItem(dateKey, start))
  }
  items.sort((a, b) => a.start - b.start)

  const blocks = readBlocks()
    .filter((b) => b.dateKey === dateKey)
    .sort((a, b) => a.start - b.start)

  return { dateKey, items, blocks }
}

// Frees the time. A real booking is removed; a sample one is remembered as cancelled.
export async function cancelBooking(item) {
  await delay(250)
  if (item.source === 'online') {
    writeBookings(readBookings().filter((b) => !(b.code === item.id && b.dateKey === item.dateKey && b.start === item.start)))
  } else {
    const list = readCancelledSamples()
    if (!list.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
      writeCancelledSamples([...list, { dateKey: item.dateKey, start: item.start }])
    }
  }
}

// The "backend" has the final say: it refuses a block that overlaps a booking or other blocked time,
// even if the screen did not catch it (for example when something changed a moment ago).
export async function addBlock({ dateKey, start, end, note = '', whole = false }) {
  await delay(250)
  const day = await getDay(dateKey)
  const slot = slotMinutesOn(dateKey)
  const grid = slotStarts(fromKey(dateKey), HOURS, slot)
  const conflicts = findConflicts({ range: { start, end }, grid, items: day.items, blocks: day.blocks, slotMinutes: slot })
  if (conflicts.bookings.length > 0 || conflicts.blocks.length > 0) {
    const error = new Error('That time overlaps a booking or blocked time.')
    error.code = 'CONFLICT'
    throw error
  }
  const block = {
    id: `blk-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    dateKey,
    start,
    end,
    note: String(note ?? '').trim().slice(0, 80),
    whole: !!whole,
  }
  writeBlocks([...readBlocks(), block])
  return block
}

export async function removeBlock(id) {
  await delay(150)
  writeBlocks(readBlocks().filter((b) => b.id !== id))
}

// Moves a booking to another day and time. The "backend" has the final say, like the real one will:
// it refuses a time that is not on the grid, or that is taken or blocked (except by this booking itself).
// A real booking keeps its code. A sample booking becomes a real one at the new time, and its old time is freed.
export async function moveBooking(item, { dateKey, start }) {
  await delay(300)
  // The booking takes the new day's appointment length, like the real backend.
  const slot = slotMinutesOn(dateKey)
  if (!slotStarts(fromKey(dateKey), HOURS, slot).includes(start)) {
    const error = new Error('That is not a time Vic works.')
    error.code = 'INVALID'
    throw error
  }

  const busy = new Set((await getBusy([dateKey]))[dateKey] || [])
  if (item.dateKey === dateKey) {
    // the appointment starts that only overlap this booking itself are not in its way
    for (const s of [...busy]) if (overlaps(s, s + slot, item.start, item.start + item.minutes)) busy.delete(s)
  }
  if (busy.has(start)) {
    const error = new Error('That time is taken.')
    error.code = 'CONFLICT'
    throw error
  }

  if (item.source === 'online') {
    writeBookings(
      readBookings().map((b) => (b.code === item.id && b.dateKey === item.dateKey && b.start === item.start ? { ...b, dateKey, start, minutes: slot } : b)),
    )
    return
  }

  // sample booking: free its old time, then make a real booking at the new one
  const cancelled = readCancelledSamples()
  if (!cancelled.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
    writeCancelledSamples([...cancelled, { dateKey: item.dateKey, start: item.start }])
  }
  const code = 'VB-' + Math.random().toString(36).slice(2, 7).toUpperCase()
  writeBookings([
    ...readBookings(),
    {
      staffId: 'vic',
      serviceId: item.serviceId,
      dateKey,
      start,
      minutes: slot,
      serviceName: item.serviceName || '',
      name: item.name,
      phone: item.phone,
      email: item.email,
      notes: item.notes,
      smsConsent: item.smsConsent === true,
      code,
    },
  ])
}

// The settings screen: read what is saved, and save a new version. Takes and gives the API's shape.
export async function getAdminSettings() {
  await delay(150)
  return toApi(readShopSettings())
}

export async function saveSettings(body) {
  await delay(300)
  const parsed = fromApi({
    // A new service has no id yet; the real backend makes one, so the mock does too.
    services: body.services.map((s) => ({ ...s, id: s.id || `svc-${Math.random().toString(16).slice(2, 8)}` })),
    slotMinutes: body.slotMinutes,
    reminderHours: body.reminderHours,
  })
  if (!parsed) throw new Error('Those settings are not valid.')
  const saved = toApi(parsed)
  writeShopSettings(saved)
  return saved
}
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
// Who is told when Vic cancels a booking: a text if the customer ticked the box, an email if they left one.
// This mirrors the backend, which texts only customers who agreed and emails only those who left an address.

export function whoIsTold(item) {
  return { text: item.smsConsent === true, email: Boolean(item.email && item.email.trim()) }
}

export function cancelMessage(item, timeLabel, serviceName) {
  const { text, email } = whoIsTold(item)
  const head = `Cancel ${item.name}'s ${timeLabel} ${serviceName}? The time opens up for other customers.`
  if (text && email) return `${head} They are sent a text and an email saying it was cancelled.`
  if (text) return `${head} They are sent a text saying it was cancelled.`
  if (email) return `${head} They are sent an email saying it was cancelled.`
  return `${head} They won't be told, because they didn't agree to texts or leave an email.`
}

// The short label beside the phone number. The mark and the words both say it, so colour is never the only clue.
export function textsLabel(item) {
  return item.smsConsent === true ? { mark: '✓', words: 'Texts OK', on: true } : { mark: '✗', words: 'No texts', on: false }
}
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { cancelMessage, textsLabel, whoIsTold } from './notify'

const base = { name: 'Rayner Codes', smsConsent: false, email: '' }
const msg = (o) => cancelMessage({ ...base, ...o }, '3:05 pm', "Men's haircut with design")

describe('cancel message', () => {
  it('says text and email when both apply', () => {
    expect(msg({ smsConsent: true, email: 'a@b.co' })).toContain('a text and an email')
  })
  it('says text only when they only agreed to texts', () => {
    const m = msg({ smsConsent: true })
    expect(m).toContain('a text saying')
    expect(m).not.toContain('email')
  })
  it('says email only when they only left an email', () => {
    const m = msg({ email: 'a@b.co' })
    expect(m).toContain('an email saying')
    expect(m).not.toContain('a text')
  })
  it('says nobody is told when neither applies', () => {
    expect(msg({})).toContain("won't be told")
    expect(msg({ email: '   ' })).toContain("won't be told")
  })
  it('always names the booking and frees the time', () => {
    expect(msg({})).toMatch(/^Cancel Rayner Codes's 3:05 pm Men's haircut with design\? The time opens up/)
  })
  it('only a true consent counts', () => {
    expect(whoIsTold({ smsConsent: 'yes', email: '' }).text).toBe(false)
    expect(whoIsTold({ email: 'x@y.co' }).email).toBe(true)
  })
})

describe('texts label', () => {
  it('has a mark and words either way', () => {
    expect(textsLabel({ smsConsent: true })).toEqual({ mark: '✓', words: 'Texts OK', on: true })
    expect(textsLabel({})).toEqual({ mark: '✗', words: 'No texts', on: false })
  })
})
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/app/domain/models.py\", \"base\": \"f72e5cf2bde2394dd49d8c41c08c30aa306e211267b9bc134fceee5f24cccfd8\", \"new\": 0}, {\"path\": \"backend/app/texting/templates.py\", \"base\": \"c7195a9cd9fe1265273fc1b9c4055cbdc28c69bcebbb3fbedceee3e792ff3661\", \"new\": 1}, {\"path\": \"backend/tests/test_admin_api.py\", \"base\": \"8c25335b41c6a0da7caf541245f9ce925eb5ed0ee441a5907b8db2bffed2b57e\", \"new\": 2}, {\"path\": \"backend/tests/test_texting.py\", \"base\": \"9169edc50b5c03eccbd36425c6066cd4dfb47513f36ab2717ea574aa14cc985a\", \"new\": 3}, {\"path\": \"frontend/src/admin/Schedule.jsx\", \"base\": \"2bf8539ee003d20102fa38d06222a74452bda021b0c852556329e26279accb47\", \"new\": 4}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"512f6507e71e3baf6d573dbb26b364078a2ced129ada593bf827786b67099ef1\", \"new\": 5}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"ffc9969f293724cc4ed8c0dd96bfc166a28529e2e5a99ffd3a77133326cd17ce\", \"new\": 6}, {\"path\": \"frontend/src/admin/notify.js\", \"base\": null, \"new\": 7}, {\"path\": \"frontend/src/admin/notify.test.js\", \"base\": null, \"new\": 8}]")

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
echo "Then: git add -A && git commit, push, and let the deploy run (backend and frontend both change)."
