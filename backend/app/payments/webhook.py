"""Checking that a message really came from Stripe.

Stripe signs every webhook: the `Stripe-Signature` header has a timestamp `t` and one or more signatures `v1`, each an
HMAC-SHA256 (keyed with the endpoint's signing secret) of "<t>.<raw body>". A message that fails the check, or whose
timestamp is more than five minutes old (a replay), is refused.
"""

from __future__ import annotations

import hashlib
import hmac
import json

from . import PaymentError

TOLERANCE_SECONDS = 300


def verify(payload: bytes, header: str, secret: str, now: float) -> dict:
    """Returns the event (a dict) when the signature is good; raises PaymentError otherwise."""
    timestamp = ""
    signatures: list[str] = []
    for part in (header or "").split(","):
        name, _, value = part.strip().partition("=")
        if name == "t":
            timestamp = value
        elif name == "v1":
            signatures.append(value)
    if not timestamp.isdigit() or not signatures:
        raise PaymentError("The signature header is missing or malformed")
    if abs(now - int(timestamp)) > TOLERANCE_SECONDS:
        raise PaymentError("The signature is too old")
    expected = hmac.new(secret.encode(), timestamp.encode() + b"." + payload, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(expected, s) for s in signatures):
        raise PaymentError("The signature does not match")
    try:
        event = json.loads(payload.decode())
    except ValueError:
        raise PaymentError("The body is not JSON") from None
    if not isinstance(event, dict):
        raise PaymentError("The body is not an event")
    return event
