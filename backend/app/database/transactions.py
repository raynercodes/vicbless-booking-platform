"""Why double booking cannot happen: every 5 minute unit of every day gets one "claim" item whose key is
unique to that unit. A booking (or a block-off) is written together with all the claims it needs in ONE
transaction, and each claim must not already exist. If any claim is taken, nothing is written. DynamoDB decides
who wins when two people try for the same unit at once.

Because the claims are 5 minute units, not appointment slots, two things can share a unit only if they really
overlap in time. So the appointment length can differ from day to day, or change later, and an older booking made
with a different length still blocks exactly the time it covers.

DynamoDB allows at most 100 items in one transaction. Bookings and moves need far fewer. A whole-day block-off on a
long day can need more, so block-offs go through write_claimed / delete_claimed below, which split the claims into
chunks when they must (and undo the earlier chunks if a later one is refused).
"""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import SlotTaken
from . import keys, table
from .keys import PK


MAX_TRANSACTION_ITEMS = 100  # DynamoDB's limit for one transaction
CHUNK_CLAIMS = 90  # claims per transaction when a block-off needs several (leaves room for the block item itself)


def claim_put(day: date, start: int, ref: str, *, allow_same_ref: bool = False) -> dict:
    """ "Reserve this unit for `ref`": creates the claim, but ONLY if nobody has it yet.

    allow_same_ref also accepts a claim `ref` already owns, which makes the one-time migration safe to run twice.
    """
    return {
        "Put": {
            "TableName": table.table_name(),
            "Item": {
                "pk": PK,
                "sk": keys.claim_sk(day, start),
                "kind": "claim",
                "ref": ref,
                "expiresAt": keys.expires(day),
            },
            **(
                {
                    "ConditionExpression": "attribute_not_exists(pk) OR #ref = :ref",
                    "ExpressionAttributeNames": {"#ref": "ref"},
                    "ExpressionAttributeValues": {":ref": ref},
                }
                if allow_same_ref
                else {"ConditionExpression": "attribute_not_exists(pk)"}
            ),
        }
    }


def claim_delete(day: date, start: int, ref: str, *, tolerant: bool = False) -> dict:
    """ "Release this unit": deletes the claim, but ONLY if it still belongs to `ref` (never someone else's).

    tolerant also accepts a claim that is already gone, so a half-finished release can simply be run again.
    """
    return {
        "Delete": {
            "TableName": table.table_name(),
            "Key": {"pk": PK, "sk": keys.claim_sk(day, start)},
            # "ref" is a reserved word in DynamoDB, so it needs a name alias
            "ConditionExpression": "attribute_not_exists(pk) OR #ref = :ref" if tolerant else "#ref = :ref",
            "ExpressionAttributeNames": {"#ref": "ref"},
            "ExpressionAttributeValues": {":ref": ref},
        }
    }


def claim_reassign(day: date, start: int, old_ref: str, new_ref: str) -> dict:
    """ "Hand this block from `old_ref` to `new_ref`": used when a moved booking keeps a block it already held.

    A transaction may touch each item only once, so a block that is in both the old and the new time
    can't be deleted and re-created. Instead its owner is changed in place, and only if `old_ref` still owns it.
    """
    return {
        "Update": {
            "TableName": table.table_name(),
            "Key": {"pk": PK, "sk": keys.claim_sk(day, start)},
            "UpdateExpression": "SET #ref = :new",
            "ConditionExpression": "#ref = :old",
            "ExpressionAttributeNames": {"#ref": "ref"},
            "ExpressionAttributeValues": {":old": old_ref, ":new": new_ref},
        }
    }


def write_all_or_nothing(items: list[dict]) -> None:
    """Runs the transaction. Returns normally if everything was written; raises SlotTaken if a block was taken."""
    try:
        table.client().transact_write_items(TransactItems=items)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            reasons = [r.get("Code") for r in err.response.get("CancellationReasons", [])]
            # ConditionalCheckFailed: a block is taken. TransactionConflict: someone else is writing
            # the same block right now. Either way this attempt did not win the time.
            if any(r in ("ConditionalCheckFailed", "TransactionConflict") for r in reasons):
                raise SlotTaken() from None
        raise


def _chunks(units: list[int]) -> list[list[int]]:
    return [units[i : i + CHUNK_CLAIMS] for i in range(0, len(units), CHUNK_CLAIMS)]


def write_claimed(put_item: dict, day: date, units: list[int], ref: str) -> None:
    """Writes one item (a block-off) together with a claim for every unit it covers. Raises SlotTaken if any is taken.

    The normal case is ONE transaction. Only when there are too many claims for one (a whole Saturday) are they
    written in chunks, the item with the first chunk. If a later chunk is refused, everything written so far is
    undone, so the caller sees the same all-or-nothing result either way.
    """
    if 1 + len(units) <= MAX_TRANSACTION_ITEMS:
        write_all_or_nothing([put_item] + [claim_put(day, u, ref) for u in units])
        return
    written: list[list[int]] = []
    try:
        for index, chunk in enumerate(_chunks(units)):
            write_all_or_nothing(([put_item] if index == 0 else []) + [claim_put(day, u, ref) for u in chunk])
            written.append(chunk)
    except Exception:
        _undo(put_item, day, written, ref)
        raise


def _undo(put_item: dict, day: date, written: list[list[int]], ref: str) -> None:
    """Best effort: releases the chunks already written, then the item. Never raises (the original error matters more)."""
    try:
        for chunk in written:
            table.client().transact_write_items(TransactItems=[claim_delete(day, u, ref, tolerant=True) for u in chunk])
        if written:
            item = put_item["Put"]["Item"]
            table.table().delete_item(Key={"pk": item["pk"], "sk": item["sk"]})
    except Exception:  # noqa: BLE001 - see docstring
        pass


def delete_claimed(delete_item: dict, day: date, units: list[int], ref: str) -> None:
    """Deletes one item (a block-off) and releases its claims: one transaction normally, chunks for a very long block.

    In chunks the claims go first and the item last, and releasing a claim that is already gone is fine, so if it is
    interrupted, removing the block again simply finishes the job. Raises the DynamoDB error if the item itself is gone.
    """
    if 1 + len(units) <= MAX_TRANSACTION_ITEMS:
        table.client().transact_write_items(TransactItems=[delete_item] + [claim_delete(day, u, ref) for u in units])
        return
    for chunk in _chunks(units):
        table.client().transact_write_items(TransactItems=[claim_delete(day, u, ref, tolerant=True) for u in chunk])
    table.client().transact_write_items(TransactItems=[delete_item])
