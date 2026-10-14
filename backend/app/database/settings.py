"""Vic's settings in the database: one item that holds his services and his appointment lengths."""

from __future__ import annotations

from datetime import datetime, timezone

from ..domain import shop
from . import keys, table
from .keys import PK

# What a service may look like, so a damaged or hand-edited item can never break the site. Anything that does not fit
# is ignored and the default is used instead.
_SLOT_RANGE = range(shop.MIN_SLOT_MINUTES, shop.MAX_SLOT_MINUTES + 1)


def _service_from(raw: object) -> shop.Service | None:
    if not isinstance(raw, dict):
        return None
    try:
        service_id, name = str(raw["id"]), str(raw["name"])
        price = int(raw["price"])
    except (KeyError, TypeError, ValueError):
        return None
    if not service_id or not name:
        return None
    return shop.Service(service_id, name, price, bool(raw.get("from", False)), str(raw.get("note", "")))


def settings_from_item(item: dict | None) -> shop.ShopSettings:
    """Turns the stored item into ShopSettings. A missing or unreadable part falls back to the shop's defaults."""
    defaults = shop.DEFAULT_SETTINGS
    if not item:
        return defaults
    slots = defaults.slot_minutes
    stored = item.get("slotMinutes")
    if isinstance(stored, list) and len(stored) == 7:
        try:
            parsed = tuple(int(v) for v in stored)
        except (TypeError, ValueError):
            parsed = ()
        if len(parsed) == 7 and all(v in _SLOT_RANGE and v % shop.UNIT_MINUTES == 0 for v in parsed):
            slots = parsed  # type: ignore[assignment]
    services = defaults.services
    stored_services = item.get("services")
    if isinstance(stored_services, list):
        parsed_services = tuple(s for s in (_service_from(r) for r in stored_services) if s)
        if parsed_services:
            services = parsed_services
    reminders = defaults.reminder_hours
    stored_reminders = item.get("reminderHours")
    if isinstance(stored_reminders, list):  # an empty list is a real choice: no reminders
        try:
            parsed_hours = tuple(sorted({int(v) for v in stored_reminders}, reverse=True))
        except (TypeError, ValueError):
            parsed_hours = None
        if parsed_hours is not None and all(h in shop.REMINDER_CHOICES for h in parsed_hours):
            reminders = parsed_hours
    return shop.ShopSettings(slot_minutes=slots, services=services, reminder_hours=reminders)


def load() -> shop.ShopSettings:
    """Reads the settings (defaults if Vic has never saved any). ConsistentRead so a save is seen at once."""
    item = table.table().get_item(Key={"pk": PK, "sk": keys.SETTINGS_SK}, ConsistentRead=True).get("Item")
    return settings_from_item(item)


def save(settings: shop.ShopSettings) -> None:
    """Stores the settings, replacing the earlier ones."""
    table.table().put_item(
        Item={
            "pk": PK,
            "sk": keys.SETTINGS_SK,
            "kind": "settings",
            "slotMinutes": list(settings.slot_minutes),
            "reminderHours": list(settings.reminder_hours),
            "services": [
                {"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in settings.services
            ],
            "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
