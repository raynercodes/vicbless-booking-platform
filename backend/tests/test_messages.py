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
    assert r.status_code == 429 and "3 upcoming bookings" in message_of(r) and "call or text Vic" in message_of(r)


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
