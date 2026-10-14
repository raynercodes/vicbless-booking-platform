"""Routes anyone can call (mounted under /api).

A route's job is small: read the request, hand it to a service, and shape the answer. The decisions
(is this time bookable? who wins a race?) are made in services/ and database/, not here.
"""

from __future__ import annotations

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from ..core import config
from ..domain import shop
from ..schemas.requests import BookingIn, date_from_query
from ..services import bookings, notifications
from ..services import settings as settings_service

router = APIRouter()


@router.get("/health")
def health() -> dict:
    """Is the API up, which environment is it, and which version of the code is running?"""
    try:
        # The deploy workflow writes the version into AWS Parameter Store after every deploy.
        version = config.params.get("app-version") or "unknown"
    except Exception:
        version = "unknown"  # a health check must never fail just because the version can't be read
    return {"status": "ok", "environment": config.get_settings().environment, "version": version}


@router.get("/availability")
def availability(from_: str = Query(alias="from"), to: str = Query()) -> dict:
    """Which times are taken between two dates. The booking page uses this to grey out unavailable times.

    `from` is a Python keyword, so the parameter is called from_ here and given its URL name with alias.
    """
    return bookings.get_availability(date_from_query(from_), date_from_query(to))


@router.get("/settings")
def shop_settings() -> dict:
    """The services and prices, and how long an appointment is on each weekday. The site reads this to draw its pages."""
    return settings_service.to_view(settings_service.current())


@router.post("/bookings")
def create_booking(body: BookingIn) -> JSONResponse:
    """A customer books a time.

    201 = a new booking was made. 200 = this exact request had already succeeded (a retry), so the
    same booking is returned and no second email goes out.
    """
    booking, created = bookings.create_booking(body, shop.now_local())
    if created:
        notifications.booking_created(booking)  # best effort: a failed email never fails the booking
    # public_view() leaves out the internal id; the customer only needs their code.
    return JSONResponse(status_code=201 if created else 200, content=booking.public_view())
