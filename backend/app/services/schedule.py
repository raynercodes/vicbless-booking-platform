"""The schedule Vic sees for one day."""

from __future__ import annotations

from datetime import date

from ..database import schedule as schedule_db


def day_for_admin(day: date) -> dict:
    """One day for the dashboard: the bookings (with contact details) and the blocked-off times."""
    bookings, blocks = schedule_db.day_schedule(day)
    return {
        "dateKey": day.isoformat(),
        "items": [b.admin_view() for b in bookings],
        "blocks": [b.admin_view() for b in blocks],
    }
