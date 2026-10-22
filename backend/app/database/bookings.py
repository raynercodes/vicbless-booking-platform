"""Bookings in the database: create, find, cancel."""

from __future__ import annotations

from datetime import date, datetime, timezone

from botocore.exceptions import ClientError

from ..core.errors import NotFound, SlotTaken
from ..domain import shop
from ..domain.models import Booking, new_id, parse_id
from . import keys, table, transactions
from .keys import PK


def booking_from(item: dict) -> Booking:
    """Turns a raw DynamoDB item into a Booking. (DynamoDB hands numbers back as Decimal, hence the int() calls.)"""
    return Booking(
        id=item["id"],
        code=item["code"],
        day=date.fromisoformat(item["date"]),
        start=int(item["start"]),
        minutes=int(item["minutes"]),
        service_id=item["serviceId"],
        name=item["name"],
        phone=item["phone"],
        email=item.get("email", ""),
        notes=item.get("notes", ""),
        created_at=item.get("createdAt", ""),
        service_name=item.get("serviceName", ""),
        held=tuple(int(u) for u in item.get("blocks", [])),
        sms_consent=bool(item.get("smsConsent", False)),
        updated_at=item.get("updatedAt", item.get("createdAt", "")),
        reminders_sent=tuple(str(t) for t in item.get("remindersSent", [])),
        payment=str(item.get("payment", "shop")),
        amount_cents=int(item.get("amountCents", 0)),
        checkout_id=str(item.get("checkoutId", "")),
        checkout_url=str(item.get("checkoutUrl", "")),
        hold_until=str(item.get("holdUntil", "")),
        payment_intent=str(item.get("paymentIntent", "")),
    )


def get_booking(booking_id: str) -> Booking | None:
    """Finds a booking from its id in one direct lookup (the id already contains the day and time)."""
    parsed = parse_id(booking_id)
    if not parsed:
        return None  # not an id we could have made, so there is nothing to look up
    day, start = parsed
    # ConsistentRead: always see the latest write (an eventually consistent read could miss a booking just made).
    item = table.table().get_item(Key={"pk": PK, "sk": keys.booking_sk(day, start, booking_id)}, ConsistentRead=True).get("Item")
    return booking_from(item) if item else None


def booking_holding(day: date, start: int) -> Booking | None:
    """The booking that owns the claim at this time, if there is one (used to spot a retried request)."""
    claim = table.table().get_item(Key={"pk": PK, "sk": keys.claim_sk(day, start)}, ConsistentRead=True).get("Item")
    if not claim:
        return None
    ref = str(claim.get("ref", ""))
    parsed = parse_id(ref)
    if not parsed or parsed[0] != day:
        return None
    return get_booking(ref)


def upcoming_for_phone(phone: str, from_day: date) -> int:
    """How many bookings this phone number has from `from_day` on. Eventually consistent on purpose:
    this is an anti-spam limit, not the guard against double booking."""
    resp = table.table().query(
        IndexName="gsi1",
        KeyConditionExpression="gsi1pk = :p AND gsi1sk >= :from",
        ExpressionAttributeValues={":p": f"PHONE#{phone}", ":from": f"{from_day.isoformat()}#"},
        Select="COUNT",
    )
    return int(resp.get("Count", 0))


def _booking_item(
    *, booking_id: str, day: date, start: int, service_id: str, service_name: str, minutes: int, name: str,
    phone: str, email: str, notes: str, code: str, created: str, updated: str, sms_consent: bool,
    payment: str = "shop", amount_cents: int = 0, checkout_id: str = "", checkout_url: str = "", hold_until: str = "",
    payment_intent: str = "",
) -> dict:  # fmt: skip
    """The raw DynamoDB item for a booking. One place builds it, so a new booking and a moved one can't differ."""
    item = {
        "pk": PK,
        "sk": keys.booking_sk(day, start, booking_id),
        "kind": "booking",
        "id": booking_id,
        "code": code,
        "date": day.isoformat(),
        "start": start,
        "minutes": minutes,
        "serviceId": service_id,
        "serviceName": service_name,
        "name": name,
        "phone": phone,
        "email": email,
        "notes": notes,
        "createdAt": created,
        "updatedAt": updated,  # made or last moved: reminders already past at this moment are skipped
        "smsConsent": sms_consent,
        "blocks": shop.occupied_starts(start, minutes),  # the claims it holds. Releasing exactly these is what keeps cancelling safe
        "units": True,  # claims are 5 minute units (items made before that are brought up to date by scripts/migrate_unit_claims.py)
        "gsi1pk": f"PHONE#{phone}",  # sparse index: lets us count a phone number's upcoming bookings
        "gsi1sk": f"{day.isoformat()}#{shop.hhmm(start)}",
        "expiresAt": keys.expires(day),
        "payment": payment,
        "amountCents": amount_cents,
    }
    # only what exists is stored: a pending booking has a checkout and a hold, a paid one has its payment
    for name, value in (
        ("checkoutId", checkout_id), ("checkoutUrl", checkout_url), ("holdUntil", hold_until), ("paymentIntent", payment_intent),
    ):  # fmt: skip
        if value:
            item[name] = value
    return item


def _hold_put(booking_id: str, day: date, until: str) -> dict:
    """The marker that lets a sweep find unpaid online bookings (see keys.hold_sk)."""
    return {
        "Put": {
            "TableName": table.table_name(),
            "Item": {"pk": PK, "sk": keys.hold_sk(until, booking_id), "kind": "hold", "ref": booking_id, "expiresAt": keys.expires(day)},
        }
    }


def _hold_delete(booking: Booking) -> dict:
    return {"Delete": {"TableName": table.table_name(), "Key": {"pk": PK, "sk": keys.hold_sk(booking.hold_until, booking.id)}}}


def create_booking(
    *, day: date, start: int, service_id: str, service_name: str, minutes: int, name: str, phone: str, email: str,
    notes: str, code: str, sms_consent: bool = False, payment: str = "shop", amount_cents: int = 0, hold_until: str = "",
) -> Booking:  # fmt: skip
    booking_id = new_id(day, start)
    claims = shop.occupied_starts(start, minutes)  # the 5 minute units this booking will hold
    created = datetime.now(timezone.utc).isoformat(timespec="seconds")
    item = _booking_item(
        booking_id=booking_id, day=day, start=start, service_id=service_id, service_name=service_name,
        minutes=minutes, name=name, phone=phone, email=email, notes=notes, code=code, created=created,
        updated=created, sms_consent=sms_consent, payment=payment, amount_cents=amount_cents, hold_until=hold_until,
    )  # fmt: skip
    # ONE transaction: the booking itself plus one claim per block. If any claim already exists the
    # whole thing is refused and nothing is written, so a booking can never be half-made.
    transaction = [
        {
            "Put": {
                "TableName": table.table_name(),
                "Item": item,
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }
    ] + [transactions.claim_put(day, s, booking_id) for s in claims]
    if payment == "pending":
        transaction.append(_hold_put(booking_id, day, hold_until))  # an unpaid booking is findable by when its hold ends
    transactions.write_all_or_nothing(transaction)
    return booking_from(item)


def cancel_booking(booking_id: str) -> Booking:
    """Deletes the booking and releases all its claims in one transaction (hard delete: the time is free at once)."""
    booking = get_booking(booking_id)
    if not booking:
        raise NotFound("That booking was not found. It may already be cancelled.")
    transaction = [
        {
            "Delete": {
                "TableName": table.table_name(),
                "Key": {"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
                "ConditionExpression": "attribute_exists(pk)",
            }
        }
    ] + [transactions.claim_delete(booking.day, s, booking.id) for s in booking.claims]
    if booking.payment == "pending" and booking.hold_until:
        transaction.append(_hold_delete(booking))
    try:
        table.client().transact_write_items(TransactItems=transaction)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            if get_booking(booking_id) is None:
                raise NotFound("That booking was not found. It may already be cancelled.") from None
        raise
    return booking


def move_booking(booking: Booking, *, day: date, start: int, minutes: int) -> Booking:
    """Moves a booking to a new day/time in ONE transaction, so it is never in two places or in none.

    The booking id contains its day and time, so a moved booking gets a NEW id (the customer's code stays
    the same). The transaction:
      - deletes the old booking item and creates the new one
      - releases the old units nobody needs any more, and claims the new ones (refused if any is taken)
      - for a unit that is in BOTH (moving a booking a little), hands it over in place

    `minutes` is the appointment length on the NEW day (the booking takes that day's slot).
    If anything fails, nothing changes: the booking stays exactly where it was.
    """
    new_booking_id = new_id(day, start)
    old_blocks = {(booking.day, s) for s in booking.claims}
    new_blocks = {(day, s) for s in shop.occupied_starts(start, minutes)}

    item = _booking_item(
        booking_id=new_booking_id, day=day, start=start, service_id=booking.service_id,
        service_name=booking.service_name, minutes=minutes, name=booking.name, phone=booking.phone,
        email=booking.email, notes=booking.notes, code=booking.code, created=booking.created_at,
        updated=datetime.now(timezone.utc).isoformat(timespec="seconds"), sms_consent=booking.sms_consent,
        payment=booking.payment, amount_cents=booking.amount_cents, checkout_id=booking.checkout_id,
        checkout_url=booking.checkout_url, hold_until=booking.hold_until, payment_intent=booking.payment_intent,
    )  # fmt: skip
    transaction = [
        {
            "Delete": {
                "TableName": table.table_name(),
                "Key": {"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
                "ConditionExpression": "attribute_exists(pk)",  # someone may have cancelled it a moment ago
            }
        },
        {"Put": {"TableName": table.table_name(), "Item": item, "ConditionExpression": "attribute_not_exists(pk)"}},
    ]
    transaction += [transactions.claim_delete(d, s, booking.id) for d, s in sorted(old_blocks - new_blocks)]
    transaction += [transactions.claim_put(d, s, new_booking_id) for d, s in sorted(new_blocks - old_blocks)]
    transaction += [transactions.claim_reassign(d, s, booking.id, new_booking_id) for d, s in sorted(old_blocks & new_blocks)]
    try:
        transactions.write_all_or_nothing(transaction)
    except SlotTaken:
        # Refused. Either the new time is taken, or the booking itself vanished (cancelled) in the meantime.
        if get_booking(booking.id) is None:
            raise NotFound("That booking was not found. It may already be cancelled.") from None
        raise
    return booking_from(item)


def attach_checkout(booking: Booking, session_id: str, url: str) -> None:
    """Remembers the Stripe Checkout Session of a booking that is waiting for payment."""
    table.table().update_item(
        Key={"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
        UpdateExpression="SET checkoutId = :i, checkoutUrl = :u",
        ConditionExpression="attribute_exists(pk) AND payment = :pending",
        ExpressionAttributeValues={":i": session_id, ":u": url, ":pending": "pending"},
    )


def mark_paid(booking: Booking, payment_intent: str) -> bool:
    """Pending -> paid, and the hold marker goes, in one transaction. True if THIS call did it; False if the booking was
    already paid, or is gone (cancelled, or its hold was released), so a payment event that arrives twice changes nothing."""
    transaction = [
        {
            "Update": {
                "TableName": table.table_name(),
                "Key": {"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
                "UpdateExpression": "SET payment = :paid, paymentIntent = :pi REMOVE holdUntil, checkoutUrl",
                "ConditionExpression": "attribute_exists(pk) AND payment = :pending",
                "ExpressionAttributeValues": {":paid": "paid", ":pi": payment_intent, ":pending": "pending"},
            }
        }
    ]
    if booking.hold_until:
        transaction.append(_hold_delete(booking))
    try:
        table.client().transact_write_items(TransactItems=transaction)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            return False
        raise
    return True


def holds_ending_before(until: str) -> list[tuple[str, str]]:
    """(booking id, when its hold ended) for unpaid online bookings whose hold ended before `until` (ISO UTC), oldest first."""
    resp = table.table().query(
        KeyConditionExpression="pk = :pk AND sk BETWEEN :lo AND :hi",
        ExpressionAttributeValues={":pk": PK, ":lo": "HOLD#", ":hi": f"HOLD#{until}~"},
        ConsistentRead=True,
    )
    return [(str(i["ref"]), str(i["sk"]).split("#")[1]) for i in resp.get("Items", [])]


def forget_hold(booking_id: str, until: str) -> None:
    """Removes a hold marker whose booking no longer exists."""
    table.table().delete_item(Key={"pk": PK, "sk": keys.hold_sk(until, booking_id)})
