"""Blocked time (lunch, a day off) in the database: create, find, remove."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import Conflict, NotFound, SlotTaken
from ..domain.models import Block, new_id, parse_id
from . import keys, table, transactions
from .keys import PK


def block_from(item: dict) -> Block:
    """Turns a raw DynamoDB item into a Block."""
    return Block(
        id=item["id"],
        day=date.fromisoformat(item["date"]),
        start=int(item["start"]),
        end=int(item["end"]),
        note=item.get("note", ""),
        whole=bool(item.get("whole", False)),
        claims=tuple(int(s) for s in item.get("blocks", [])),
    )


def get_block(block_id: str) -> Block | None:
    parsed = parse_id(block_id)
    if not parsed:
        return None
    day, start = parsed
    item = table.table().get_item(Key={"pk": PK, "sk": keys.block_sk(day, start, block_id)}, ConsistentRead=True).get("Item")
    return block_from(item) if item else None


def create_block(*, day: date, claims: list[int], start: int, end: int, note: str, whole: bool) -> Block:
    # Same trick as a booking: claim every covered block in one transaction. If a booking or another
    # block-off already holds one of them, nothing is written and Vic gets a Conflict.
    block_id = new_id(day, claims[0])
    item = {
        "pk": PK,
        "sk": keys.block_sk(day, claims[0], block_id),
        "kind": "block",
        "id": block_id,
        "date": day.isoformat(),
        "start": start,
        "end": end,
        "note": note,
        "whole": whole,
        "blocks": claims,
        "expiresAt": keys.expires(day),
    }
    transaction = [
        {
            "Put": {
                "TableName": table.table_name(),
                "Item": item,
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }
    ] + [transactions.claim_put(day, s, block_id) for s in claims]
    try:
        transactions.write_all_or_nothing(transaction)
    except SlotTaken:
        raise Conflict() from None
    return block_from(item)


def delete_block(block_id: str) -> Block:
    block = get_block(block_id)
    if not block:
        raise NotFound("That blocked time was not found. It may already be removed.")
    transaction = [
        {
            "Delete": {
                "TableName": table.table_name(),
                "Key": {"pk": PK, "sk": keys.block_sk(block.day, block.claims[0], block.id)},
                "ConditionExpression": "attribute_exists(pk)",
            }
        }
    ] + [transactions.claim_delete(block.day, s, block.id) for s in block.claims]
    try:
        table.client().transact_write_items(TransactItems=transaction)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            if get_block(block_id) is None:
                raise NotFound("That blocked time was not found. It may already be removed.") from None
        raise
    return block
