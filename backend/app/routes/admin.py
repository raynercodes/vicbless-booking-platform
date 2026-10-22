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
from ..schemas.requests import BlockIn, LoginIn, MoveIn, SaleIn, SettingsIn, date_from_query
from ..services import auth, blocks, bookings, notifications
from ..services import sales as sales_service
from ..services import schedule as schedule_service
from ..services import settings as settings_service
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


@router.get("/settings")
def get_settings() -> dict:
    """Vic's settings as he last saved them (or the shop's defaults), read fresh from the database."""
    settings_service.reset_cache()
    return settings_service.to_view(settings_service.current())


@router.put("/settings")
def put_settings(body: SettingsIn) -> dict:
    """Saves the services and appointment lengths. Takes effect for new bookings at once; existing ones keep their times."""
    return settings_service.to_view(settings_service.save(body))


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


@router.get("/sales")
def list_sales() -> dict:
    """Vic's whole sales log, newest first. The dashboard filters, sorts and adds it up."""
    return {"sales": [s.admin_view() for s in sales_service.list_sales()]}


@router.post("/sales")
def add_sale(body: SaleIn) -> JSONResponse:
    """Logs a sale Vic entered by hand."""
    sale = sales_service.add_sale(body, shop.now_local())
    return JSONResponse(status_code=201, content=sale.admin_view())


@router.put("/sales/{sale_id}")
def edit_sale(sale_id: str, body: SaleIn) -> dict:
    """Changes a line of the log. The answer is the line as it is now (its id changes only if its day did)."""
    return sales_service.update_sale(sale_id, body, shop.now_local()).admin_view()


@router.delete("/sales/{sale_id}")
def remove_sale(sale_id: str) -> dict:
    """Removes a line of the log (for a mistake)."""
    sales_service.remove_sale(sale_id)
    return {"removed": True}
