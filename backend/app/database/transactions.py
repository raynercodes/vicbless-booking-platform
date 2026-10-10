"""Why double booking cannot happen: every 35 minute block of every day gets one "claim" item whose
key is unique to that block. A booking (or a block-off) is written together with all the claims it
needs in ONE transaction, and each claim must not already exist. If any claim is taken, nothing is
written. DynamoDB decides who wins when two people try for the same block at once.
"""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import SlotTaken
from . import keys, table
from .keys import PK


def claim_put(day: date, start: int, ref: str) -> dict:
    """ "Reserve this block for `ref`": creates the claim, but ONLY if nobody has it yet."""
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
            "ConditionExpression": "attribute_not_exists(pk)",
        }
    }


def claim_delete(day: date, start: int, ref: str) -> dict:
    """ "Release this block": deletes the claim, but ONLY if it still belongs to `ref` (never someone else's)."""
    return {
        "Delete": {
            "TableName": table.table_name(),
            "Key": {"pk": PK, "sk": keys.claim_sk(day, start)},
            "ConditionExpression": "#ref = :ref",  # "ref" is a reserved word in DynamoDB, so it needs a name alias
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
