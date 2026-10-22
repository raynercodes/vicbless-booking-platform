"""Paying online, in action: holding the time while a customer pays, confirming the payment, giving a time back, refunding.

The life of an online booking:
  1. the customer picks "pay online": the booking is made at once and its time is HELD (payment = "pending"), and they
     are sent to Stripe's payment page. Nobody is told about the booking yet.
  2. Stripe tells us the result with a signed webhook. Paid: the booking becomes "paid" and Vic and the customer are told.
     Expired (they never paid): the booking is removed and the time is free again.
  3. a sweep every 15 minutes (the same schedule as the reminders) frees any hold whose webhook never arrived. Before it
     does, it asks Stripe, so a payment that did go through is confirmed instead of lost.
A booking Vic cancels after it was paid is refunded first. If the refund fails, nothing is cancelled.
"""

from __future__ import annotations

import re
import time
from dataclasses import replace
from datetime import datetime, timedelta, timezone

from .. import payments as stripe_payments
from ..core import config
from ..core.brand import BRAND_NAME
from ..core.errors import BadWebhook, NotConfigured, NotFound, PaymentUnavailable, RefundFailed
from ..core.logs import log
from ..database import bookings as bookings_db
from ..domain.models import Booking
from ..payments import PaymentError, webhook
from . import notifications

# How long a customer's time is held while they pay. Short on purpose: a customer who wanders off must not keep a
# time from someone who would book it. Stripe will not make a payment page expire in under 30 minutes, so when the hold
# ends WE close the page (release below) instead of waiting for Stripe's own expiry.
HOLD_MINUTES = 10
STRIPE_MIN_PAGE_MINUTES = 31  # the shortest life Stripe allows for a payment page is 30 minutes


def available() -> bool:
    """Can customers pay online right now? (Both Stripe secrets are set up.)"""
    return stripe_payments.configured()


def iso_utc(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hold_until(now: datetime) -> str:
    """When a time that is waiting for payment stops being held."""
    return iso_utc(now + timedelta(minutes=HOLD_MINUTES))


def hold_is_over(booking: Booking, now: datetime) -> bool:
    return not booking.hold_until or booking.hold_until <= iso_utc(now)


_ORIGIN_SHAPE = re.compile(r"^https?://[A-Za-z0-9.-]+(:\d+)?$")


def _return_origin(return_to: str | None) -> str:
    """Where Stripe sends the customer back to: the site they came from, but only if it is one of our own addresses.
    (Otherwise a made-up address would turn Stripe's page into a link to anywhere.) Dev allows any site, like its CORS does."""
    allowed = config.get_settings().cors_origins
    clean = (return_to or "").rstrip("/")
    if clean and _ORIGIN_SHAPE.match(clean) and ("*" in allowed or clean in allowed):
        return clean
    real = [o for o in allowed if o != "*"]
    if real:
        return real[0]
    raise PaymentUnavailable()


def start_checkout(booking: Booking, return_to: str | None) -> Booking:
    """Gets the payment page for a booking that is waiting for payment, and remembers it. If Stripe can't, the held time
    is given back and the customer is told to pay at the shop instead."""
    client = stripe_payments.get_client()
    try:
        if client is None:
            raise PaymentError("online payment is not set up")
        origin = _return_origin(return_to)
        expires = datetime.now(timezone.utc) + timedelta(minutes=STRIPE_MIN_PAGE_MINUTES)  # Stripe checks the real clock
        session = client.create_checkout_session(
            booking_id=booking.id,
            code=booking.code,
            amount_cents=booking.amount_cents,
            product_name=f"{booking.service_name or 'Appointment'} at {BRAND_NAME.title()}",
            success_url=f"{origin}/#/book?paid={booking.code}",
            cancel_url=f"{origin}/#/book?payment=cancelled",
            expires_at=int(expires.timestamp()),
            customer_email=booking.email,
        )
        bookings_db.attach_checkout(booking, session.id, session.url)
    except (PaymentError, PaymentUnavailable) as err:
        log("payment_checkout_failed", bookingId=booking.id, reason=type(err).__name__)
        try:
            bookings_db.cancel_booking(booking.id)  # the customer never got to pay, so the time goes back
        except Exception as undo:  # noqa: BLE001 - the sweep will find the hold and free it
            log("payment_release_failed", bookingId=booking.id, reason=type(undo).__name__)
        raise PaymentUnavailable() from None
    log("payment_checkout_created", bookingId=booking.id, amountCents=booking.amount_cents)
    return replace(booking, checkout_id=session.id, checkout_url=session.url)


def confirm(booking_id: str, payment_intent: str) -> bool:
    """A payment arrived. Marks the booking paid and tells Vic and the customer. True if this call did it, False if it
    was already confirmed. A payment for a booking that no longer exists (its time was given back) is refunded."""
    booking = bookings_db.get_booking(booking_id)
    if booking is None:
        log("payment_orphaned", bookingId=booking_id)
        client = stripe_payments.get_client()
        if client and payment_intent:
            client.refund(payment_intent, idempotency_key=f"orphan-{payment_intent}")  # raises: Stripe will send it again
            log("payment_orphan_refunded", bookingId=booking_id)
        return False
    if not bookings_db.mark_paid(booking, payment_intent):
        log("payment_already_confirmed", bookingId=booking_id)
        return False
    log("payment_confirmed", bookingId=booking_id, amountCents=booking.amount_cents)
    notifications.booking_created(replace(booking, payment="paid", payment_intent=payment_intent, hold_until="", checkout_url=""))
    return True


def release(booking: Booking) -> str:
    """Gives up an unpaid booking and frees its time. Returns:
      "released"  it is gone and the time is free
      "paid"      Stripe says it WAS paid after all, so it is now confirmed instead
      "gone"      it no longer existed
      "kept"      Stripe could not be asked, so nothing was changed (the sweep tries again later)
    """
    client = stripe_payments.get_client()
    if client is not None and booking.checkout_id:
        try:
            status = client.get_session(booking.checkout_id)
            if status.status == "complete" and status.paid:
                confirm(booking.id, status.payment_intent)
                return "paid"
            if status.status == "open":
                client.expire_session(booking.checkout_id)  # from here on the customer can no longer pay it
        except PaymentError:
            return "kept"
    try:
        bookings_db.cancel_booking(booking.id)
    except NotFound:
        return "gone"
    log("payment_hold_released", bookingId=booking.id)
    return "released"


def refund(booking: Booking) -> None:
    """Gives a paid booking's money back. Raises RefundFailed if the card could not be refunded."""
    client = stripe_payments.get_client()
    if client is None or not booking.payment_intent:
        log("refund_failed", bookingId=booking.id, reason="no_payment_to_refund")
        raise RefundFailed()
    try:
        client.refund(booking.payment_intent, idempotency_key=f"refund-{booking.code}")
    except PaymentError as err:
        if err.code == "charge_already_refunded":
            log("refund_already_done", bookingId=booking.id)  # Vic already refunded it in Stripe
            return
        log("refund_failed", bookingId=booking.id, reason=err.code or "stripe_error")
        raise RefundFailed() from None
    log("payment_refunded", bookingId=booking.id, amountCents=booking.amount_cents)


def handle_webhook(payload: bytes, signature: str, now: float | None = None) -> str:
    """One message from Stripe. Returns what was done (for the log). Raises BadWebhook for a message that isn't Stripe's."""
    secret = stripe_payments.webhook_secret()
    if not secret:
        raise NotConfigured()
    try:
        event = webhook.verify(payload, signature, secret, now if now is not None else time.time())
    except PaymentError as err:
        log("webhook_rejected", reason=str(err)[:80])
        raise BadWebhook() from None
    kind = str(event.get("type", ""))
    session = (event.get("data") or {}).get("object") or {}
    booking_id = str((session.get("metadata") or {}).get("bookingId", ""))
    if kind in ("checkout.session.completed", "checkout.session.async_payment_succeeded"):
        if session.get("payment_status") != "paid":
            outcome = "ignored_not_paid"  # a delayed payment method: its own "async_payment_succeeded" comes later
        else:
            outcome = "confirmed" if confirm(booking_id, str(session.get("payment_intent") or "")) else "already_handled"
    elif kind == "checkout.session.expired":
        booking = bookings_db.get_booking(booking_id) if booking_id else None
        if booking is not None and booking.payment == "pending":
            bookings_db.cancel_booking(booking.id)
            log("payment_hold_released", bookingId=booking.id)
            outcome = "released"
        else:
            outcome = "already_handled"
    else:
        outcome = "ignored"
    log("webhook_handled", type=kind, outcome=outcome)
    return outcome


def release_expired(now: datetime) -> int:
    """Gives back the time of every unpaid booking whose hold has ended. Returns how many.

    Runs on the 15 minute schedule, and also whenever anyone looks at the times or books one, so a time is free again
    the minute its hold ends, not up to 15 minutes later. Each is closed on Stripe's side first, and if Stripe says it was
    paid after all, it is confirmed instead of released.
    """
    freed = 0
    for booking_id, until in bookings_db.holds_ending_before(iso_utc(now)):
        try:
            booking = bookings_db.get_booking(booking_id)
            if booking is None or booking.payment != "pending":
                bookings_db.forget_hold(booking_id, until)  # a marker nothing needs any more
            elif release(booking) == "released":
                freed += 1
        except Exception as exc:  # noqa: BLE001 - one stuck hold must not stop the others
            log("hold_sweep_error", bookingId=booking_id, reason=type(exc).__name__)
    if freed:
        log("holds_released", count=freed)
    return freed


def release_expired_quietly(now: datetime) -> None:
    """release_expired for callers that must never fail because of it (the booking page's time grid)."""
    try:
        release_expired(now)
    except Exception as exc:  # noqa: BLE001
        log("hold_sweep_error", reason=type(exc).__name__)
