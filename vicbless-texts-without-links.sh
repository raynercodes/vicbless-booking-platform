#!/usr/bin/env bash
# Vicbless: texts without email addresses (Textbelt blocks links)
# Run from the REPO ROOT:  bash vicbless-texts-without-links.sh
#
# Textbelt refused the confirmation text because 'vicslegacy89@gmail.com' looks like a link to an unverified account.
# Texts now say 'email Vic (his address is on our site)', anything a customer typed that looks like a link is defused,
# and Textbelt's full refusal reason is logged. Needs the more-logging installer applied first.
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


def owner_new_booking(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: New booking. {_line(booking.name, 40)}, {_line(_service(booking), 50)}, {_when(booking)}. "
        f"Phone {booking.phone}. Code {booking.code}."
    )


def customer_confirmation(booking: Booking) -> str:
    first = _line(booking.name.split()[0] if booking.name.split() else "", 20)
    return (
        f"{BRAND_NAME}: You're booked, {first}. {_when(booking)} with Vic. Code {booking.code}. Pay at the shop. "
        f"{EMAIL_HINT} {OPT_OUT}"
    )


def customer_cancellation(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: Your appointment on {_when(booking)} was cancelled. You can book a new time anytime on our site. "
        f"{OPT_OUT}"
    )


def customer_rescheduled(before: Booking, after: Booking) -> str:
    return (
        f"{BRAND_NAME}: Your appointment moved to {_when(after)} (it was {_when(before)}). Code {after.code}. "
        f"Questions? Email Vic (his address is on our site). {OPT_OUT}"
    )


def customer_reminder(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: Reminder, you're booked {_when(booking)} at {ADDRESS_LINES[0]}. Code {booking.code}. "
        f"Need to change it? Email Vic (his address is on our site). {OPT_OUT}"
    )
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
"""Textbelt bridge. Delete this file when the AWS SMS account is approved (see texting/__init__.py).

Uses only the standard library, so it adds nothing to the Lambda package.
API: POST https://textbelt.com/text  (docs.textbelt.com), form fields: phone, message, key, sender.
Answer: JSON { success, quotaRemaining, textId } or { success: false, error }.
Textbelt answers STOP replies by itself. The `sender` field names the business, which their rules ask for.
The key is the Textbelt key bought for Vic, kept in Parameter Store (/vicbless/<env>/textbelt-key). The special key
"textbelt" is Textbelt's free test key (about one text a day for everyone), good only to check that it is wired up.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from ..core.brand import BRAND_NAME
from ..core.logs import log
from . import SmsMessage

API_URL = "https://textbelt.com/text"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 5


class SmsSendError(Exception):
    """Raised when Textbelt could not deliver. The caller (services/notifications.py) logs it and carries on."""

    pass


class TextbeltSender:
    def __init__(self, api_key: str):
        self.api_key = api_key

    def _request(self, message: SmsMessage) -> urllib.request.Request:
        """The full HTTP request. The key goes only in the form body, and neither it nor the number is ever logged."""
        form = urllib.parse.urlencode(
            {"phone": message.to, "message": message.body, "key": self.api_key, "sender": BRAND_NAME.title()}
        )
        return urllib.request.Request(
            API_URL,
            data=form.encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT},
        )

    def send(self, message: SmsMessage) -> None:
        """Send one text. Raises SmsSendError when Textbelt refuses it or cannot be reached."""
        try:
            with urllib.request.urlopen(self._request(message), timeout=TIMEOUT_SECONDS) as response:
                answer = json.loads(response.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            log("sms_failed", provider="textbelt", status=err.code)
            raise SmsSendError(f"Textbelt answered {err.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            log("sms_failed", provider="textbelt", reason=type(err).__name__)
            raise SmsSendError("Could not reach Textbelt") from None
        if not isinstance(answer, dict) or not answer.get("success"):
            # Textbelt's own reason ("Out of quota", "Invalid phone number") is safe to log: it has no personal details.
            reason = str(answer.get("error", "unknown"))[:200] if isinstance(answer, dict) else "unknown"
            log("sms_failed", provider="textbelt", reason=reason)
            raise SmsSendError("Textbelt refused the text")
        remaining = answer.get("quotaRemaining")
        log("sms_accepted", provider="textbelt", textId=str(answer.get("textId", ""))[:40], quotaRemaining=remaining)
        if isinstance(remaining, (int, float)) and remaining <= 10:
            log("sms_quota_low", provider="textbelt", remaining=remaining)  # a nudge in the logs to buy more credit
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
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
        assert body.startswith("VICBLESS BARBERSHOP:") and body.endswith("Reply STOP to opt out.")
        assert "\n" not in body and len(body) < 300


def test_the_texts_have_the_details_a_customer_needs():
    b = booking_model()
    assert "Tue, Oct 13 at 12:00 pm" in templates.customer_confirmation(b) and "VB-ABC234" in templates.customer_confirmation(b)
    assert "Marcus" in templates.customer_confirmation(b)
    moved = templates.customer_rescheduled(b, booking_model(start=765))
    assert "12:45 pm" in moved and "was Tue, Oct 13 at 12:00 pm" in moved.replace("it was", "was")
    assert "656 S Main St" in templates.customer_reminder(b)


def test_the_owner_text_has_no_opt_out_and_shows_the_phone():
    body = templates.owner_new_booking(booking_model())
    assert "STOP" not in body and "5550101234" in body and "Marcus Jones" in body and "Men's haircut" in body


def test_what_a_customer_typed_cannot_break_a_text_into_lines():
    b = booking_model(name="Mal\nlory\r\n" + "x" * 80, service_name="Cut\x00\x07 and" + "y" * 100)
    body = templates.owner_new_booking(b)
    assert "\n" not in body and "\x00" not in body and "x" * 41 not in body and "y" * 51 not in body


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
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/app/texting/templates.py\", \"base\": \"5be36e6ee026fdab9c2f72d32c4664640a7ea77796dc5d6d16a0d269c45d5b8d\", \"new\": 0}, {\"path\": \"backend/app/texting/textbelt.py\", \"base\": \"f833edd306edb848c64709b98764098680406a4c6c4b6888635986e62651ea43\", \"new\": 1}, {\"path\": \"backend/tests/test_texting.py\", \"base\": \"92f4340abd0cc605428f3f713957a3bfc1c84fc31387dcb6a36b9e82aa68c18e\", \"new\": 2}]")

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
echo "Next: commit, push to dev, book again with the text box ticked."
