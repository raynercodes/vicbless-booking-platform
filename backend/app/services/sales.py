"""Vic's sales log in action: log a sale, list them, remove one."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..core.errors import NotFound, ValidationFailed
from ..core.logs import log
from ..database import sales as sales_db
from ..domain import shop
from ..domain.sales import Sale, new_sale_id, parse_sale_id
from ..schemas.requests import MSG_SALE_AMOUNT, MSG_SALE_SERVICE, SaleIn, parse_date_key
from . import settings as settings_service

MAX_DAYS_BACK = 366  # a sale can be logged for any day in the last year


def _build(data: SaleIn, now: datetime, *, sale_id: str | None, created_at: str, same_day: date | None = None) -> Sale:
    """Turns what Vic picked into a line of the log. The listed price is read from his settings here, never trusted
    from the screen, and a sale can't be dated in the future. `sale_id` is kept when a line is edited on its own day."""
    today = shop.today(now)
    day = parse_date_key(data.dateKey) if data.dateKey else (same_day or today)
    if day > today:
        raise ValidationFailed("A sale can't be dated in the future.", field="dateKey")
    if day < today - timedelta(days=MAX_DAYS_BACK):
        raise ValidationFailed("A sale can be logged for any day in the last year.", field="dateKey")

    service = settings_service.current().service(data.serviceId) if data.serviceId else None
    if data.serviceId and service is None:  # Vic may have removed it since the screen loaded
        raise ValidationFailed(MSG_SALE_SERVICE, field="serviceId")
    name = service.name if service else data.serviceName
    if not name:
        raise ValidationFailed(MSG_SALE_SERVICE, field="serviceName")

    custom = data.priceMode == "custom"
    if custom:
        if data.amountCents is None:
            raise ValidationFailed(MSG_SALE_AMOUNT, field="amountCents")
        amount = data.amountCents
    else:
        if service is None:
            raise ValidationFailed("A one-off service has no listed price. Type the price.", field="amountCents")
        amount = service.price * 100

    return Sale(
        id=sale_id if sale_id and parse_sale_id(sale_id) == day else new_sale_id(day),
        day=day,
        service_id=service.id if service else "",
        service_name=name,
        amount_cents=amount,
        custom_price=custom,
        payment=data.payment,
        client_name=data.clientName,
        note=data.note or "",
        created_at=created_at,
    )


def add_sale(data: SaleIn, now: datetime) -> Sale:
    sale = sales_db.add(_build(data, now, sale_id=None, created_at=now.astimezone(timezone.utc).isoformat(timespec="seconds")))
    log("sale_logged", saleId=sale.id, amountCents=sale.amount_cents, payment=sale.payment, custom=sale.custom_price)
    return sale


def update_sale(sale_id: str, data: SaleIn, now: datetime) -> Sale:
    """Vic edits a line: everything on it can change. It keeps its place in the log (and its id) unless the day changes,
    which gives it a new id because the id carries the day. The old line is gone either way."""
    old = sales_db.get(sale_id)
    if old is None:
        raise NotFound(sales_db.NOT_FOUND)
    new = _build(data, now, sale_id=old.id, created_at=old.created_at, same_day=old.day)
    sales_db.replace(old, new)  # raises NotFound if the line was removed a moment ago
    log("sale_edited", saleId=new.id, amountCents=new.amount_cents, payment=new.payment, custom=new.custom_price)
    return new


def list_sales() -> list[Sale]:
    return sales_db.list_all()


def remove_sale(sale_id: str) -> Sale:
    sale = sales_db.remove(sale_id)
    log("sale_removed", saleId=sale.id)
    return sale
