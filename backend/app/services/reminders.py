"""Reminders before appointments. A scheduled run (every 15 minutes, see infra/template.yaml) calls send_due().

Vic chooses the reminder times in his settings (default: 24 hours and 2 hours before). For each upcoming booking the
sweep works out which of those moments have arrived, and sends the reminder by email (if the customer left one) and by
text (if they agreed to texts).

Rules that keep it from being annoying:
  - each reminder is marked as sent BEFORE it is sent, so it goes out at most once, even if two sweeps overlap
  - a reminder whose moment had already passed when the booking was made (or moved) is never sent
    (someone who books at noon for 2 pm does not get a "24 hours before" reminder)
  - if two reminders are due at once (the sweep was down for a while), only the nearest one is sent
  - nothing is sent after the appointment has started
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..core.logs import log
from ..database import reminders as reminders_db
from ..domain import shop
from ..domain.models import Booking
from . import notifications
from . import settings as settings_service


def _tag(hours: int) -> str:
    return f"{hours}h"


def _updated(booking: Booking) -> datetime:
    """When the booking was made or last moved (UTC). Unreadable or missing counts as long ago."""
    try:
        return datetime.fromisoformat(booking.updated_at).astimezone(timezone.utc)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def _handle(booking: Booking, hours_list: tuple[int, ...], now: datetime) -> bool:
    """Sends the reminder this booking is due, if any. Returns True when one was sent."""
    starts = shop.starts_at(booking.day, booking.start).astimezone(timezone.utc)
    if now >= starts:
        return False
    changed = _updated(booking)
    due: list[int] = []  # reminder moments that have arrived and are still wanted
    for hours in hours_list:
        tag = _tag(hours)
        moment = starts - timedelta(hours=hours)
        if tag in booking.reminders_sent or moment > now:
            continue
        if moment < changed:  # already in the past when it was booked or moved: skip it for good
            reminders_db.claim(booking, tag)
            log("reminder_skipped", bookingId=booking.id, tag=tag, reason="past_when_booked")
            continue
        due.append(hours)
    if not due:
        return False
    nearest = min(due)
    for hours in due:
        if hours != nearest:
            reminders_db.claim(booking, _tag(hours))  # an older one that was overtaken: mark it, send only the nearest
    if not reminders_db.claim(booking, _tag(nearest)):
        return False
    log("reminder_sending", bookingId=booking.id, tag=_tag(nearest), smsConsent=booking.sms_consent, hasEmail=bool(booking.email))
    notifications.booking_reminder(booking)
    return True


def send_due(now: datetime | None = None) -> dict[str, int]:
    """One sweep. Returns how many reminders were sent and how many bookings could not be handled."""
    moment = (now or shop.now_local()).astimezone(timezone.utc)
    hours_list = settings_service.current().reminder_hours
    result = {"sent": 0, "errors": 0}
    if not hours_list:
        log("reminders_swept", sent=0, errors=0, examined=0, note="no reminder times are switched on")
        return result
    first = shop.today(moment)
    last: date = first + timedelta(days=max(hours_list) // 24 + 2)
    upcoming = reminders_db.upcoming(first, last)
    for booking in upcoming:
        try:
            if _handle(booking, hours_list, moment):
                result["sent"] += 1
        except Exception as exc:  # one broken booking must not stop everyone else's reminder
            result["errors"] += 1
            log("reminder_error", reason=type(exc).__name__)
    log("reminders_swept", examined=len(upcoming), reminderHours=list(hours_list), **result)
    return result
