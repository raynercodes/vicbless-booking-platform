"""Sends the emails around a booking. Best effort: a failed email is logged and never fails the booking."""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates


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


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (only if they left an email)."""
    _send_all([lambda owner: templates.customer_cancellation(booking, owner) if booking.email else None])


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (only if they left an email)."""
    _send_all([lambda owner: templates.customer_rescheduled(before, after, owner) if after.email else None])
