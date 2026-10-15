"""The logs answer "what happened?" in CloudWatch, without ever containing what a customer typed."""

import pytest

from app.core import config
from app.services import notifications, reminders
from tests.fixtures.logs import events
from tests.fixtures.sms import OWNER_PHONE
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_body
from tests.helpers.constants import TUESDAY


def reasons(lines, event):
    return sorted((line["to"], line["kind"], line.get("reason")) for line in events(lines, event))


# --- who was texted, and why not ------------------------------------------------------------------------------


def test_a_text_that_goes_out_is_logged(client, texts, logged):
    book(client, smsConsent=True)
    sent = sorted((e["to"], e["kind"]) for e in events(logged, "sms_sent"))
    assert sent == [("customer", "confirmation"), ("owner", "new_booking")]
    assert events(logged, "sms_sent")[0]["provider"] == "Recorder"


def test_a_customer_who_did_not_agree_is_logged_as_no_consent(client, texts, logged):
    book(client)
    assert reasons(logged, "sms_skipped") == [("customer", "confirmation", "no_consent")]


def test_a_missing_owner_phone_is_logged(client, texts, logged):
    put_param("owner-phone", " ", secure=False)
    book(client, smsConsent=True)
    assert ("owner", "new_booking", "no_owner_phone") in reasons(logged, "sms_skipped")


def test_a_number_that_cannot_be_texted_is_logged(client, texts, logged):
    book(client, phone="+44 7700 900123", smsConsent=True)
    assert ("customer", "confirmation", "bad_number") in reasons(logged, "sms_skipped")


def test_no_key_at_all_explains_itself(client, logged):
    put_param("owner-phone", OWNER_PHONE, secure=False)
    book(client, smsConsent=True)
    assert events(logged, "sms_not_configured")  # nothing texted because there is no Textbelt key
    assert events(logged, "param_missing") and "textbelt-key" in {e["name"] for e in events(logged, "param_missing")}


def test_a_provider_that_fails_is_logged_as_an_error(client, logged, monkeypatch):
    from app.texting.textbelt import SmsSendError

    class Broken:
        def send(self, message):
            raise SmsSendError("down")

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Broken())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    assert book(client).status_code == 201
    error = events(logged, "sms_error")[0]
    assert error["kind"] == "new_booking" and error["reason"] == "SmsSendError" and error["provider"] == "Broken"


# --- emails -----------------------------------------------------------------------------------------------------


def test_emails_are_logged_like_texts(client, sent, logged):
    book(client, email="a@example.com")
    assert sorted((e["to"], e["kind"]) for e in events(logged, "email_sent")) == [("customer", "confirmation"), ("owner", "new_booking")]
    logged.clear()
    book(client, start=12 * 60 + 35, phone="5550106666")
    assert ("customer", "confirmation", "no_customer_email") in reasons(logged, "email_skipped")


# --- the story of a booking -----------------------------------------------------------------------------------


def test_a_booking_leaves_a_trail(client, auth, sent, texts, logged):
    assert book(client, smsConsent=True, email="a@example.com").status_code == 201
    created = events(logged, "booking_created")[0]
    assert created["smsConsent"] is True and created["hasEmail"] is True and created["minutes"] == 35
    assert created["bookingId"].startswith("2026-10-13.1200.")
    item = schedule_of(client, auth)["items"][0]
    client.patch(f"/api/admin/bookings/{item['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    moved = events(logged, "booking_moved")[0]
    assert moved["fromId"] == item["id"] and moved["toId"].startswith("2026-10-15.")
    client.delete(f"/api/admin/bookings/{moved['toId']}", headers=auth)
    assert events(logged, "booking_cancelled")[0]["bookingId"] == moved["toId"]


def test_a_refused_booking_says_why(client, logged):
    book(client)
    book(client, name="Other Person", phone="5550108888")
    assert any(e["reason"] == "slot_taken" for e in events(logged, "booking_refused"))
    codes = [e["code"] for e in events(logged, "api_error")]
    assert "slot_taken" in codes


def test_a_second_identical_request_is_logged_as_a_replay(client, logged):
    book(client)
    book(client)
    assert events(logged, "booking_replayed")


def test_a_validation_failure_names_the_field_but_not_the_value(client, logged):
    book(client, phone="123", name="Secret Person")
    failure = events(logged, "validation_failed")[0]
    assert failure["field"] == "phone"
    assert "Secret" not in str(logged) and "123" not in str([e for e in logged if e["event"] == "validation_failed"])


def test_blocks_and_settings_are_logged(client, auth, logged):
    from tests.test_settings import settings_body

    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": TUESDAY, "start": 720, "end": 780})
    client.delete(f"/api/admin/blocks/{r.json()['id']}", headers=auth)
    client.put("/api/admin/settings", headers=auth, json=settings_body())
    assert events(logged, "block_created")[0]["units"] == 12 and events(logged, "block_removed")
    saved = events(logged, "settings_saved")[0]
    assert saved["services"] == 5 and saved["reminderHours"] == [24, 2]


def test_a_rejected_dashboard_call_is_logged(client, auth, logged):  # `auth` sets up the sign-in secrets
    client.get("/api/admin/settings")
    client.get("/api/admin/settings", headers={"Authorization": "Bearer nonsense"})
    assert [e["reason"] for e in events(logged, "auth_rejected")] == ["no_token", "bad_or_expired_token"]


# --- reminders --------------------------------------------------------------------------------------------------


def test_the_sweep_reports_what_it_looked_at(sent, texts, logged):
    from tests.test_reminders import appointment, ny

    appointment()
    reminders.send_due(ny(12, 12, 10))
    sweep = events(logged, "reminders_swept")[0]
    assert sweep["examined"] == 1 and sweep["sent"] == 1 and sweep["reminderHours"] == [24, 2]
    sending = events(logged, "reminder_sending")[0]
    assert sending["tag"] == "24h" and sending["smsConsent"] is True


def test_a_skipped_reminder_says_why(sent, texts, logged):
    from tests.test_reminders import appointment, ny

    appointment(updated=ny(12, 13))
    reminders.send_due(ny(12, 13, 15))
    assert events(logged, "reminder_skipped")[0]["reason"] == "past_when_booked"


def test_the_scheduled_timer_is_logged(logged):
    from app.handler import lambda_handler

    lambda_handler({"source": "aws.events"}, None)
    assert events(logged, "scheduled_event")


# --- surprises ----------------------------------------------------------------------------------------------------


def test_an_unexpected_crash_logs_where_but_not_what(client, logged, monkeypatch):
    from app.services import bookings

    def boom(*args, **kwargs):
        raise RuntimeError("customer typed Secret Person 5550101234")

    monkeypatch.setattr(bookings, "create_booking", boom)
    from app.routes import public

    monkeypatch.setattr(public.bookings, "create_booking", boom)
    assert book(client).status_code == 500
    crash = events(logged, "unhandled_error")[0]
    assert crash["errorType"] == "RuntimeError" and any("boom" in f for f in crash["frames"])
    assert "Secret" not in str(logged) and "5550101234" not in str(logged)


def test_a_parameter_store_failure_is_logged(logged, monkeypatch):
    from app.core import aws

    class Denied:
        def get_parameter(self, **kwargs):
            from botocore.exceptions import ClientError

            raise ClientError({"Error": {"Code": "AccessDeniedException"}}, "GetParameter")

    monkeypatch.setattr(aws, "ssm_client", lambda: Denied())
    config.params.reset()
    with pytest.raises(Exception):
        config.params.get("textbelt-key")
    error = events(logged, "param_error")[0]
    assert error["name"] == "textbelt-key" and error["code"] == "AccessDeniedException"
