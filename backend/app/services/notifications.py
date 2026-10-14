"""Sends the emails and texts around a booking. Best effort: a failed one is logged and never fails the booking.

Vic is texted at his own number (the `owner-phone` setting) about new bookings. A customer is texted only if they ticked
"text me" when booking, and emailed only if they left an email address."""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates
from ..texting import SmsMessage, us_number
from ..texting import get_sender as get_sms_sender
from ..texting import templates as sms_templates


def _send_all(builders) -> None:
    """Builds and sends each email on its own. One failing never stops the others, and none can fail the booking."""
    try:
        owner = config.params.get("owner-email") or ""
        sender = get_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("email_setup_failed", reason=type(exc).__name__)
        return
    for build in builders:
        try:
            message: EmailMessage | None = build(owner)
            if message is not None and message.to:
                sender.send(message)
        except Exception as exc:
            log("email_error", reason=type(exc).__name__)


def booking_created(booking: Booking) -> None:
    """Vic always hears about a new booking; the customer gets a confirmation only if they left an email."""
    _send_all(
        [
            lambda owner: templates.owner_notification(booking, owner) if owner else None,
            lambda owner: templates.customer_confirmation(booking, owner) if booking.email else None,
        ]
    )
    texts_for_created(booking)


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (by email and/or text, whichever they chose)."""
    _send_all([lambda owner: templates.customer_cancellation(booking, owner) if booking.email else None])
    texts_for_cancelled(booking)


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (by email and/or text, whichever they chose)."""
    _send_all([lambda owner: templates.customer_rescheduled(before, after, owner) if after.email else None])
    texts_for_moved(before, after)


def _send_texts(builders) -> None:
    """Builds and sends each text on its own. A builder gets Vic's number and returns (number, text) or None to skip."""
    try:
        owner = us_number(config.params.get("owner-phone"))
        sender = get_sms_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("sms_setup_failed", reason=type(exc).__name__)
        return
    for build in builders:
        try:
            built = build(owner)
            if built is not None:
                to, body = built
                if to:
                    sender.send(SmsMessage(to=to, body=body))
        except Exception as exc:
            log("sms_error", reason=type(exc).__name__)


def _to_customer(booking: Booking, body: str):
    """(number, text) for a customer who agreed to texts and gave a US number, otherwise None."""
    return (us_number(booking.phone), body) if booking.sms_consent else None


def texts_for_created(booking: Booking) -> None:
    _send_texts(
        [
            lambda owner: (owner, sms_templates.owner_new_booking(booking)) if owner else None,
            lambda owner: _to_customer(booking, sms_templates.customer_confirmation(booking)),
        ]
    )


def texts_for_cancelled(booking: Booking) -> None:
    _send_texts([lambda owner: _to_customer(booking, sms_templates.customer_cancellation(booking))])


def texts_for_moved(before: Booking, after: Booking) -> None:
    _send_texts([lambda owner: _to_customer(after, sms_templates.customer_rescheduled(before, after))])


def booking_reminder(booking: Booking) -> None:
    """The reminder before an appointment: an email if they left one, a text if they agreed to texts."""
    _send_all([lambda owner: templates.customer_reminder(booking, owner) if booking.email else None])
    _send_texts([lambda owner: _to_customer(booking, sms_templates.customer_reminder(booking))])
