"""Talks to Stripe with the standard library only, so it adds nothing to the Lambda package.

API: https://stripe.com/docs/api. Requests are form-encoded POSTs with the secret key as a Bearer token.
The key is never logged. Neither is anything about the customer: only Stripe's ids and short error codes.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from ..core.logs import log
from . import CheckoutSession, PaymentError, SessionStatus

API = "https://api.stripe.com/v1"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 8


def _flatten(fields: dict, prefix: str = "") -> list[tuple[str, str]]:
    """{'a': {'b': 1}, 'c': [{'d': 2}]} -> [('a[b]', '1'), ('c[0][d]', '2')]: how Stripe wants nested fields."""
    out: list[tuple[str, str]] = []
    for name, value in fields.items():
        key = f"{prefix}[{name}]" if prefix else str(name)
        if isinstance(value, dict):
            out += _flatten(value, key)
        elif isinstance(value, (list, tuple)):
            out += _flatten({str(i): v for i, v in enumerate(value)}, key)
        elif value is not None:
            out.append((key, str(value)))
    return out


class StripeClient:
    def __init__(self, secret_key: str):
        self.secret_key = secret_key

    def _call(self, method: str, path: str, fields: dict | None = None, idempotency_key: str = "") -> dict:
        headers = {"Authorization": f"Bearer {self.secret_key}", "User-Agent": USER_AGENT}
        data = None
        if method == "POST":
            data = urllib.parse.urlencode(_flatten(fields or {})).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            if idempotency_key:
                headers["Idempotency-Key"] = idempotency_key  # the same request twice makes ONE session or refund
        request = urllib.request.Request(f"{API}{path}", data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                answer = json.loads(response.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            code = ""
            try:
                code = str(json.loads(err.read().decode()).get("error", {}).get("code") or "")[:80]
            except Exception:  # noqa: BLE001 - an unreadable error body is fine, the status is enough
                pass
            log("stripe_failed", path=path.split("/")[1], status=err.code, code=code)
            raise PaymentError(f"Stripe answered {err.code}", code) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            log("stripe_failed", path=path.split("/")[1], reason=type(err).__name__)
            raise PaymentError("Could not reach Stripe") from None
        if not isinstance(answer, dict):
            raise PaymentError("Stripe sent something unexpected")
        return answer

    def create_checkout_session(
        self, *, booking_id: str, code: str, amount_cents: int, product_name: str, success_url: str, cancel_url: str,
        expires_at: int, customer_email: str = "",
    ) -> CheckoutSession:  # fmt: skip
        """A payment page for one booking. `expires_at` (Unix time) must be 30 minutes to 24 hours from now."""
        answer = self._call(
            "POST",
            "/checkout/sessions",
            {
                "mode": "payment",
                "success_url": success_url,
                "cancel_url": cancel_url,
                "expires_at": expires_at,
                "customer_email": customer_email or None,
                "client_reference_id": code,
                "metadata": {"bookingId": booking_id, "code": code},
                "payment_intent_data": {"metadata": {"bookingId": booking_id, "code": code}},
                "line_items": [
                    {
                        "quantity": 1,
                        "price_data": {"currency": "usd", "unit_amount": amount_cents, "product_data": {"name": product_name}},
                    }
                ],
            },
            idempotency_key=f"checkout-{booking_id}",
        )
        if not answer.get("id") or not answer.get("url"):
            raise PaymentError("Stripe did not return a payment page")
        log("stripe_checkout_created", sessionId=str(answer["id"])[:80], amountCents=amount_cents)
        return CheckoutSession(id=str(answer["id"]), url=str(answer["url"]))

    def get_session(self, session_id: str) -> SessionStatus:
        answer = self._call("GET", f"/checkout/sessions/{urllib.parse.quote(session_id, safe='')}")
        return SessionStatus(
            id=str(answer.get("id", session_id)),
            status=str(answer.get("status", "")),
            paid=answer.get("payment_status") == "paid",
            payment_intent=str(answer.get("payment_intent") or ""),
        )

    def expire_session(self, session_id: str) -> None:
        """Closes an unpaid payment page so the customer can no longer pay it."""
        self._call("POST", f"/checkout/sessions/{urllib.parse.quote(session_id, safe='')}/expire")

    def refund(self, payment_intent: str, *, idempotency_key: str) -> None:
        """Gives the whole payment back to the customer's card."""
        self._call("POST", "/refunds", {"payment_intent": payment_intent}, idempotency_key=idempotency_key)
        log("stripe_refunded", paymentIntent=payment_intent[:80])
