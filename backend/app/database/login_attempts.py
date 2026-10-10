"""Failed sign-in counters, kept per source address (hashed) so Vic cannot be locked out by a stranger."""

from __future__ import annotations

import hashlib
import time

from . import table

LOGIN_WINDOW_SECONDS = 15 * 60
LOGIN_MAX_FAILURES = 5


def lock_key(source: str) -> dict:
    """Where one address's failure count lives. The address is hashed, so the table never stores a raw IP."""
    digest = hashlib.sha256(source.encode()).hexdigest()[:24]
    return {"pk": f"LOCK#{digest}", "sk": "LOGIN"}


def login_locked(source: str, now: float | None = None) -> bool:
    """True if this address has failed 5 times and the 15 minute window is still running.

    The expiry is checked in code too: DynamoDB's TTL deletion can lag by many hours, so an old
    record must not keep someone locked out.
    """
    now = time.time() if now is None else now
    item = table.table().get_item(Key=lock_key(source), ConsistentRead=True).get("Item")
    return bool(item and int(item["expiresAt"]) > now and int(item["failures"]) >= LOGIN_MAX_FAILURES)


def record_login_failure(source: str, now: float | None = None) -> None:
    """Counts one wrong password. The first failure starts a fresh 15 minute window."""
    now = int(time.time() if now is None else now)
    key = lock_key(source)
    item = table.table().get_item(Key=key, ConsistentRead=True).get("Item")
    if not item or int(item["expiresAt"]) <= now:
        table.table().put_item(Item={**key, "failures": 1, "expiresAt": now + LOGIN_WINDOW_SECONDS})
        return
    table.table().update_item(
        Key=key,
        UpdateExpression="ADD #f :one",
        ExpressionAttributeNames={"#f": "failures"},
        ExpressionAttributeValues={":one": 1},
    )


def clear_login_failures(source: str) -> None:
    """A correct password wipes the count."""
    table.table().delete_item(Key=lock_key(source))
