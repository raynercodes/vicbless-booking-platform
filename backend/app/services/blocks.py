"""Vic blocking off time (lunch, a phone booking, a day off)."""

from __future__ import annotations

from datetime import datetime

from ..core.errors import InvalidSlot, ValidationFailed
from ..database import blocks as blocks_db
from ..domain import shop
from ..domain.models import Block
from ..schemas.requests import BlockIn, parse_date_key


def add_block(data: BlockIn, now: datetime) -> Block:
    """Blocks off part of a day, or all of it. Customers then see those times as taken (or the day as Closed)."""
    day = parse_date_key(data.dateKey)
    shop.check_blockable(day, now)  # open day, from today up to a year ahead
    windows = shop.windows_for(day)
    if data.whole:
        # A whole day off runs from the first opening time to the last closing time (Saturday's lunch gap included).
        start, end = windows[0][0], windows[-1][1]
    else:
        start, end = data.start, data.end
        if end <= start:
            raise ValidationFailed("The end time has to be after the start time.")
    # Turn the range into the 5 minute units it covers (only inside opening hours).
    claims = shop.block_units(day, start, end)
    if not claims:
        raise InvalidSlot("Pick times that fall inside opening hours.")
    # The database refuses (Conflict) if any of those blocks already holds a booking or another block-off.
    return blocks_db.create_block(day=day, claims=claims, start=start, end=end, note=data.note or "", whole=data.whole)


def remove_block(block_id: str) -> Block:
    """Opens blocked-off time back up."""
    return blocks_db.delete_block(block_id)
