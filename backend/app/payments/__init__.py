"""Taking card payments online. The rest of the app only knows about this module's functions and PaymentError.

The provider is Stripe Checkout: the customer is sent to a payment page Stripe hosts, so card numbers never touch this
app. Stripe tells us the result with a signed message (a webhook, see payments/webhook.py).

Two secrets live in Parameter Store (/vicbless/<env>/): `stripe-secret-key` and `stripe-webhook-secret`. Until the key is
set, "pay online" simply is not offered and every booking is paid at the shop.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..core import config
from ..core.logs import log


class PaymentError(Exception):
    """Stripe refused, or could not be reached. `code` is Stripe's own short reason (never a card detail) when it gave one."""

    def __init__(self, message: str, code: str = ""):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class CheckoutSession:
    id: str
    url: str


@dataclass(frozen=True)
class SessionStatus:
    """What Stripe says about a Checkout Session: status is 'open', 'complete' or 'expired'."""

    id: str
    status: str
    paid: bool
    payment_intent: str


def secret_key() -> str | None:
    return config.params.get("stripe-secret-key") or None


def webhook_secret() -> str | None:
    return config.params.get("stripe-webhook-secret") or None


def configured() -> bool:
    """Is online payment set up? False when the key is missing, or the parameter store could not be read."""
    try:
        return bool(secret_key() and webhook_secret())
    except Exception as exc:  # a health check of the setup must never break the booking page
        log("payments_setup_failed", reason=type(exc).__name__)
        return False


def get_client():
    """The Stripe client, or None when no key is set up."""
    from .stripe import StripeClient

    key = secret_key()
    return StripeClient(secret_key=key) if key else None
