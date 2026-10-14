"""Vic's settings: read them (cached for a few seconds) and save them.

Every booking and every availability request needs the settings, so they are kept in memory for CACHE_SECONDS
instead of read from the database each time. A save clears the cache at once on the instance that handled it; another
running copy of the API may still use the old settings for up to CACHE_SECONDS, which is harmless: bookings claim exact
5 minute units, so an appointment made under the older settings can never overlap another one.
"""

from __future__ import annotations

import secrets
import threading
import time

from ..core import config
from ..database import settings as settings_db
from ..domain import shop
from ..schemas.requests import SettingsIn

CACHE_SECONDS = 15

_lock = threading.Lock()
_cached: tuple[float, shop.ShopSettings] | None = None


def reset_cache() -> None:
    global _cached
    with _lock:
        _cached = None


config.on_reset(reset_cache)  # tests clear it together with the other caches


def current() -> shop.ShopSettings:
    """The settings right now (from the cache when it is fresh)."""
    global _cached
    now = time.monotonic()
    with _lock:
        if _cached and now - _cached[0] < CACHE_SECONDS:
            return _cached[1]
    loaded = settings_db.load()
    with _lock:
        _cached = (now, loaded)
    return loaded


def _new_service_id() -> str:
    return "svc-" + secrets.token_hex(3)


def save(data: SettingsIn) -> shop.ShopSettings:
    """Stores what Vic sent. A service without an id is new and gets one; the others keep theirs (bookings refer to it)."""
    services = []
    for item in data.services:
        services.append(
            shop.Service(
                id=item.id or _new_service_id(),
                name=item.name,
                price=item.price,
                from_price=item.from_price,
                note=item.note,
            )
        )
    updated = shop.ShopSettings(
        slot_minutes=tuple(data.slotMinutes[key] for key in shop.WEEKDAY_KEYS),  # type: ignore[arg-type]
        services=tuple(services),
        reminder_hours=(
            tuple(sorted(data.reminderHours, reverse=True)) if data.reminderHours is not None else current().reminder_hours
        ),
    )
    settings_db.save(updated)
    global _cached
    with _lock:
        _cached = (time.monotonic(), updated)
    return updated


def to_view(settings: shop.ShopSettings) -> dict:
    """The settings as the site reads them (the same for customers and for Vic's dashboard)."""
    return {
        "services": [
            {"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in settings.services
        ],
        "slotMinutes": dict(zip(shop.WEEKDAY_KEYS, settings.slot_minutes)),
        "reminderHours": list(settings.reminder_hours),
    }
