"""Builds test data. Each builder has sensible defaults, so a test only spells out what it is about."""

from datetime import date

from app.database import bookings as bookings_db
from app.database import schedule as schedule_db
from app.domain.models import Booking

from .constants import TUESDAY


def booking_body(**over) -> dict:
    """The JSON the booking page sends, as a dict. Override any field: booking_body(name="A")."""
    body = {
        "staffId": "vic",
        "serviceId": "mens-cut",
        "dateKey": TUESDAY,
        "start": 12 * 60,  # 12:00 pm, the first block on a Tuesday
        "minutes": 35,
        "name": "Marcus Jones",
        "phone": "(555) 010-1234",
        "email": "",
        "notes": "",
    }
    body.update(over)
    return body


def booking_model(**over) -> Booking:
    """A Booking object (no database involved), for template and formatting tests."""
    args = dict(
        id="2026-10-13.1200.abcdef12",
        code="VB-ABC234",
        day=date(2026, 10, 13),
        start=720,
        minutes=35,
        service_id="mens-cut",
        name="Marcus Jones",
        phone="5550101234",
        email="m@example.com",
        notes="",
        created_at="",
    )
    args.update(over)
    return Booking(**args)


def make_booking(start=720, minutes=35, phone="5550101234", day=date(2026, 10, 13), **over) -> Booking:
    """Writes a booking straight into the database, skipping the web layer and the booking rules."""
    args = dict(
        day=day,
        start=start,
        service_id="mens-cut",
        minutes=minutes,
        name="A Person",
        phone=phone,
        email="",
        notes="",
        code="VB-AAAAAA",
    )
    args.update(over)
    return bookings_db.create_booking(**args)


def taken_blocks(day: date = date(2026, 10, 13)) -> list[int]:
    """The taken block starts for one day, as the database reports them."""
    return schedule_db.availability(day, day)[day.isoformat()]["busy"]
