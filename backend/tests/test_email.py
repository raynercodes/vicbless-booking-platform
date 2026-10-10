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
