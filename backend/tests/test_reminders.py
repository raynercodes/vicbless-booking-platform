"""Reminders: which ones go out when, never twice, never late, and what Vic can change."""

from datetime import date, datetime

import pytest

from app.database import bookings as bookings_db
from app.database import keys
from app.domain import shop
from app.services import notifications, reminders
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import raw_table
from tests.helpers.builders import make_booking
from tests.helpers.constants import TUESDAY

TUE = date(2026, 10, 13)  # the appointment day; 12:00 pm is 28 hours after the tests' "now" (Mon 10:00 am)


def ny(day: int, hour: int, minute: int = 0) -> datetime:
    """A moment in October 2026, in the shop's timezone."""
    return datetime(2026, 10, day, hour, minute, tzinfo=shop.TIMEZONE)


def appointment(updated=None, **over):
    """A booking Tuesday 12:00 pm. `updated` is when it was made, in the shop's timezone (long ago unless given)."""
    over.setdefault("email", "m@example.com")
    over.setdefault("sms_consent", True)
    b = make_booking(start=720, day=TUE, **over)
    stamp = (updated or ny(1, 9)).isoformat()
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(b.day, b.start, b.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": stamp},
    )
    return bookings_db.get_booking(b.id)


@pytest.fixture
def outbox(sent, texts):
    """Everything sent: emails in `.emails`, texts in `.texts`."""

    class Box:
        emails = sent
        texts_ = texts

    return Box


def count(box):
    return len(box.emails), len(box.texts_)


def test_nothing_is_due_a_day_and_a_half_ahead(outbox):
    appointment()
    assert reminders.send_due(ny(12, 10)) == {"sent": 0, "errors": 0}  # 26 hours before
    assert count(outbox) == (0, 0)


def test_the_24_hour_reminder_goes_out_by_email_and_text(outbox):
    appointment()
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 1  # a sweep 10 minutes after the 24 hour moment
    assert count(outbox) == (1, 1)
    assert "Reminder" in outbox.emails[0].subject and "Reminder" in outbox.texts_[0].body
    assert outbox.texts_[0].to == "5550101234"


def test_a_reminder_is_never_sent_twice(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert reminders.send_due(ny(12, 12, 25))["sent"] == 0
    assert reminders.send_due(ny(12, 18))["sent"] == 0
    assert count(outbox) == (1, 1)


def test_the_2_hour_reminder_follows_the_24_hour_one(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert reminders.send_due(ny(13, 10, 5))["sent"] == 1
    assert count(outbox) == (2, 2)


def test_two_sweeps_at_once_cannot_both_send(outbox, monkeypatch):
    b = appointment()
    from app.database import reminders as db

    assert db.claim(b, "24h") is True
    assert db.claim(b, "24h") is False
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 0  # it was already marked
    assert count(outbox) == (0, 0)


def test_a_reminder_for_a_time_already_passed_when_booked_is_skipped(outbox):
    appointment(updated=ny(12, 13))  # made Monday 1:00 pm: the 24 hour moment (Monday 12:00) was already over
    assert reminders.send_due(ny(12, 13, 15))["sent"] == 0
    assert reminders.send_due(ny(13, 10, 5))["sent"] == 1  # but the 2 hour one is still ahead
    assert count(outbox) == (1, 1)


def test_if_both_are_due_only_the_nearest_is_sent(outbox):
    b = appointment()
    assert reminders.send_due(ny(13, 10, 30))["sent"] == 1  # the sweep was down all night
    assert count(outbox) == (1, 1)
    assert set(bookings_db.get_booking(b.id).reminders_sent) == {"24h", "2h"}


def test_nothing_is_sent_once_the_appointment_has_started(outbox):
    appointment()
    assert reminders.send_due(ny(13, 12, 5))["sent"] == 0
    assert count(outbox) == (0, 0)


def test_only_the_channels_the_customer_chose_are_used(outbox):
    appointment(email="", sms_consent=True)
    appointment_two = make_booking(start=765, day=TUE, phone="5550102222", email="x@example.com", sms_consent=False)
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(appointment_two.day, appointment_two.start, appointment_two.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(1, 9).isoformat()},
    )
    assert reminders.send_due(ny(12, 12, 50))["sent"] == 2
    assert [m.to for m in outbox.texts_] == ["5550101234"]  # the second customer did not agree to texts
    assert [m.to for m in outbox.emails] == ["x@example.com"]  # the first left no email


def test_vic_is_not_sent_the_customers_reminder(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert all(m.to != "5550100777" for m in outbox.texts_) and all(m.to != "vic@example.com" for m in outbox.emails)


def test_a_cancelled_booking_gets_no_reminder(client, auth, outbox):
    book(client, smsConsent=True, email="a@example.com")
    item = schedule_of(client, auth)["items"][0]
    client.delete(f"/api/admin/bookings/{item['id']}", headers=auth)
    outbox.emails.clear()
    outbox.texts_.clear()
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 0 and count(outbox) == (0, 0)


def test_a_moved_booking_starts_over(client, auth, outbox):
    b = appointment()
    reminders.send_due(ny(12, 12, 10))
    assert "24h" in bookings_db.get_booking(b.id).reminders_sent
    r = client.patch(f"/api/admin/bookings/{b.id}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    assert r.status_code == 200
    moved = bookings_db.get_booking(r.json()["id"])
    assert moved.reminders_sent == () and moved.sms_consent is True and moved.code == b.code


def test_a_moved_booking_is_not_reminded_about_moments_before_the_move(client, auth, outbox):
    b = appointment()
    r = client.patch(f"/api/admin/bookings/{b.id}", headers=auth, json={"dateKey": "2026-10-13", "start": 755})
    assert r.status_code == 200, r.text
    new_id = r.json()["id"]
    raw_table().update_item(  # pretend the move happened Tuesday 8:30 am
        Key={"pk": keys.PK, "sk": keys.booking_sk(TUE, 755, new_id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(13, 8, 30).isoformat()},
    )
    outbox.emails.clear()
    outbox.texts_.clear()
    assert reminders.send_due(ny(13, 8, 40))["sent"] == 0  # the 24 hour moment was before the move
    assert reminders.send_due(ny(13, 10, 50))["sent"] == 1  # the 2 hour moment (12:35 - 2h = 10:35) has come
    assert count(outbox) == (1, 1)


def test_one_broken_booking_does_not_stop_the_others(outbox, monkeypatch):
    appointment()
    other = make_booking(start=765, day=TUE, phone="5550102222", email="x@example.com", sms_consent=False)
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(other.day, other.start, other.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(1, 9).isoformat()},
    )
    real = notifications.booking_reminder
    calls = []

    def flaky(booking):
        calls.append(booking.code)
        if len(calls) == 1:
            raise RuntimeError("boom")
        real(booking)

    monkeypatch.setattr(notifications, "booking_reminder", flaky)
    result = reminders.send_due(ny(12, 12, 50))
    assert result == {"sent": 1, "errors": 1}


# --- what Vic can change --------------------------------------------------------------------------------------


def put(client, auth, **extra):
    from tests.test_settings import settings_body

    return client.put("/api/admin/settings", headers=auth, json={**settings_body(), **extra})


def test_the_default_is_24_and_2_hours(client):
    assert client.get("/api/settings").json()["reminderHours"] == [24, 2]


def test_vic_can_choose_the_reminder_times(client, auth):
    assert put(client, auth, reminderHours=[2, 12, 4]).json()["reminderHours"] == [12, 4, 2]  # saved biggest first
    assert client.get("/api/settings").json()["reminderHours"] == [12, 4, 2]


def test_leaving_the_field_out_keeps_what_was_saved(client, auth):
    put(client, auth, reminderHours=[6])
    from tests.test_settings import settings_body

    assert client.put("/api/admin/settings", headers=auth, json=settings_body()).json()["reminderHours"] == [6]


@pytest.mark.parametrize("hours", [[5], [24, 24], [0], [-2], [100], ["24"]])
def test_only_listed_reminder_times_are_accepted(client, auth, hours):
    assert put(client, auth, reminderHours=hours).status_code == 422


def test_no_reminders_at_all_is_allowed_and_sends_nothing(client, auth, outbox):
    assert put(client, auth, reminderHours=[]).json()["reminderHours"] == []
    appointment()
    assert reminders.send_due(ny(13, 10, 30)) == {"sent": 0, "errors": 0}
    assert count(outbox) == (0, 0)


def test_a_new_reminder_time_takes_effect_at_once(client, auth, outbox):
    appointment()
    put(client, auth, reminderHours=[4])
    assert reminders.send_due(ny(13, 8, 5))["sent"] == 1  # 4 hours before 12:00
    assert count(outbox) == (1, 1)


def test_a_damaged_stored_reminder_list_falls_back_to_the_default(client):
    raw_table().put_item(Item={"pk": keys.PK, "sk": "SETTINGS", "reminderHours": ["soon", 5]})
    assert client.get("/api/settings").json()["reminderHours"] == [24, 2]


# --- the scheduled run ------------------------------------------------------------------------------------------


def test_a_scheduled_event_runs_the_sweep(monkeypatch):
    from app import handler

    monkeypatch.setattr(reminders, "send_due", lambda: {"sent": 3, "errors": 0})
    event = {"version": "0", "source": "aws.events", "detail-type": "Scheduled Event", "detail": {}}
    assert handler.lambda_handler(event, None) == {"sent": 3, "errors": 0}


def test_a_web_request_still_goes_to_the_api():
    from app.handler import lambda_handler
    from tests.test_handler import http_api_event

    assert lambda_handler(http_api_event("GET", "/api/health"), None)["statusCode"] == 200


def test_a_real_sweep_through_the_handler_with_nothing_to_do():
    from app.handler import lambda_handler

    assert lambda_handler({"source": "aws.events"}, None) == {"sent": 0, "errors": 0}
