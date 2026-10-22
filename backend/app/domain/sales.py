"""Vic's sales log: one line per client he served, kept by hand in the dashboard (separate from online bookings).

Pure data and rules, nothing here touches AWS.
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass
from datetime import date

PAYMENTS = ("shop", "online")  # how the client paid: at the shop, or online
MAX_SALE_CENTS = 999_999  # $9,999.99, a typo guard more than a business limit
ID_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})\.sale\.[0-9a-f]{8}$")


def new_sale_id(day: date) -> str:
    """'2026-10-22.sale.9f3a1c2b'. The date is inside it, so removing a line is a direct lookup."""
    return f"{day.isoformat()}.sale.{secrets.token_hex(4)}"


def parse_sale_id(value: str) -> date | None:
    """The date inside a sale id, or None if the id is not one we could have made."""
    m = ID_PATTERN.match(value or "")
    if not m:
        return None
    try:
        return date.fromisoformat(m.group(1))
    except ValueError:
        return None


@dataclass(frozen=True)
class Sale:
    id: str
    day: date
    service_id: str  # "" for a one-off service Vic typed in
    service_name: str
    amount_cents: int
    custom_price: bool  # True when Vic typed the price instead of using the service's listed one
    payment: str  # "shop" or "online"
    client_name: str
    note: str
    created_at: str  # when it was logged (ISO, UTC)

    def admin_view(self) -> dict:
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "serviceId": self.service_id,
            "serviceName": self.service_name,
            "amountCents": self.amount_cents,
            "customPrice": self.custom_price,
            "payment": self.payment,
            "clientName": self.client_name,
            "note": self.note,
            "createdAt": self.created_at,
        }
