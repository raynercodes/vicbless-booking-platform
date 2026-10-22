"""Booking rules in action: what happens when a customer asks for a time.

This layer decides WHAT should happen and in which order. It calls the shop rules (domain/shop.py)
to ask "is this a valid time?" and the database layer to actually store it. It knows nothing about
web requests or DynamoDB details, which is what keeps it easy to read and easy to test.
"""

from __future__ import annotations

from datetime import date, datetime

from ..core.brand import CONTACT_EMAIL
from ..core.errors import NotFound, PaymentUnavailable, SlotTaken, TooManyBookings, ValidationFailed
from ..core.logs import log
from ..database import bookings as bookings_db
from ..database import schedule
from ..domain import shop
from ..domain.models import Booking, new_code
from ..schemas.requests import MSG_SERVICE, BookingIn, MoveIn, parse_date_key
from . import payments as payments_service
from . import settings as settings_service

# Anti-spam: one phone number can hold at most this many upcoming bookings at a time.
MAX_UPCOMING_PER_PHONE = 3


def get_availability(first: date, last: date) -> dict[str, dict]:
    """Which times are taken, day by day, for the booking page's grid. Works for up to 31 days at once."""
    if last < first:
        raise ValidationFailed("The end date can't be before the start date.")
    if (last - first).days + 1 > shop.MAX_RANGE_DAYS:
        raise ValidationFailed(f"Please ask for {shop.MAX_RANGE_DAYS} days or fewer at a time.")
    payments_service.release_expired_quietly(shop.now_local())  # a time whose payment ran out is free from that minute on
    return schedule.availability(first, last, settings_service.current())


def _same_request(existing: Booking | None, data: BookingIn, day: date) -> Booking | None:
    """Is `existing` the booking THIS request already made?

    A customer who double-taps the button, or whose phone loses signal right after the booking went
    through, sends the same request twice. The second one should get their booking back, not an
    error that says the time was taken (by them). "Same request" means the same person, service and time.
    """
    if (
        existing
        and existing.day == day
        and existing.start == data.start
        and existing.phone == data.phone
        and existing.service_id == data.serviceId
        and existing.name.casefold() == data.name.casefold()
        # the same way of paying too, except that a payment still pending can be answered by either (see replay_of)
        and (existing.payment == "pending" or (existing.payment == "paid") == (data.payment == "online"))
    ):
        return existing
    return None


def create_booking(data: BookingIn, now: datetime) -> tuple[Booking, bool]:
    """Books the time. Returns (booking, created); created is False when this exact request had already succeeded.

    Order matters:
      1. is it a service Vic offers, a time he could ever take, and is it open right now?  (shop rules)
      2. does this phone number already hold too many upcoming bookings?  (anti-spam)
      3. try to claim the time. The database refuses if anyone got there first.
    """
    day = parse_date_key(data.dateKey)
    settings = settings_service.current()
    service = settings.service(data.serviceId)
    if service is None:  # Vic may have removed it since the page was loaded
        raise ValidationFailed(MSG_SERVICE, field="serviceId")
    minutes = settings.slot_for(day)  # the length is the day's setting, never something the client sends
    shop.check_bookable(day, data.start, minutes, now, settings.after_count(day))
    shop.check_service_fits_slot(service.after_hours, day, data.start)
    payments_service.release_expired_quietly(now)  # someone else's payment may have just run out, which frees this time

    def earlier_attempt() -> Booking | None:
        # Look at who owns this exact time right now, and check if it is this same request.
        return _same_request(bookings_db.booking_holding(day, data.start), data, day)

    online = data.payment == "online"
    amount_cents = service.price * 100
    if online:
        if not payments_service.available():
            raise PaymentUnavailable()
        if amount_cents <= 0:
            raise ValidationFailed("This service is free to book, so there is nothing to pay online.", field="payment")

    def replay_of(earlier: Booking) -> tuple[Booking, bool] | None:
        """The answer for a retried request. A payment page that has run out is not handed back, and neither is one the customer
        now wants to skip (they came back and chose "pay at the shop"): the time is given up so the request can start over."""
        if earlier.payment == "pending" and (not online or payments_service.hold_is_over(earlier, now)):
            return None if payments_service.release(earlier) == "released" else (earlier, False)
        log("booking_replayed", bookingId=earlier.id)
        return earlier, False

    if bookings_db.upcoming_for_phone(data.phone, shop.today(now)) >= MAX_UPCOMING_PER_PHONE:
        # The cap is reached, but a retry of an already-made booking must still be answered with it.
        replay = earlier_attempt()
        if replay and (answer := replay_of(replay)):
            return answer
        log("booking_refused", reason="too_many_upcoming")
        raise TooManyBookings(
            f"This phone number already has {MAX_UPCOMING_PER_PHONE} upcoming bookings, which is the most we allow. "
            f"Please email Vic at {CONTACT_EMAIL} if you need to change one."
        )
    held_until = payments_service.hold_until(now) if online else ""
    for attempt in (1, 2):  # a second go only after a run-out payment page of this same request was given up
        try:
            booking = bookings_db.create_booking(
                day=day,
                start=data.start,
                service_id=data.serviceId,
                service_name=service.name,
                minutes=minutes,
                name=data.name,
                phone=data.phone,
                email=data.email or "",
                notes=data.notes or "",
                code=new_code(),
                sms_consent=data.smsConsent,
                payment="pending" if online else "shop",
                amount_cents=amount_cents,
                hold_until=held_until,
            )
            break
        except SlotTaken:
            # Someone holds the time. If that someone is this very request (a retry), hand it back.
            replay = earlier_attempt()
            answer = replay_of(replay) if replay else None
            if answer:
                return answer  # the same request arrived twice; the first one stands
            if replay is None or attempt == 2:
                log("booking_refused", reason="slot_taken", date=data.dateKey, start=data.start)
                raise
    log(
        "booking_created",
        bookingId=booking.id,
        serviceId=booking.service_id,
        minutes=booking.minutes,
        hasEmail=bool(booking.email),
        smsConsent=booking.sms_consent,
        payment=booking.payment,
    )
    if online:
        booking = payments_service.start_checkout(booking, data.returnTo)  # Vic and the customer hear about it once it is paid
    return booking, True


def cancel_booking(booking_id: str) -> Booking:
    """Vic cancels a booking. Frees every block it held, and returns it so the customer can be told.

    One that was paid online is refunded first, and if the refund fails nothing is cancelled. One still waiting for payment
    has its payment page closed, so the customer can't pay for a time that is no longer theirs.
    """
    booking = bookings_db.get_booking(booking_id)
    if booking is None:
        raise NotFound("That booking was not found. It may already be cancelled.")
    if booking.payment == "pending":
        outcome = payments_service.release(booking)
        if outcome == "released":
            log("booking_cancelled", bookingId=booking.id, smsConsent=booking.sms_consent, hasEmail=bool(booking.email))
            return booking
        if outcome == "gone":
            raise NotFound("That booking was not found. It may already be cancelled.")
        if outcome == "paid":  # they paid a moment ago: it is a paid booking now, so it is refunded below
            booking = bookings_db.get_booking(booking_id) or booking
    if booking.payment == "paid":
        payments_service.refund(booking)
    booking = bookings_db.cancel_booking(booking_id)
    log("booking_cancelled", bookingId=booking.id, smsConsent=booking.sms_consent, hasEmail=bool(booking.email), payment=booking.payment)
    return booking


def move_booking(booking_id: str, data: MoveIn, now: datetime) -> tuple[Booking, Booking]:
    """Vic moves a booking to another time. Returns (before, after) so the customer can be told both.

    The customer keeps the same code. The booking gets a new id, because the id contains the day and time.
    """
    before = bookings_db.get_booking(booking_id)
    if not before:
        raise NotFound("That booking was not found. It may already be cancelled.")
    if before.payment == "pending":
        raise ValidationFailed("This booking is waiting for the customer to pay online. Wait for the payment, or cancel it.")
    day = parse_date_key(data.dateKey)
    if (day, data.start) == (before.day, before.start):
        raise ValidationFailed("That booking is already at that time. Pick a different one.")
    settings = settings_service.current()
    minutes = settings.slot_for(day)  # the booking takes the new day's appointment length
    shop.check_movable(day, data.start, minutes, now, settings.after_count(day))
    shop.check_service_fits_slot(before.service_id == shop.AFTER_HOURS_ID, day, data.start)
    after = bookings_db.move_booking(before, day=day, start=data.start, minutes=minutes)  # raises SlotTaken if not free
    log("booking_moved", fromId=before.id, toId=after.id, minutes=minutes)
    return before, after
