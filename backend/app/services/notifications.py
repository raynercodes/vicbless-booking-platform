"""Sends the emails and texts around a booking. Best effort: a failed one is logged and never fails the booking.

Vic is texted at his own number (the `owner-phone` setting) about new bookings. A customer is texted only if they ticked
"text me" when booking, and emailed only if they left an email address.

Every message that is considered leaves ONE line in the logs, so "why did nobody get a text?" can be answered in CloudWatch:
  email_sent / sms_sent       it went to the provider and the provider accepted it (to=owner or customer, kind=what for)
  email_skipped / sms_skipped it was not sent, and reason says why (no_owner_phone, no_consent, bad_number, ...)
  email_error / sms_error     the provider refused it or could not be reached
Names, phone numbers and email addresses are never logged.
"""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates
from ..texting import SmsMessage, us_number
from ..texting import get_sender as get_sms_sender
from ..texting import templates as sms_templates


class Skip(Exception):
    """Raised by a builder that has nothing to send. `reason` is what is written to the log."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _send_all(items) -> None:
    """Builds and sends each email on its own. `items` are (kind, to, builder); a builder gets Vic's address and returns the
    message, or raises Skip(reason). One failing never stops the others, and none can fail the booking."""
    try:
        owner = config.params.get("owner-email") or ""
        sender = get_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("email_setup_failed", reason=type(exc).__name__)
        return
    provider = type(sender).__name__
    for kind, to, build in items:
        try:
            message: EmailMessage = build(owner)
            sender.send(message)
            log("email_sent", kind=kind, to=to, provider=provider)
        except Skip as skip:
            log("email_skipped", kind=kind, to=to, reason=skip.reason)
        except Exception as exc:
            log("email_error", kind=kind, to=to, provider=provider, reason=type(exc).__name__)


def _need_owner(owner: str) -> str:
    if not owner:
        raise Skip("no_owner_email")
    return owner


def _need_email(booking: Booking) -> None:
    if not booking.email:
        raise Skip("no_customer_email")


def booking_created(booking: Booking) -> None:
    """Vic always hears about a new booking; the customer gets a confirmation only if they left an email."""
    _send_all(
        [
            ("new_booking", "owner", lambda owner: templates.owner_notification(booking, _need_owner(owner))),
            ("confirmation", "customer", lambda owner: (_need_email(booking), templates.customer_confirmation(booking, owner))[1]),
        ]
    )
    texts_for_created(booking)


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (by email and/or text, whichever they chose)."""
    _send_all([("cancellation", "customer", lambda owner: (_need_email(booking), templates.customer_cancellation(booking, owner))[1])])
    texts_for_cancelled(booking)


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (by email and/or text, whichever they chose)."""
    _send_all([("rescheduled", "customer", lambda owner: (_need_email(after), templates.customer_rescheduled(before, after, owner))[1])])
    texts_for_moved(before, after)


def _send_texts(items) -> None:
    """Builds and sends each text on its own. `items` are (kind, to, builder); a builder gets Vic's number and returns
    (number, text), or raises Skip(reason)."""
    try:
        owner = us_number(config.params.get("owner-phone"))
        sender = get_sms_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("sms_setup_failed", reason=type(exc).__name__)
        return
    provider = type(sender).__name__
    for kind, to, build in items:
        try:
            number, body = build(owner)
            sender.send(SmsMessage(to=number, body=body))
            log("sms_sent", kind=kind, to=to, provider=provider)
        except Skip as skip:
            log("sms_skipped", kind=kind, to=to, reason=skip.reason)
        except Exception as exc:
            log("sms_error", kind=kind, to=to, provider=provider, reason=type(exc).__name__)


def _to_owner(owner: str | None, body: str):
    if not owner:
        raise Skip("no_owner_phone")  # the owner-phone setting is missing or not a 10 digit US number
    return owner, body


def _to_customer(booking: Booking, body: str):
    """(number, text) for a customer who agreed to texts and gave a US number. Otherwise Skip says which."""
    if not booking.sms_consent:
        raise Skip("no_consent")
    number = us_number(booking.phone)
    if not number:
        raise Skip("bad_number")
    return number, body


def texts_for_created(booking: Booking) -> None:
    _send_texts(
        [
            ("new_booking", "owner", lambda owner: _to_owner(owner, sms_templates.owner_new_booking(booking))),
            ("confirmation", "customer", lambda owner: _to_customer(booking, sms_templates.customer_confirmation(booking))),
        ]
    )


def texts_for_cancelled(booking: Booking) -> None:
    _send_texts([("cancellation", "customer", lambda owner: _to_customer(booking, sms_templates.customer_cancellation(booking)))])


def texts_for_moved(before: Booking, after: Booking) -> None:
    _send_texts([("rescheduled", "customer", lambda owner: _to_customer(after, sms_templates.customer_rescheduled(before, after)))])


def booking_reminder(booking: Booking) -> None:
    """The reminder before an appointment: an email if they left one, a text if they agreed to texts."""
    _send_all([("reminder", "customer", lambda owner: (_need_email(booking), templates.customer_reminder(booking, owner))[1])])
    _send_texts([("reminder", "customer", lambda owner: _to_customer(booking, sms_templates.customer_reminder(booking)))])
