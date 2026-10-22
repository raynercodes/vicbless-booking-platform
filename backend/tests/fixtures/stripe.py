"""A fake Stripe for the tests: the same questions and answers as the real API, nothing sent over the network."""

import hashlib
import hmac
import io
import json
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

from tests.helpers.aws import put_param

SECRET_KEY = "sk_test_secret"
WEBHOOK_SECRET = "whsec_test"
SITE = "https://vicbless.com"


class FakeStripe:
    """Holds the payment pages ("sessions") it has made. Tests change `fail` / `refund_error` to make Stripe misbehave."""

    def __init__(self):
        self.sessions: dict[str, dict] = {}
        self.calls: list[tuple[str, str, dict, dict]] = []  # (method, path, form, headers)
        self.refunds: list[dict] = []
        self.fail: set[str] = set()  # "create", "get", "expire", "refund": that call answers with an error
        self.refund_error: str = ""  # Stripe's code for a refused refund

    def _error(self, url, status, code=""):
        body = io.BytesIO(json.dumps({"error": {"code": code}}).encode())
        return urllib.error.HTTPError(url, status, "error", {}, body)

    def handle(self, request):
        path = request.full_url.removeprefix("https://api.stripe.com/v1")
        form = {k: v[0] for k, v in urllib.parse.parse_qs((request.data or b"").decode()).items()}
        headers = {k.lower(): v for k, v in request.header_items()}
        self.calls.append((request.get_method(), path, form, headers))
        if request.get_method() == "POST" and path == "/checkout/sessions":
            if "create" in self.fail:
                raise self._error(request.full_url, 500)
            sid = f"cs_test_{len(self.sessions) + 1}"
            self.sessions[sid] = {
                "id": sid, "url": f"https://checkout.stripe.test/c/{sid}", "status": "open", "payment_status": "unpaid",
                "payment_intent": f"pi_{sid}", "form": form,
            }  # fmt: skip
            return {"id": sid, "url": self.sessions[sid]["url"]}
        if path.startswith("/checkout/sessions/") and path.endswith("/expire"):
            sid = path.split("/")[3]
            if "expire" in self.fail or self.sessions[sid]["status"] != "open":
                raise self._error(request.full_url, 400, "checkout_session_not_open")
            self.sessions[sid]["status"] = "expired"
            return {"id": sid, "status": "expired"}
        if request.get_method() == "GET" and path.startswith("/checkout/sessions/"):
            if "get" in self.fail:
                raise self._error(request.full_url, 500)
            return self.sessions[path.split("/")[3]]
        if path == "/refunds":
            if "refund" in self.fail or self.refund_error:
                raise self._error(request.full_url, 400, self.refund_error)
            self.refunds.append({"form": form, "headers": headers})
            return {"id": "re_1"}
        raise AssertionError(f"unexpected Stripe call: {request.get_method()} {path}")

    def pay(self, session_id: str):
        """The customer pays that payment page."""
        self.sessions[session_id].update(status="complete", payment_status="paid")


@pytest.fixture
def stripe(monkeypatch):
    """Online payment switched on (keys in the fake Parameter Store) and a fake Stripe to talk to."""
    fake = FakeStripe()

    class Response:
        def __init__(self, answer):
            self.answer = answer

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return json.dumps(self.answer).encode()

    monkeypatch.setattr(urllib.request, "urlopen", lambda request, timeout=None: Response(fake.handle(request)))
    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", f"{SITE}, https://www.vicbless.com")
    put_param("stripe-secret-key", SECRET_KEY)
    put_param("stripe-webhook-secret", WEBHOOK_SECRET)
    return fake


def signed(event: dict, *, secret: str = WEBHOOK_SECRET, at: float | None = None) -> tuple[bytes, dict]:
    """(body, headers) of a webhook the way Stripe sends it."""
    body = json.dumps(event).encode()
    stamp = str(int(at if at is not None else time.time()))
    digest = hmac.new(secret.encode(), stamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    return body, {"stripe-signature": f"t={stamp},v1={digest}", "content-type": "application/json"}


def session_event(kind: str, session: dict, booking_id: str, *, paid: bool | None = None) -> dict:
    """A Stripe event about a payment page. `paid` defaults to what the fake says."""
    is_paid = session["payment_status"] == "paid" if paid is None else paid
    return {
        "id": "evt_1",
        "type": kind,
        "data": {
            "object": {
                "id": session["id"],
                "payment_status": "paid" if is_paid else "unpaid",
                "payment_intent": session["payment_intent"],
                "metadata": {"bookingId": booking_id},
            }
        },
    }
