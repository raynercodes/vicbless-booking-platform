"""Reading a day or a range of days: what is taken, and the schedule Vic sees."""

from __future__ import annotations

from datetime import date, timedelta

from ..domain import shop
from ..domain.models import Block, Booking
from . import blocks as blocks_db
from . import bookings as bookings_db
from . import keys, table
from .keys import PK


def query_range(low: str, high: str, projection: bool = False) -> list[dict]:
    """Reads all of Vic's items whose sort key is between `low` and `high`, following DynamoDB's paging.

    Sort keys start with the date, so "2026-10-12#" to "2026-10-12#~" is exactly one day, and a longer
    range is just as cheap: one query, not one per day. projection=True fetches only what availability needs.
    """
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk AND sk BETWEEN :lo AND :hi",
        "ExpressionAttributeValues": {":pk": PK, ":lo": low, ":hi": high},
        "ConsistentRead": True,
    }
    if projection:
        kwargs["ProjectionExpression"] = "#sk, #w"
        kwargs["ExpressionAttributeNames"] = {"#sk": "sk", "#w": "whole"}
    items: list[dict] = []
    while True:
        page = table.table().query(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def availability(first: date, last: date, settings: shop.ShopSettings) -> dict[str, dict]:
    """{ 'YYYY-MM-DD': { busy: [appointment starts], dayOff: bool, slotMinutes: int } } for every day in the range.

    `busy` lists the appointment starts of that day's grid that overlap anything taken (bookings and block-offs alike,
    so the site greys them out the same way). `dayOff` is true when Vic took the whole day off, so the site can say
    "Closed" instead of "Full". `slotMinutes` is how long an appointment is that day.
    """
    # Start every day empty, so days with nothing booked still appear in the answer.
    days: dict[str, dict] = {}
    taken: dict[str, set[int]] = {}
    d = first
    while d <= last:
        days[d.isoformat()] = {"busy": [], "dayOff": False, "slotMinutes": settings.slot_for(d)}
        taken[d.isoformat()] = set()
        d += timedelta(days=1)
    items = query_range(f"{first.isoformat()}#", f"{last.isoformat()}#~", projection=True)
    for item in items:
        day_key, kind, *rest = item["sk"].split("#")
        entry = days.get(day_key)
        if entry is None:
            continue
        if kind == "CLAIM":
            taken[day_key].add(keys.minutes_of(rest[0]))
        elif kind == "BLOCK" and item.get("whole"):
            entry["dayOff"] = True
    for day_key, entry in days.items():
        day = date.fromisoformat(day_key)
        entry["busy"] = shop.busy_slots(day, entry["slotMinutes"], taken[day_key], settings.after_count(day))
    return days


def day_schedule(day: date) -> tuple[list[Booking], list[Block]]:
    items = query_range(f"{day.isoformat()}#", f"{day.isoformat()}#~")
    bookings, blocks = [], []
    for item in items:
        kind = item["sk"].split("#")[1]
        if kind == "BOOKING":
            bookings.append(bookings_db.booking_from(item))
        elif kind == "BLOCK":
            blocks.append(blocks_db.block_from(item))
    bookings.sort(key=lambda b: b.start)
    blocks.sort(key=lambda b: b.start)
    return bookings, blocks
