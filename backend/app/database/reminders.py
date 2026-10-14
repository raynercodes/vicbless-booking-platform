"""Reminder bookkeeping in the database: which bookings are coming up, and marking a reminder as sent."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..domain.models import Booking
from . import keys, schedule, table
from .bookings import booking_from
from .keys import PK


def upcoming(first: date, last: date) -> list[Booking]:
    """Every booking from `first` through `last` (both days included), earliest first."""
    items = schedule.query_range(f"{first.isoformat()}#", f"{last.isoformat()}#~")
    return [booking_from(i) for i in items if i.get("kind") == "booking"]


def claim(booking: Booking, tag: str) -> bool:
    """Marks the reminder `tag` (like "24h") as sent for this booking. True if THIS call marked it, False if it already
    was (or the booking is gone, or was moved a moment ago), so two overlapping sweeps can never both send it."""
    try:
        table.table().update_item(
            Key={"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
            UpdateExpression="SET remindersSent = list_append(if_not_exists(remindersSent, :none), :tag)",
            ConditionExpression="attribute_exists(pk) AND (attribute_not_exists(remindersSent) OR NOT contains(remindersSent, :t))",
            ExpressionAttributeValues={":none": [], ":tag": [tag], ":t": tag},
        )
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise
    return True
