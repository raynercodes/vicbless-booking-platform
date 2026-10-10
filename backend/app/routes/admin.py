"""Vic's routes (mounted under /api/admin).

Two routers on purpose:
  login_router  open to everyone, because it is how Vic gets a token in the first place
  router        every route on it requires a valid session. The check is attached to the router, so a
                new admin route can't be added here and accidentally left open.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse

from ..domain import shop
from ..schemas.requests import BlockIn, LoginIn, MoveIn, date_from_query
from ..services import auth, blocks, bookings, notifications
from ..services import schedule as schedule_service
from .deps import require_admin, source_address

login_router = APIRouter()
router = APIRouter(dependencies=[Depends(require_admin)])


@login_router.post("/login")
def login(body: LoginIn, request: Request) -> dict:
    """Password in, session token out (valid 12 hours)."""
    return auth.login(body.password, source_address(request))


@router.get("/schedule")
def schedule(date: str = Query()) -> dict:
    """One day for the dashboard: bookings with contact details, and blocked-off times."""
    return schedule_service.day_for_admin(date_from_query(date))


@router.delete("/bookings/{booking_id}")
def cancel_booking(booking_id: str) -> dict:
    """Cancels a booking, frees its time, and emails the customer if they left an email."""
    booking = bookings.cancel_booking(booking_id)
    notifications.booking_cancelled(booking)
    return {"cancelled": True}


@router.patch("/bookings/{booking_id}")
def move_booking(booking_id: str, body: MoveIn) -> dict:
    """Moves a booking to another open time (any day up to a year ahead), and emails the customer if they left an email.

    The answer is the booking in its new place. It has a NEW id, because the id contains the day and time.
    """
    before, after = bookings.move_booking(booking_id, body, shop.now_local())
    notifications.booking_moved(before, after)
    return after.admin_view()


@router.post("/blocks")
def add_block(body: BlockIn) -> JSONResponse:
    """Blocks off part of a day, or the whole day (customers then see "Closed")."""
    block = blocks.add_block(body, shop.now_local())
    return JSONResponse(status_code=201, content=block.admin_view())


@router.delete("/blocks/{block_id}")
def remove_block(block_id: str) -> dict:
    """Opens blocked-off time back up."""
    blocks.remove_block(block_id)
    return {"removed": True}
