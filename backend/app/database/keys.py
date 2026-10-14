"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 5 minute unit (a 45 minute booking holds nine)
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
    SETTINGS                              Vic's settings (services, prices, appointment lengths). It has no date in front,
                                          so it never shows up in a day's range and never expires.
Failed-login counters live under their own partition key (LOCK#...).
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..domain import shop

PK = f"STAFF#{shop.STAFF_ID}"
KEEP_DAYS_AFTER = 90  # items disappear (DynamoDB TTL) about this long after their day


def expires(day: date) -> int:
    """When DynamoDB may delete the item: 90 days after the appointment day (a Unix timestamp).

    DynamoDB removes expired items within a day or two, not at the exact second. Nothing in the app
    depends on the exact moment, only on old data eventually going away.
    """
    end = datetime(day.year, day.month, day.day, tzinfo=timezone.utc) + timedelta(days=KEEP_DAYS_AFTER)
    return int(end.timestamp())


SETTINGS_SK = "SETTINGS"


def claim_sk(day: date, start: int) -> str:
    """The sort key of one block's claim. Only one item can have this key, which is what prevents double booking."""
    return f"{day.isoformat()}#CLAIM#{shop.hhmm(start)}"


def booking_sk(day: date, start: int, booking_id: str) -> str:
    return f"{day.isoformat()}#BOOKING#{shop.hhmm(start)}#{booking_id}"


def block_sk(day: date, start: int, block_id: str) -> str:
    return f"{day.isoformat()}#BLOCK#{shop.hhmm(start)}#{block_id}"


def minutes_of(hhmm: str) -> int:
    """'1235' -> 755 minutes after midnight (the reverse of shop.hhmm)."""
    return int(hhmm[:2]) * 60 + int(hhmm[2:])
