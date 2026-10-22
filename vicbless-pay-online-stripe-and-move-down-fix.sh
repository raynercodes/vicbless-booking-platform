#!/usr/bin/env bash
# Pay online with Stripe or at the shop, and the Move Down fix
# Run from the REPO ROOT:  bash vicbless-pay-online-stripe-and-move-down-fix.sh
#
# Adds Stripe Checkout (pay online or at the shop), shows Vic how each booking is paid, refunds a paid booking
# Vic cancels, holds the time while a customer pays, and fixes the Move Down button overflowing on phones.
#
# Safe by design: before anything is written, every file this touches is compared with the version this script was built
# against. If any of them was edited since, NOTHING is changed and the script lists which ones (FORCE=1 overrides that).
# Running it twice is harmless. It runs no git commands.
set -euo pipefail
if [ ! -d .git ] || [ ! -d frontend/src ] || [ ! -d backend/app ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git, frontend/ and backend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/0" <<'VICBLESS_EOF'
# Backend

Python 3.12, FastAPI on AWS Lambda (through Mangum), DynamoDB. Deployed by `infra/template.yaml` and
`.github/workflows/deploy-backend.yml`. Every route is under `/api`. There is no `/docs` in any environment.

## Where things live
```
backend/
  app/
    main.py        builds the app (routers, error handling, middleware) and nothing else
    handler.py     the AWS Lambda entry point
    routes/        the URLs. public.py (health, availability, bookings), admin.py (Vic's routes), deps.py (shared helpers)
    services/      what happens: bookings.py, blocks.py, auth.py, schedule.py, notifications.py (emails and texts), reminders.py
    database/      everything that touches DynamoDB: bookings.py, blocks.py, schedule.py (reads),
                   login_attempts.py, keys.py (how items are named), transactions.py (the no-double-booking write), table.py
    domain/        the shop itself: shop.py (hours, default services and appointment lengths, booking rules) and models.py (Booking, Block, ids)
    schemas/       requests.py: what the site is allowed to send, cleaned and checked
    core/          config.py (settings + AWS secrets), security.py (password + session), aws.py, logs.py, errors.py, web.py (headers, CORS, error JSON)
    emailing/      email providers: resend.py (today), templates.py (the emails)
    texting/       text message providers: textbelt.py (today), templates.py (the texts)
    payments/      Stripe: stripe.py (payment pages, refunds), webhook.py (checks a message really came from Stripe)
  tests/
    fixtures/      what pytest sets up for you: aws.py (fake AWS + the table, built from infra/template.yaml),
                   clock.py (frozen "now"), api.py (client, signed-in Vic), email.py (catches outgoing emails)
    helpers/       shared test data and shortcuts: builders.py, api.py, aws.py, template.py, constants.py
    test_*.py      the tests themselves, one file per topic; test_structure.py enforces the layering,
                   test_messages.py checks every message people read, test_contract.py checks the site and API agree
  scripts/         hash_password.py (makes Vic's sign-in secrets)
```
Each layer only talks to the ones below it: **routes -> services -> database -> domain -> core**
(`test_structure.py` fails if that is broken, or if anything but the web layer imports FastAPI).

**Where do I change...?**
- the shop's opening hours: `domain/shop.py` (and `frontend/src/config.js`, a test checks they match)
- the services, prices and appointment lengths: Vic edits these himself in the dashboard (Settings). The values a fresh
  database starts with are `DEFAULT_SETTINGS` in `domain/shop.py` (Monday and Tuesday 45 minutes, the rest 35)
- what a customer may type in the form: `schemas/requests.py`
- what happens when someone books, cancels or is moved: `services/bookings.py`
- a URL or its response: `routes/`
- how it is stored: `database/`
- the wording of an email: `emailing/templates.py`; of a text: `texting/templates.py`
- when reminders go out: Vic picks the times in Shop settings; the 15 minute sweep is `services/reminders.py`

## Environments
`dev` is the staging environment for this project. `prod` is the real one. Nothing else.

## Endpoints
| Method and path | Who | What |
|---|---|---|
| `GET /api/health` | anyone | status, environment, deployed version |
| `GET /api/availability?from=YYYY-MM-DD&to=YYYY-MM-DD` | anyone | `{ "2026-10-13": { "busy": [720, 755], "dayOff": false } }` (up to 31 days) |
| `POST /api/bookings` | anyone | 201 new booking, 200 if the same request is repeated, 409 `slot_taken` / `slot_unavailable`, 422 `invalid_slot` / `validation_error`, 429 `too_many_bookings` |
| `POST /api/stripe/webhook` | Stripe | tells us a payment was made or ran out; refused (400) unless the signature checks out |
| `POST /api/admin/login` | Vic | `{ "password" }` gives `{ "token", "expiresIn" }`; 5 wrong tries in 15 minutes locks that address out |
| `GET /api/admin/schedule?date=` | Vic | `{ dateKey, items, blocks }` |
| `DELETE /api/admin/bookings/{id}` | Vic | cancels, frees the time, emails the customer if they left an email |
| `PATCH /api/admin/bookings/{id}` | Vic | moves a booking to another day/time (any open time up to a year ahead); the booking gets a new id, the customer keeps their code; emails the customer if they left an email |
| `POST /api/admin/blocks` | Vic | `{ dateKey, start, end, note }` or `{ dateKey, whole: true }` |
| `DELETE /api/admin/blocks/{id}` | Vic | opens the time back up |

Admin calls send `Authorization: Bearer <token>`. Errors are always `{ "error": { "code", "message" } }`.

## How double booking is prevented
Time is counted in 5 minute units. Each unit of each day is one DynamoDB item that can only be created once. A
booking (or a block-off) writes every unit it covers, and itself, in a single transaction that fails as a whole if
any unit already exists. Because the units are small, the appointment length can differ by weekday and change later;
an older booking still blocks exactly the time it covers. A very long block-off is written in pieces and undone if a
later piece is refused.
The availability list is only for display; the transaction is the real guard.

## One-time upgrade after the settings release
Bookings made before it hold fewer units. Deploy the backend, then for each environment:
`AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev` (shows what it would do), then again
with `--apply`. It only adds free claims, is safe to repeat, and reports (never overwrites) a conflict.

## Settings in AWS (SSM Parameter Store, `/vicbless/<env>/...`)
`pepper`, `jwt-secret`, `admin-password-hash`, `resend-api-key` (SecureString) and `owner-email`,
`email-from` (String). `stripe-secret-key` and `stripe-webhook-secret` (SecureString, see Paying online). `app-version` is written by the deploy workflow.
Make the first three with `python backend/scripts/hash_password.py --env dev`.

## Reading the logs (CloudWatch)
Log group `/aws/lambda/vicbless-api-<env>`. Every line is JSON with an `event` and the request's `requestId`. Never any names,
phone numbers, emails or keys. In CloudWatch Logs Insights, pick the log group and try:
```
fields @timestamp, event, kind, to, reason, provider | filter event like /sms_|email_/ | sort @timestamp desc | limit 50
fields @timestamp, event, bookingId, smsConsent, hasEmail | filter event like /booking_/ | sort @timestamp desc
fields @timestamp, event, code, status, field | filter event in ["api_error","validation_failed","unhandled_error"] | sort @timestamp desc
fields @timestamp, event, name, code | filter event in ["param_missing","param_error"] | sort @timestamp desc
fields @timestamp, event, examined, sent, errors | filter event in ["scheduled_event","reminders_swept"] | sort @timestamp desc
```
The events that answer "why no text?": `sms_sent` (went to Textbelt and was accepted), `sms_skipped` + `reason` (`no_consent`,
`no_owner_phone`, `bad_number`, `no_provider`), `sms_error`/`sms_failed` (Textbelt refused it, `reason` is their words), `sms_accepted`
(Textbelt's id and the credit left), `param_missing name=textbelt-key` (the key was never stored).

## Texts and reminders
Textbelt for now (`app/texting/textbelt.py`). Setup per environment (run with `AWS_PROFILE=vicbless`):
`textbelt-key` (SecureString: the key bought at textbelt.com; the key `textbelt` is a free test key, about one text a
day) and `owner-phone` (String: Vic's mobile, he is texted about every new booking). Without a key texts are skipped and
logged, nothing breaks. A customer is texted only if they ticked "text me" on the booking form. Textbelt answers STOP replies
itself. When the AWS SMS account is approved: add `texting/aws.py`, add it to `get_sender()`, set `SMS_PROVIDER=aws`,
delete `textbelt.py`.
Reminders: the same Lambda runs `services/reminders.py` every 15 minutes (EventBridge schedule in `infra/template.yaml`).
Vic chooses the times (24 and 2 hours before to start with) in Shop settings. Each one is marked on the booking as sent first,
so it goes out once.

## Paying online (Stripe)
A customer can choose "Pay online now" on the booking form (only offered once both secrets below exist, so nothing breaks
before then). The booking is made at once and its time is **held for 31 minutes** (`payment = pending`) while they pay on
Stripe's page. Nobody is told about it yet. Stripe's signed message to `/api/stripe/webhook` then either confirms it
(`paid`: Vic and the customer are told, and Vic sees "Paid online" on the card) or says the page ran out (the time is freed).
The 15 minute sweep frees any hold whose message never arrived, after asking Stripe, so a payment that did go through is
confirmed instead of lost. A booking Vic cancels after it was paid is **refunded in full first**; if the refund fails nothing
is cancelled. (Stripe keeps its card fee on a refund.) Prices are the listed prices in dollars; a "starting at" service is
charged its starting price, and Vic settles any difference at the shop.

Setup per environment (run with `AWS_PROFILE=vicbless`). Use `sk_test_...` keys for dev and live keys for prod.
1. Stripe dashboard > Developers > API keys: copy the **Secret key**.
2. Developers > Webhooks > Add endpoint: URL `https://<ApiDomainName>/api/stripe/webhook` (the backend stack's API Gateway
   address, so CloudFront and the dev preview key are not in the way), events `checkout.session.completed`,
   `checkout.session.expired` and `checkout.session.async_payment_succeeded`. Copy its **Signing secret** (`whsec_...`).
3. `aws ssm put-parameter --name /vicbless/<env>/stripe-secret-key --type SecureString --value 'sk_...' --overwrite`
   and the same for `stripe-webhook-secret` with the signing secret. Within five minutes the booking page offers the choice.
4. Try it with the test card `4242 4242 4242 4242` (any future date, any code).
Logs to look for: `stripe_checkout_created`, `webhook_handled` (with `outcome`), `payment_confirmed`, `payment_hold_released`,
`payment_refunded`, and `payment_orphaned` / `webhook_rejected` when something is off.

## Email
Resend for now (`app/emailing/resend.py`). Until a domain is verified in Resend it can only send from
`onboarding@resend.dev` to the Resend account's own email. When SES is approved: add `emailing/ses.py`,
add it to `get_sender()`, set `EMAIL_PROVIDER=ses`, delete `resend.py`. A failed email never fails a booking.

## Known limits
- The sign-in lockout counts per address as API Gateway sees it. Behind CloudFront that is the CloudFront
  edge, so treat it as a coarse brake; API Gateway also throttles the login route hard.
- A booking and its confirmation email happen in one request. If Resend is slow the customer waits up to a few seconds.
- Bookings disappear from the database about 90 days after their day (DynamoDB TTL).

## Tests
From the repo root: `pip install -r backend/requirements-dev.txt && pytest backend/tests/ -v`
The tests use a fake AWS (moto), and the fake table is created from the real definition in
`infra/template.yaml`, so the tests can't pass against a table shape that isn't the deployed one.
`test_contract.py` reads `frontend/src/config.js` and fails if the hours, services, slot length or
input limits (name 50, notes 500) there differ from `app/domain/shop.py` and `app/schemas/requests.py`.
VICBLESS_EOF
cat > "$STAGE/1" <<'VICBLESS_EOF'
"""Errors the API turns into the JSON shape { "error": { "code", "message" } }.

Each error carries three things the site needs:
  status   the HTTP status code
  code     a short stable word the frontend can branch on (for example "slot_taken")
  message  a sentence that is safe to show a customer or Vic as it is, so keep them friendly and plain
Raise one of these from anywhere in the app; core/web.py turns it into the response.
"""

from .brand import CONTACT_EMAIL


class ApiError(Exception):
    status = 400
    code = "bad_request"

    field: str | None = None  # which form field the problem is about, when it is about one

    def __init__(self, message: str | None = None, *, code: str | None = None, field: str | None = None):
        super().__init__(message or self.default_message)
        self.message = message or self.default_message
        if code:
            self.code = code
        if field:
            self.field = field

    default_message = "Something went wrong with that request. Please try again."


class ValidationFailed(ApiError):
    status = 422
    code = "validation_error"
    default_message = "Some of the details aren't valid. Please check them and try again."


class InvalidSlot(ApiError):
    """The time can never be booked: closed day, off the grid, or does not fit in the day."""

    status = 422
    code = "invalid_slot"
    default_message = "That isn't a time Vic takes bookings for. Please pick another."


class SlotUnavailable(ApiError):
    """The time could be booked in general but not right now: past, too soon, or too far ahead."""

    status = 409
    code = "slot_unavailable"
    default_message = "That time is no longer available. Please pick another."


class SlotTaken(ApiError):
    status = 409
    code = "slot_taken"
    default_message = "Sorry, that time was just taken. Please pick another."


class Conflict(ApiError):
    status = 409
    code = "conflict"
    default_message = "That overlaps a booking or time you already blocked off."


class NotFound(ApiError):
    status = 404
    code = "not_found"
    default_message = "We couldn't find that."


class Unauthorized(ApiError):
    status = 401
    code = "unauthorized"
    default_message = "Please sign in to continue."


class TooManyBookings(ApiError):
    status = 429
    code = "too_many_bookings"
    default_message = f"This phone number already has the most upcoming bookings we allow. Please email Vic at {CONTACT_EMAIL} to change one."


class TooManyAttempts(ApiError):
    status = 429
    code = "too_many_attempts"
    default_message = "Too many tries. Please wait about 15 minutes, then try again."


class NotConfigured(ApiError):
    status = 503
    code = "not_configured"
    default_message = "This part of the service isn't set up yet."


class PaymentUnavailable(ApiError):
    """Stripe could not be reached or refused, or online payment is not set up."""

    status = 503
    code = "payment_unavailable"
    default_message = "Online payment isn't available right now. Please choose to pay at the shop, or try again in a minute."


class RefundFailed(ApiError):
    status = 502
    code = "refund_failed"
    default_message = (
        "The card couldn't be refunded, so nothing was cancelled. Try again in a minute, "
        "or refund it in your Stripe dashboard first."
    )


class BadWebhook(ApiError):
    status = 400
    code = "bad_signature"
    default_message = "That message did not come from Stripe."
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 5 minute unit (a 45 minute booking holds nine)
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
    HOLD#<until, ISO UTC>#<booking id>    an unpaid online booking whose time is held until <until> (a sweep finds the
                                          old ones; "HOLD#" sorts after every date, so a day's range never includes it)
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


def hold_sk(until: str, booking_id: str) -> str:
    """The sort key of the marker for an unpaid online booking. `until` is an ISO UTC time, so the markers sort by it."""
    return f"HOLD#{until}#{booking_id}"


def block_sk(day: date, start: int, block_id: str) -> str:
    return f"{day.isoformat()}#BLOCK#{shop.hhmm(start)}#{block_id}"


def minutes_of(hhmm: str) -> int:
    """'1235' -> 755 minutes after midnight (the reverse of shop.hhmm)."""
    return int(hhmm[:2]) * 60 + int(hhmm[2:])
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""The things the shop deals with: bookings, blocked time, and their ids.

Plain frozen dataclasses. No web or AWS code in here.
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass
from datetime import date

from . import shop

# Booking codes skip look-alike characters (no 0/O, 1/I/L) so they are easy to read out over the phone.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

# The exact shape of an id we create. Anything else (a typo, an attack) is rejected before touching the database.
ID_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})\.(\d{4})\.([0-9a-f]{8})$")


def new_id(day: date, start: int) -> str:
    """'2026-10-12.0720.9f3a1c2b'. The date and start are inside it, so cancelling is a direct lookup."""
    return f"{day.isoformat()}.{shop.hhmm(start)}.{secrets.token_hex(4)}"


def parse_id(value: str) -> tuple[date, int] | None:
    """Returns (date, start minutes), or None if the id is not one we could have made."""
    m = ID_PATTERN.match(value or "")
    if not m:
        return None
    try:
        day = date.fromisoformat(m.group(1))
    except ValueError:
        return None
    hh, mm = int(m.group(2)[:2]), int(m.group(2)[2:])
    if hh > 23 or mm > 59:
        return None
    return day, hh * 60 + mm


def new_code() -> str:
    """A friendly code the customer keeps, like VB-K7M2QX. `secrets` (not `random`) so codes can't be predicted."""
    return "VB-" + "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))


@dataclass(frozen=True)
class Booking:
    """One customer's appointment. `id` is internal (used by Vic's dashboard); `code` is what the customer sees."""

    id: str
    code: str
    day: date
    start: int
    minutes: int
    service_id: str
    name: str
    phone: str
    email: str
    notes: str
    created_at: str
    # The service's name as it was when the customer booked, so a service Vic later renames or removes
    # still reads correctly on old bookings, emails and the dashboard.
    service_name: str = ""
    # The claims (5 minute units) the database really holds for this booking, read from its item. A booking made
    # before units existed holds fewer, and releasing exactly what is held is what keeps cancelling safe.
    held: tuple[int, ...] = ()
    # Did the customer tick "text me"? Texts to a customer go out only when they did.
    sms_consent: bool = False
    # When the booking was made or last moved (ISO, UTC). A reminder whose time had already passed by then is skipped.
    updated_at: str = ""
    # Which reminders were already sent, like "24h". Keeps a reminder from going out twice.
    reminders_sent: tuple[str, ...] = ()
    # How it is paid. "shop": at the shop. "pending": the customer chose to pay online and has not finished yet (the time
    # is held for a little while). "paid": paid online. `amount_cents` is the service's price when it was booked.
    payment: str = "shop"
    amount_cents: int = 0
    checkout_id: str = ""  # Stripe's Checkout Session for a pending booking
    checkout_url: str = ""  # where the customer pays it
    hold_until: str = ""  # a pending booking's time is held until then (ISO, UTC)
    payment_intent: str = ""  # Stripe's payment, once paid (what a refund needs)

    @property
    def price_label(self) -> str:
        """'$65' or '$65.50'; empty for a booking made before prices were stored."""
        if self.amount_cents <= 0:
            return ""
        dollars, cents = divmod(self.amount_cents, 100)
        return f"${dollars}" if not cents else f"${dollars}.{cents:02d}"

    @property
    def payment_label(self) -> str:
        """How it is paid, for Vic: 'Paid online ($65)', 'Pay at the shop ($65)' or 'Waiting for online payment ($65)'."""
        base = {"paid": "Paid online", "pending": "Waiting for online payment"}.get(self.payment, "Pay at the shop")
        return f"{base} ({self.price_label})" if self.price_label else base

    @property
    def claims(self) -> list[int]:
        """The 5 minute units this booking holds in the database."""
        return list(self.held) if self.held else shop.occupied_starts(self.start, self.minutes)

    def admin_view(self) -> dict:
        """What Vic's dashboard shows, contact details included."""
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "source": "online",
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
            "serviceName": self.service_name,
            "name": self.name,
            "phone": self.phone,
            "email": self.email,
            "notes": self.notes,
            "code": self.code,
            "smsConsent": self.sms_consent,
            "payment": self.payment,
            "amountCents": self.amount_cents,
        }

    def public_view(self) -> dict:
        """What the customer gets back. The internal id is left out."""
        view = {
            "code": self.code,
            "dateKey": self.day.isoformat(),
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
            "staffId": shop.STAFF_ID,
            "payment": self.payment,
        }
        if self.payment == "pending" and self.checkout_url:
            view["checkoutUrl"] = self.checkout_url  # the page where they pay; the site sends them there
        return view


@dataclass(frozen=True)
class Block:
    """Time Vic blocked off (lunch, a day off). `claims` are the 5 minute units it covers."""

    id: str
    day: date
    start: int
    end: int
    note: str
    whole: bool
    claims: tuple[int, ...]

    def admin_view(self) -> dict:
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "start": self.start,
            "end": self.end,
            "note": self.note,
            "whole": self.whole,
        }
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
"""The emails. Everything a customer typed is HTML-escaped; subjects have line breaks removed.

Every email ends with the same branded block (VICBLESS BARBERSHOP, the tagline, the address and the contact
email), in both the HTML and the plain-text version, so a customer can always tell who it is from.
"""

from __future__ import annotations

from html import escape

from ..core.brand import ADDRESS_LINES, BRAND_NAME, BRAND_TAGLINE, CONTACT_EMAIL
from ..domain import shop
from ..domain.models import Booking
from . import EmailMessage


def _when(booking: Booking) -> str:
    """'Tuesday, October 13 at 12:00 pm'."""
    d = booking.day
    return f"{d:%A}, {d:%B} {d.day} at {shop.label(booking.start)}"


def _subject(text: str) -> str:
    """Subjects can't contain line breaks (a way to sneak extra email headers in), so squash them to spaces."""
    return " ".join(text.replace("\r", " ").replace("\n", " ").split())


def _service_name(booking: Booking) -> str:
    """The service as it was named when the customer booked. (Bookings made before the name was stored fall back to the
    shop's starting list, and as a last resort to the id.)"""
    if booking.service_name:
        return booking.service_name
    service = shop.DEFAULT_SETTINGS.service(booking.service_id)
    return service.name if service else booking.service_id


# The site's colors: a dark purple-black ground with the lavender accent, so the email feels like the website.
_INK = "#0a0612"
_ACCENT = "#c084fc"
_SOFT = "#e9e0f7"
_MUTED = "#b8a9d0"


def brand_text() -> str:
    """The branded ending of the plain-text version of every email."""
    return f"{BRAND_NAME}\n{BRAND_TAGLINE}\n{', '.join(ADDRESS_LINES)}\n{CONTACT_EMAIL}\n"


def brand_html() -> str:
    """The branded ending of the HTML version. A table with inline styles, because that is what email apps render reliably.

    Plain text on purpose, not an image: many email apps hide pictures until the reader allows them, and a logo that is
    switched off would leave this block empty.
    """
    address = " &middot; ".join(escape(line) for line in ADDRESS_LINES)
    mail = escape(CONTACT_EMAIL, quote=True)
    return (
        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="{_INK}" '
        f'style="margin-top:28px;background:{_INK};border-radius:12px"><tr><td align="center" style="padding:24px 16px">'
        f'<div style="font-family:Arial Black,Arial,sans-serif;font-weight:900;font-size:22px;letter-spacing:3px;'
        f'color:{_ACCENT}">{escape(BRAND_NAME)}</div>'
        f'<div style="margin-top:6px;font-size:13px;color:{_SOFT}">{escape(BRAND_TAGLINE)}</div>'
        f'<div style="margin-top:12px;font-size:12px;line-height:1.5;color:{_MUTED}">{address}<br>'
        f'<a href="mailto:{mail}" style="color:{_ACCENT};text-decoration:underline">{escape(CONTACT_EMAIL)}</a></div>'
        "</td></tr></table>"
    )


def _page(title: str, rows: list[tuple[str, str]], footer: str) -> str:
    body = "".join(
        f'<tr><td style="padding:4px 16px 4px 0;color:#666">{escape(k)}</td><td style="padding:4px 0">{v}</td></tr>'
        for k, v in rows
    )
    return (
        '<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#111">'
        f'<h2 style="margin:0 0 12px">{escape(title)}</h2>'
        f'<table style="border-collapse:collapse">{body}</table>'
        f'<p style="margin-top:16px;color:#444">{escape(footer)}</p>'
        f"{brand_html()}</div>"
    )


def customer_confirmation(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Barber", "Vic"),
        ("Your code", f"<strong>{escape(booking.code)}</strong>"),
    ]
    paying = "Paid online, thank you." if booking.payment == "paid" else "Pay at the shop."
    footer = f"{paying} Need to change something? Reply to this email or write to {CONTACT_EMAIL} and quote your code."
    text = (
        f"You're booked with Vic.\n\nWhen: {when}\nService: {_service_name(booking)}\nYour code: {booking.code}\n\n{footer}\n\n"
        f"{brand_text()}"
    )
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"You're booked: {when}"),
        text=text,
        html=_page("You're booked with Vic", rows, footer),
        reply_to=owner_email,
    )


def owner_notification(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    email_cell = (
        f'<a href="mailto:{escape(booking.email, quote=True)}">{escape(booking.email)}</a>' if booking.email else "none given"
    )
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Payment", escape(booking.payment_label)),
        ("Name", escape(booking.name)),
        ("Phone", escape(booking.phone)),
        ("Email", email_cell),
        ("Notes", escape(booking.notes).replace("\n", "<br>") or "none"),
        ("Code", escape(booking.code)),
    ]
    text = (
        f"New booking\n\nWhen: {when}\nService: {_service_name(booking)}\nPayment: {booking.payment_label}\nName: {booking.name}\n"
        f"Phone: {booking.phone}\nEmail: {booking.email or 'none given'}\n"
        f"Notes: {booking.notes or 'none'}\nCode: {booking.code}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=owner_email,
        subject=_subject(f"New booking: {booking.name}, {when}"),
        text=text,
        html=_page("New booking", rows, "It is already on your schedule."),
        reply_to=booking.email,
    )


def customer_cancellation(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    footer = "Sorry about the change. You can book a new time anytime on the site."
    if booking.payment == "paid":
        footer = f"Your online payment is being refunded to your card. It can take a few days to show up. {footer}"
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"Your appointment was cancelled: {when}"),
        text=f"Your appointment with Vic on {when} was cancelled.\n\n{footer}\n\n{brand_text()}",
        html=_page("Your appointment was cancelled", [("Was booked for", escape(when))], footer),
        reply_to=owner_email,
    )


def customer_rescheduled(before: Booking, after: Booking, owner_email: str) -> EmailMessage:
    """Sent to the customer when Vic moves their appointment. Shows the old and the new time."""
    old_when, new_when = _when(before), _when(after)
    footer = f"If this time doesn't work for you, reply to this email or write to {CONTACT_EMAIL}."
    rows = [
        ("New time", f"<strong>{escape(new_when)}</strong>"),
        ("Was", escape(old_when)),
        ("Service", escape(_service_name(after))),
        ("Your code", escape(after.code)),
    ]
    text = (
        f"Vic moved your appointment.\n\nNew time: {new_when}\nWas: {old_when}\n"
        f"Service: {_service_name(after)}\nYour code: {after.code}\n\n{footer}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=after.email,
        subject=_subject(f"Your appointment was moved: {new_when}"),
        text=text,
        html=_page("Your appointment was moved", rows, footer),
        reply_to=owner_email,
    )


def customer_reminder(booking: Booking, owner_email: str) -> EmailMessage:
    """'See you soon': the same details as the confirmation, sent a set time before the appointment."""
    when = _when(booking)
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Where", escape(", ".join(ADDRESS_LINES))),
        ("Your code", f"<strong>{escape(booking.code)}</strong>"),
    ]
    paying = "Already paid online." if booking.payment == "paid" else "Pay at the shop."
    footer = f"{paying} Need to change it? Write to {CONTACT_EMAIL} and quote your code."
    text = (
        f"A reminder of your appointment with Vic.\n\nWhen: {when}\nService: {_service_name(booking)}\n"
        f"Where: {', '.join(ADDRESS_LINES)}\nYour code: {booking.code}\n\n{footer}\n\n{brand_text()}"
    )
    return EmailMessage(
        to=booking.email,
        subject=_subject(f"Reminder: your appointment {when}"),
        text=text,
        html=_page("See you soon", rows, footer),
        reply_to=owner_email,
    )
VICBLESS_EOF
cat > "$STAGE/6" <<'VICBLESS_EOF'
"""AWS Lambda entry point. Two kinds of events arrive here:

  - web requests from API Gateway (HTTP API) -> Mangum -> FastAPI
  - a scheduled event from EventBridge every 15 minutes -> the reminder sweep (services/reminders.py), and giving back
    the time of online bookings that were never paid (services/payments.py)
"""

from mangum import Mangum

from .core.logs import log
from .main import app
from .domain import shop
from .services import payments, reminders

_web = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    # A scheduled EventBridge event says source "aws.events". Web requests never do.
    if isinstance(event, dict) and event.get("source") == "aws.events":
        log("scheduled_event", kind="reminders")  # proves the 15 minute timer is firing
        result = reminders.send_due()
        result["holdsReleased"] = payments.release_expired(shop.now_local())  # unpaid online bookings whose time ran out
        return result
    return _web(event, context)
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
"""Taking card payments online. The rest of the app only knows about this module's functions and PaymentError.

The provider is Stripe Checkout: the customer is sent to a payment page Stripe hosts, so card numbers never touch this
app. Stripe tells us the result with a signed message (a webhook, see payments/webhook.py).

Two secrets live in Parameter Store (/vicbless/<env>/): `stripe-secret-key` and `stripe-webhook-secret`. Until the key is
set, "pay online" simply is not offered and every booking is paid at the shop.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..core import config
from ..core.logs import log


class PaymentError(Exception):
    """Stripe refused, or could not be reached. `code` is Stripe's own short reason (never a card detail) when it gave one."""

    def __init__(self, message: str, code: str = ""):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class CheckoutSession:
    id: str
    url: str


@dataclass(frozen=True)
class SessionStatus:
    """What Stripe says about a Checkout Session: status is 'open', 'complete' or 'expired'."""

    id: str
    status: str
    paid: bool
    payment_intent: str


def secret_key() -> str | None:
    return config.params.get("stripe-secret-key") or None


def webhook_secret() -> str | None:
    return config.params.get("stripe-webhook-secret") or None


def configured() -> bool:
    """Is online payment set up? False when the key is missing, or the parameter store could not be read."""
    try:
        return bool(secret_key() and webhook_secret())
    except Exception as exc:  # a health check of the setup must never break the booking page
        log("payments_setup_failed", reason=type(exc).__name__)
        return False


def get_client():
    """The Stripe client, or None when no key is set up."""
    from .stripe import StripeClient

    key = secret_key()
    return StripeClient(secret_key=key) if key else None
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
"""Talks to Stripe with the standard library only, so it adds nothing to the Lambda package.

API: https://stripe.com/docs/api. Requests are form-encoded POSTs with the secret key as a Bearer token.
The key is never logged. Neither is anything about the customer: only Stripe's ids and short error codes.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from ..core.logs import log
from . import CheckoutSession, PaymentError, SessionStatus

API = "https://api.stripe.com/v1"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 8


def _flatten(fields: dict, prefix: str = "") -> list[tuple[str, str]]:
    """{'a': {'b': 1}, 'c': [{'d': 2}]} -> [('a[b]', '1'), ('c[0][d]', '2')]: how Stripe wants nested fields."""
    out: list[tuple[str, str]] = []
    for name, value in fields.items():
        key = f"{prefix}[{name}]" if prefix else str(name)
        if isinstance(value, dict):
            out += _flatten(value, key)
        elif isinstance(value, (list, tuple)):
            out += _flatten({str(i): v for i, v in enumerate(value)}, key)
        elif value is not None:
            out.append((key, str(value)))
    return out


class StripeClient:
    def __init__(self, secret_key: str):
        self.secret_key = secret_key

    def _call(self, method: str, path: str, fields: dict | None = None, idempotency_key: str = "") -> dict:
        headers = {"Authorization": f"Bearer {self.secret_key}", "User-Agent": USER_AGENT}
        data = None
        if method == "POST":
            data = urllib.parse.urlencode(_flatten(fields or {})).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            if idempotency_key:
                headers["Idempotency-Key"] = idempotency_key  # the same request twice makes ONE session or refund
        request = urllib.request.Request(f"{API}{path}", data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                answer = json.loads(response.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            code = ""
            try:
                code = str(json.loads(err.read().decode()).get("error", {}).get("code") or "")[:80]
            except Exception:  # noqa: BLE001 - an unreadable error body is fine, the status is enough
                pass
            log("stripe_failed", path=path.split("/")[1], status=err.code, code=code)
            raise PaymentError(f"Stripe answered {err.code}", code) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            log("stripe_failed", path=path.split("/")[1], reason=type(err).__name__)
            raise PaymentError("Could not reach Stripe") from None
        if not isinstance(answer, dict):
            raise PaymentError("Stripe sent something unexpected")
        return answer

    def create_checkout_session(
        self, *, booking_id: str, code: str, amount_cents: int, product_name: str, success_url: str, cancel_url: str,
        expires_at: int, customer_email: str = "",
    ) -> CheckoutSession:  # fmt: skip
        """A payment page for one booking. `expires_at` (Unix time) must be 30 minutes to 24 hours from now."""
        answer = self._call(
            "POST",
            "/checkout/sessions",
            {
                "mode": "payment",
                "success_url": success_url,
                "cancel_url": cancel_url,
                "expires_at": expires_at,
                "customer_email": customer_email or None,
                "client_reference_id": code,
                "metadata": {"bookingId": booking_id, "code": code},
                "payment_intent_data": {"metadata": {"bookingId": booking_id, "code": code}},
                "line_items": [
                    {
                        "quantity": 1,
                        "price_data": {"currency": "usd", "unit_amount": amount_cents, "product_data": {"name": product_name}},
                    }
                ],
            },
            idempotency_key=f"checkout-{booking_id}",
        )
        if not answer.get("id") or not answer.get("url"):
            raise PaymentError("Stripe did not return a payment page")
        log("stripe_checkout_created", sessionId=str(answer["id"])[:80], amountCents=amount_cents)
        return CheckoutSession(id=str(answer["id"]), url=str(answer["url"]))

    def get_session(self, session_id: str) -> SessionStatus:
        answer = self._call("GET", f"/checkout/sessions/{urllib.parse.quote(session_id, safe='')}")
        return SessionStatus(
            id=str(answer.get("id", session_id)),
            status=str(answer.get("status", "")),
            paid=answer.get("payment_status") == "paid",
            payment_intent=str(answer.get("payment_intent") or ""),
        )

    def expire_session(self, session_id: str) -> None:
        """Closes an unpaid payment page so the customer can no longer pay it."""
        self._call("POST", f"/checkout/sessions/{urllib.parse.quote(session_id, safe='')}/expire")

    def refund(self, payment_intent: str, *, idempotency_key: str) -> None:
        """Gives the whole payment back to the customer's card."""
        self._call("POST", "/refunds", {"payment_intent": payment_intent}, idempotency_key=idempotency_key)
        log("stripe_refunded", paymentIntent=payment_intent[:80])
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
"""Checking that a message really came from Stripe.

Stripe signs every webhook: the `Stripe-Signature` header has a timestamp `t` and one or more signatures `v1`, each an
HMAC-SHA256 (keyed with the endpoint's signing secret) of "<t>.<raw body>". A message that fails the check, or whose
timestamp is more than five minutes old (a replay), is refused.
"""

from __future__ import annotations

import hashlib
import hmac
import json

from . import PaymentError

TOLERANCE_SECONDS = 300


def verify(payload: bytes, header: str, secret: str, now: float) -> dict:
    """Returns the event (a dict) when the signature is good; raises PaymentError otherwise."""
    timestamp = ""
    signatures: list[str] = []
    for part in (header or "").split(","):
        name, _, value = part.strip().partition("=")
        if name == "t":
            timestamp = value
        elif name == "v1":
            signatures.append(value)
    if not timestamp.isdigit() or not signatures:
        raise PaymentError("The signature header is missing or malformed")
    if abs(now - int(timestamp)) > TOLERANCE_SECONDS:
        raise PaymentError("The signature is too old")
    expected = hmac.new(secret.encode(), timestamp.encode() + b"." + payload, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(expected, s) for s in signatures):
        raise PaymentError("The signature does not match")
    try:
        event = json.loads(payload.decode())
    except ValueError:
        raise PaymentError("The body is not JSON") from None
    if not isinstance(event, dict):
        raise PaymentError("The body is not an event")
    return event
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
"""Routes anyone can call (mounted under /api).

A route's job is small: read the request, hand it to a service, and shape the answer. The decisions
(is this time bookable? who wins a race?) are made in services/ and database/, not here.
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from ..core import config
from ..domain import shop
from ..schemas.requests import BookingIn, date_from_query
from ..services import bookings, notifications
from ..services import payments as payments_service
from ..services import settings as settings_service

router = APIRouter()


@router.get("/health")
def health() -> dict:
    """Is the API up, which environment is it, and which version of the code is running?"""
    try:
        # The deploy workflow writes the version into AWS Parameter Store after every deploy.
        version = config.params.get("app-version") or "unknown"
    except Exception:
        version = "unknown"  # a health check must never fail just because the version can't be read
    return {"status": "ok", "environment": config.get_settings().environment, "version": version}


@router.get("/availability")
def availability(from_: str = Query(alias="from"), to: str = Query()) -> dict:
    """Which times are taken between two dates. The booking page uses this to grey out unavailable times.

    `from` is a Python keyword, so the parameter is called from_ here and given its URL name with alias.
    """
    return bookings.get_availability(date_from_query(from_), date_from_query(to))


@router.get("/settings")
def shop_settings() -> dict:
    """The services and prices, and how long an appointment is on each weekday. The site reads this to draw its pages."""
    # payOnline: can customers pay by card? (Only once Stripe is set up, so the booking page never offers what can't work.)
    return {**settings_service.to_view(settings_service.current()), "payOnline": payments_service.available()}


@router.post("/bookings")
def create_booking(body: BookingIn) -> JSONResponse:
    """A customer books a time.

    201 = a new booking was made. 200 = this exact request had already succeeded (a retry), so the
    same booking is returned and no second email goes out.
    """
    booking, created = bookings.create_booking(body, shop.now_local())
    if created and booking.payment != "pending":
        # best effort: a failed email never fails the booking. One that is waiting for an online payment is announced
        # when the payment arrives (services/payments.py), not before.
        notifications.booking_created(booking)
    # public_view() leaves out the internal id; the customer only needs their code.
    return JSONResponse(status_code=201 if created else 200, content=booking.public_view())


@router.post("/stripe/webhook")
async def stripe_webhook(request: Request) -> dict:
    """Stripe tells us what happened to a payment. The message is only believed if its signature checks out.

    Anything that goes wrong AFTER the signature is good answers with an error on purpose: Stripe then sends the same
    message again for days, and everything that happens here is safe to repeat.
    """
    payments_service.handle_webhook(await request.body(), request.headers.get("stripe-signature", ""))
    return {"received": True}
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
"""What the site is allowed to send us.

Every request body is checked and cleaned here, BEFORE any business logic runs:
  - anything not listed in a model is ignored (for example the `minutes` the site sends: the API
    works out the real length from the day's setting, so a customer can never choose how long a cut takes)
  - text is stripped of hidden control characters and extra spaces
  - the error messages are written for customers and for Vic, not for programmers. The site shows
    them as they are, so they must read like a person wrote them.

The limits below are mirrored in frontend/src/config.js (LIMITS). A test compares the two.
"""

from __future__ import annotations

import re
import unicodedata
from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, field_validator

from ..core.errors import ValidationFailed
from ..domain import shop

# --- limits (the frontend counter and maxLength use the same numbers) ---------------------------
NAME_MIN = 2
NAME_MAX = 50
NOTES_MAX = 500
NOTE_MAX = 80  # Vic's own label on a blocked-off time, like "Lunch"
EMAIL_MAX = 254  # the longest an email address can legally be
PHONE_MIN_DIGITS = 10
PHONE_MAX_DIGITS = 15  # the international maximum
SERVICE_NAME_MIN = 2
SERVICE_NAME_MAX = 60
SERVICE_NOTE_MAX = 120
SERVICE_PRICE_MAX = 999  # dollars
SERVICE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

# Deliberately simple: "something@something.something" with no spaces. Real validation of an email
# address means actually sending to it, so we only catch obvious typos here.
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# --- the friendly messages ---------------------------------------------------------------------
MSG_NAME = f"Please enter your name, between {NAME_MIN} and {NAME_MAX} characters."
MSG_PHONE = f"Please enter a mobile number with at least {PHONE_MIN_DIGITS} digits so Vic can reach you."
MSG_EMAIL = "That email doesn't look right. Use something like name@example.com, or leave it blank."
MSG_NOTES = f"Notes can be up to {NOTES_MAX} characters. Please shorten yours a little."
MSG_DATE = "That date isn't valid. Please pick a day from the calendar."
MSG_TIME = "Please pick a time from the list."
MSG_SERVICE = "Please pick a service from the list."
MSG_STAFF = "Please pick a barber from the list."
MSG_PASSWORD = "Please enter your password."
MSG_SERVICE_NAME = f"Each service needs a name, between {SERVICE_NAME_MIN} and {SERVICE_NAME_MAX} characters."
MSG_SERVICE_PRICE = f"A price has to be a whole number of dollars, from 0 to {SERVICE_PRICE_MAX}."
MSG_SERVICE_NOTE = f"A service note can be up to {SERVICE_NOTE_MAX} characters. Please shorten it a little."
MSG_SERVICE_ID = "Something is wrong with that service. Reload the dashboard and try again."
MSG_SERVICES_COUNT = f"List between 1 and {shop.MAX_SERVICES} services."
MSG_SERVICES_DUPLICATE = "Two services have the same name. Give each one its own name."
MSG_SLOTS = (
    f"Each appointment length has to be between {shop.MIN_SLOT_MINUTES} and {shop.MAX_SLOT_MINUTES} minutes, "
    f"in steps of {shop.UNIT_MINUTES}."
)
MSG_REMINDERS = "Pick reminder times from the list."
MSG_SLOT_DAYS = "Set an appointment length for every day of the week."


def clean_text(value: str, *, keep_newlines: bool = False) -> str:
    """Removes invisible control characters (they can break emails and logs) and turns tabs into spaces.

    With keep_newlines=True line breaks survive (used for notes), and Windows-style "\\r\\n" counts as
    ONE line break, the same way the browser counts it, so a 500-character note is 500 on both sides.
    """
    if keep_newlines:
        value = value.replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for ch in value:
        if ch == "\n" and keep_newlines:
            out.append(ch)
        elif ch == "\t":
            out.append(" ")
        elif unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp"):
            continue  # control, format, line/paragraph separator characters
        else:
            out.append(ch)
    return "".join(out)


def one_line(value: str) -> str:
    """Single-line text: cleaned, with runs of spaces and any line breaks squashed into one space."""
    return " ".join(clean_text(value).split())


def parse_date_key(value: str) -> date:
    """'2026-10-12' -> a date. Raises ValueError (what the validators below expect) if it is not a real day."""
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError(MSG_DATE)
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ValueError(MSG_DATE) from None  # e.g. 2026-02-31


def date_from_query(value: str) -> date:
    """Same as parse_date_key, but for dates in a URL (?date=...): failures become a 422 API error."""
    try:
        return parse_date_key(value)
    except ValueError as err:
        raise ValidationFailed(str(err)) from None


def normalize_phone(value: str) -> str:
    """'(555) 010-1234' or '+1 555 010 1234' -> '5550101234'. Digits only, US country code dropped.

    Storing digits only means the same person typing their number two different ways is still the same
    person (used for the "3 upcoming bookings" limit and for spotting a retried request).
    """
    digits = re.sub(r"\D", "", value)
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    if not PHONE_MIN_DIGITS <= len(digits) <= PHONE_MAX_DIGITS:
        raise ValueError(MSG_PHONE)
    return digits


class BookingIn(BaseModel):
    """A customer booking a time (POST /api/bookings)."""

    model_config = ConfigDict(extra="ignore")  # unknown fields (like `minutes`) are dropped, not trusted

    staffId: str = shop.STAFF_ID
    serviceId: str
    dateKey: str
    start: StrictInt  # StrictInt: "720" or true are refused instead of being quietly converted
    name: str
    phone: str
    email: str | None = None
    notes: str | None = None
    smsConsent: StrictBool = False  # ticked "text me" (texts to a customer go out only when this is true)
    payment: Literal["shop", "online"] = "shop"  # pay at the shop, or online (Stripe) when it is set up
    returnTo: str | None = Field(default=None, max_length=200)  # the site's address, where Stripe sends them back to

    @field_validator("staffId")
    @classmethod
    def _staff(cls, v: str) -> str:
        if v != shop.STAFF_ID:
            raise ValueError(MSG_STAFF)
        return v

    @field_validator("serviceId")
    @classmethod
    def _service(cls, v: str) -> str:
        # Only the shape is checked here. Whether it is one of Vic's CURRENT services is decided in services/bookings.py,
        # because Vic can change the list at any time.
        if not SERVICE_ID_PATTERN.match(v):
            raise ValueError(MSG_SERVICE)
        return v

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)  # only checks it is a real date; the booking rules check if it is bookable
        return v

    @field_validator("start")
    @classmethod
    def _start(cls, v: int) -> int:
        # Minutes after midnight. Whether it is a time Vic works is decided later by domain/shop.py.
        if not 0 <= v < 24 * 60:
            raise ValueError(MSG_TIME)
        return v

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = one_line(v)
        if not NAME_MIN <= len(v) <= NAME_MAX:
            raise ValueError(MSG_NAME)
        return v

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)

    @field_validator("email")
    @classmethod
    def _email(cls, v: str | None) -> str:
        v = one_line(v or "")
        if not v:
            return ""  # email is optional
        if len(v) > EMAIL_MAX or not EMAIL_PATTERN.match(v):
            raise ValueError(MSG_EMAIL)
        return v

    @field_validator("notes")
    @classmethod
    def _notes(cls, v: str | None) -> str:
        v = clean_text(v or "", keep_newlines=True).strip()
        if len(v) > NOTES_MAX:
            raise ValueError(MSG_NOTES)
        return v


class LoginIn(BaseModel):
    """Vic signing in (POST /api/admin/login)."""

    model_config = ConfigDict(extra="ignore")

    password: str

    @field_validator("password")
    @classmethod
    def _length(cls, v: str) -> str:
        # The upper limit stops someone sending a huge "password" just to make the server hash it.
        if not 1 <= len(v) <= 200:
            raise ValueError(MSG_PASSWORD)
        return v


class MoveIn(BaseModel):
    """Vic moving a booking to another day and time (PATCH /api/admin/bookings/{id})."""

    model_config = ConfigDict(extra="ignore")

    dateKey: str
    start: StrictInt

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)
        return v

    @field_validator("start")
    @classmethod
    def _start(cls, v: int) -> int:
        if not 0 <= v < 24 * 60:
            raise ValueError(MSG_TIME)
        return v


class BlockIn(BaseModel):
    """Vic blocking off time (POST /api/admin/blocks): either a range of the day, or the whole day."""

    model_config = ConfigDict(extra="ignore")

    dateKey: str
    start: StrictInt = 0  # minutes after midnight; ignored when whole is true
    end: StrictInt = 0
    note: str | None = None
    whole: bool = False

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str) -> str:
        parse_date_key(v)
        return v

    @field_validator("note")
    @classmethod
    def _note(cls, v: str | None) -> str:
        return one_line(v or "")[:NOTE_MAX]  # a long label is trimmed rather than refused


class ServiceIn(BaseModel):
    """One service in Vic's settings. A service that already exists keeps its `id`; a new one has none yet."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str | None = None
    name: str
    price: StrictInt
    # "from" is a Python keyword, so the field is called from_price and given its JSON name with alias.
    from_price: StrictBool = Field(default=False, alias="from")
    note: str | None = None

    @field_validator("id")
    @classmethod
    def _id(cls, v: str | None) -> str | None:
        if v in (None, ""):
            return None
        if not SERVICE_ID_PATTERN.match(v):
            raise ValueError(MSG_SERVICE_ID)
        return v

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = one_line(v)
        if not SERVICE_NAME_MIN <= len(v) <= SERVICE_NAME_MAX:
            raise ValueError(MSG_SERVICE_NAME)
        return v

    @field_validator("price")
    @classmethod
    def _price(cls, v: int) -> int:
        if not 0 <= v <= SERVICE_PRICE_MAX:
            raise ValueError(MSG_SERVICE_PRICE)
        return v

    @field_validator("note")
    @classmethod
    def _note(cls, v: str | None) -> str:
        v = one_line(v or "")
        if len(v) > SERVICE_NOTE_MAX:
            raise ValueError(MSG_SERVICE_NOTE)
        return v


class SettingsIn(BaseModel):
    """Vic saving his settings (PUT /api/admin/settings): the whole list of services, and an appointment length per day."""

    model_config = ConfigDict(extra="ignore")

    services: list[ServiceIn]
    slotMinutes: dict[str, StrictInt]  # {"mon": 45, "tue": 45, ...} every weekday, in minutes
    reminderHours: list[StrictInt] | None = None  # hours before an appointment; [] = none; left out = keep what is saved

    @field_validator("services")
    @classmethod
    def _services(cls, v: list[ServiceIn]) -> list[ServiceIn]:
        if not 1 <= len(v) <= shop.MAX_SERVICES:
            raise ValueError(MSG_SERVICES_COUNT)
        ids = [s.id for s in v if s.id]
        if len(ids) != len(set(ids)):
            raise ValueError(MSG_SERVICE_ID)
        names = [s.name.casefold() for s in v]
        if len(names) != len(set(names)):
            raise ValueError(MSG_SERVICES_DUPLICATE)
        return v

    @field_validator("reminderHours")
    @classmethod
    def _reminders(cls, v: list[int] | None) -> list[int] | None:
        if v is None:
            return None
        if len(set(v)) != len(v) or any(h not in shop.REMINDER_CHOICES for h in v):
            raise ValueError(MSG_REMINDERS)
        return v

    @field_validator("slotMinutes")
    @classmethod
    def _slots(cls, v: dict[str, int]) -> dict[str, int]:
        if set(v) != set(shop.WEEKDAY_KEYS):
            raise ValueError(MSG_SLOT_DAYS)
        for minutes in v.values():
            if not shop.MIN_SLOT_MINUTES <= minutes <= shop.MAX_SLOT_MINUTES or minutes % shop.UNIT_MINUTES:
                raise ValueError(MSG_SLOTS)
        return v
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
"""Booking rules in action: what happens when a customer asks for a time.

This layer decides WHAT should happen and in which order. It calls the shop rules (domain/shop.py)
to ask "is this a valid time?" and the database layer to actually store it. It knows nothing about
web requests or DynamoDB details, which is what keeps it easy to read and easy to test.
"""

from __future__ import annotations

from datetime import date, datetime

from ..core.brand import CONTACT_EMAIL
from ..core.errors import NotFound, PaymentUnavailable, SlotTaken, TooManyBookings, ValidationFailed
from ..core.logs import log
from ..database import bookings as bookings_db
from ..database import schedule
from ..domain import shop
from ..domain.models import Booking, new_code
from ..schemas.requests import MSG_SERVICE, BookingIn, MoveIn, parse_date_key
from . import payments as payments_service
from . import settings as settings_service

# Anti-spam: one phone number can hold at most this many upcoming bookings at a time.
MAX_UPCOMING_PER_PHONE = 3


def get_availability(first: date, last: date) -> dict[str, dict]:
    """Which times are taken, day by day, for the booking page's grid. Works for up to 31 days at once."""
    if last < first:
        raise ValidationFailed("The end date can't be before the start date.")
    if (last - first).days + 1 > shop.MAX_RANGE_DAYS:
        raise ValidationFailed(f"Please ask for {shop.MAX_RANGE_DAYS} days or fewer at a time.")
    return schedule.availability(first, last, settings_service.current())


def _same_request(existing: Booking | None, data: BookingIn, day: date) -> Booking | None:
    """Is `existing` the booking THIS request already made?

    A customer who double-taps the button, or whose phone loses signal right after the booking went
    through, sends the same request twice. The second one should get their booking back, not an
    error that says the time was taken (by them). "Same request" means the same person, service and time.
    """
    if (
        existing
        and existing.day == day
        and existing.start == data.start
        and existing.phone == data.phone
        and existing.service_id == data.serviceId
        and existing.name.casefold() == data.name.casefold()
        # the same way of paying too, except that a payment still pending can be answered by either (see replay_of)
        and (existing.payment == "pending" or (existing.payment == "paid") == (data.payment == "online"))
    ):
        return existing
    return None


def create_booking(data: BookingIn, now: datetime) -> tuple[Booking, bool]:
    """Books the time. Returns (booking, created); created is False when this exact request had already succeeded.

    Order matters:
      1. is it a service Vic offers, a time he could ever take, and is it open right now?  (shop rules)
      2. does this phone number already hold too many upcoming bookings?  (anti-spam)
      3. try to claim the time. The database refuses if anyone got there first.
    """
    day = parse_date_key(data.dateKey)
    settings = settings_service.current()
    service = settings.service(data.serviceId)
    if service is None:  # Vic may have removed it since the page was loaded
        raise ValidationFailed(MSG_SERVICE, field="serviceId")
    minutes = settings.slot_for(day)  # the length is the day's setting, never something the client sends
    shop.check_bookable(day, data.start, minutes, now)

    def earlier_attempt() -> Booking | None:
        # Look at who owns this exact time right now, and check if it is this same request.
        return _same_request(bookings_db.booking_holding(day, data.start), data, day)

    online = data.payment == "online"
    amount_cents = service.price * 100
    if online:
        if not payments_service.available():
            raise PaymentUnavailable()
        if amount_cents <= 0:
            raise ValidationFailed("This service is free to book, so there is nothing to pay online.", field="payment")

    def replay_of(earlier: Booking) -> tuple[Booking, bool] | None:
        """The answer for a retried request. A payment page that has run out is not handed back, and neither is one the customer
        now wants to skip (they came back and chose "pay at the shop"): the time is given up so the request can start over."""
        if earlier.payment == "pending" and (not online or payments_service.hold_is_over(earlier, now)):
            return None if payments_service.release(earlier) == "released" else (earlier, False)
        log("booking_replayed", bookingId=earlier.id)
        return earlier, False

    if bookings_db.upcoming_for_phone(data.phone, shop.today(now)) >= MAX_UPCOMING_PER_PHONE:
        # The cap is reached, but a retry of an already-made booking must still be answered with it.
        replay = earlier_attempt()
        if replay and (answer := replay_of(replay)):
            return answer
        log("booking_refused", reason="too_many_upcoming")
        raise TooManyBookings(
            f"This phone number already has {MAX_UPCOMING_PER_PHONE} upcoming bookings, which is the most we allow. "
            f"Please email Vic at {CONTACT_EMAIL} if you need to change one."
        )
    held_until = payments_service.hold_until(now) if online else ""
    for attempt in (1, 2):  # a second go only after a run-out payment page of this same request was given up
        try:
            booking = bookings_db.create_booking(
                day=day,
                start=data.start,
                service_id=data.serviceId,
                service_name=service.name,
                minutes=minutes,
                name=data.name,
                phone=data.phone,
                email=data.email or "",
                notes=data.notes or "",
                code=new_code(),
                sms_consent=data.smsConsent,
                payment="pending" if online else "shop",
                amount_cents=amount_cents,
                hold_until=held_until,
            )
            break
        except SlotTaken:
            # Someone holds the time. If that someone is this very request (a retry), hand it back.
            replay = earlier_attempt()
            answer = replay_of(replay) if replay else None
            if answer:
                return answer  # the same request arrived twice; the first one stands
            if replay is None or attempt == 2:
                log("booking_refused", reason="slot_taken", date=data.dateKey, start=data.start)
                raise
    log(
        "booking_created",
        bookingId=booking.id,
        serviceId=booking.service_id,
        minutes=booking.minutes,
        hasEmail=bool(booking.email),
        smsConsent=booking.sms_consent,
        payment=booking.payment,
    )
    if online:
        booking = payments_service.start_checkout(booking, data.returnTo)  # Vic and the customer hear about it once it is paid
    return booking, True


def cancel_booking(booking_id: str) -> Booking:
    """Vic cancels a booking. Frees every block it held, and returns it so the customer can be told.

    One that was paid online is refunded first, and if the refund fails nothing is cancelled. One still waiting for payment
    has its payment page closed, so the customer can't pay for a time that is no longer theirs.
    """
    booking = bookings_db.get_booking(booking_id)
    if booking is None:
        raise NotFound("That booking was not found. It may already be cancelled.")
    if booking.payment == "pending":
        outcome = payments_service.release(booking)
        if outcome == "released":
            log("booking_cancelled", bookingId=booking.id, smsConsent=booking.sms_consent, hasEmail=bool(booking.email))
            return booking
        if outcome == "gone":
            raise NotFound("That booking was not found. It may already be cancelled.")
        if outcome == "paid":  # they paid a moment ago: it is a paid booking now, so it is refunded below
            booking = bookings_db.get_booking(booking_id) or booking
    if booking.payment == "paid":
        payments_service.refund(booking)
    booking = bookings_db.cancel_booking(booking_id)
    log("booking_cancelled", bookingId=booking.id, smsConsent=booking.sms_consent, hasEmail=bool(booking.email), payment=booking.payment)
    return booking


def move_booking(booking_id: str, data: MoveIn, now: datetime) -> tuple[Booking, Booking]:
    """Vic moves a booking to another time. Returns (before, after) so the customer can be told both.

    The customer keeps the same code. The booking gets a new id, because the id contains the day and time.
    """
    before = bookings_db.get_booking(booking_id)
    if not before:
        raise NotFound("That booking was not found. It may already be cancelled.")
    if before.payment == "pending":
        raise ValidationFailed("This booking is waiting for the customer to pay online. Wait for the payment, or cancel it.")
    day = parse_date_key(data.dateKey)
    if (day, data.start) == (before.day, before.start):
        raise ValidationFailed("That booking is already at that time. Pick a different one.")
    minutes = settings_service.current().slot_for(day)  # the booking takes the new day's appointment length
    shop.check_movable(day, data.start, minutes, now)
    after = bookings_db.move_booking(before, day=day, start=data.start, minutes=minutes)  # raises SlotTaken if not free
    log("booking_moved", fromId=before.id, toId=after.id, minutes=minutes)
    return before, after
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
"""Paying online, in action: holding the time while a customer pays, confirming the payment, giving a time back, refunding.

The life of an online booking:
  1. the customer picks "pay online": the booking is made at once and its time is HELD (payment = "pending"), and they
     are sent to Stripe's payment page. Nobody is told about the booking yet.
  2. Stripe tells us the result with a signed webhook. Paid: the booking becomes "paid" and Vic and the customer are told.
     Expired (they never paid): the booking is removed and the time is free again.
  3. a sweep every 15 minutes (the same schedule as the reminders) frees any hold whose webhook never arrived. Before it
     does, it asks Stripe, so a payment that did go through is confirmed instead of lost.
A booking Vic cancels after it was paid is refunded first. If the refund fails, nothing is cancelled.
"""

from __future__ import annotations

import re
import time
from dataclasses import replace
from datetime import datetime, timedelta, timezone

from .. import payments as stripe_payments
from ..core import config
from ..core.brand import BRAND_NAME
from ..core.errors import BadWebhook, NotConfigured, NotFound, PaymentUnavailable, RefundFailed
from ..core.logs import log
from ..database import bookings as bookings_db
from ..domain.models import Booking
from ..payments import PaymentError, webhook
from . import notifications

# Stripe wants a payment page to stay open at least 30 minutes, so the time is held for 31.
HOLD_MINUTES = 31
# The sweep waits a little after a hold ends, so Stripe's own "expired" message normally gets there first.
SWEEP_GRACE_MINUTES = 5


def available() -> bool:
    """Can customers pay online right now? (Both Stripe secrets are set up.)"""
    return stripe_payments.configured()


def iso_utc(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hold_until(now: datetime) -> str:
    """When a time that is waiting for payment stops being held."""
    return iso_utc(now + timedelta(minutes=HOLD_MINUTES))


def hold_is_over(booking: Booking, now: datetime) -> bool:
    return not booking.hold_until or booking.hold_until <= iso_utc(now)


_ORIGIN_SHAPE = re.compile(r"^https?://[A-Za-z0-9.-]+(:\d+)?$")


def _return_origin(return_to: str | None) -> str:
    """Where Stripe sends the customer back to: the site they came from, but only if it is one of our own addresses.
    (Otherwise a made-up address would turn Stripe's page into a link to anywhere.) Dev allows any site, like its CORS does."""
    allowed = config.get_settings().cors_origins
    clean = (return_to or "").rstrip("/")
    if clean and _ORIGIN_SHAPE.match(clean) and ("*" in allowed or clean in allowed):
        return clean
    real = [o for o in allowed if o != "*"]
    if real:
        return real[0]
    raise PaymentUnavailable()


def start_checkout(booking: Booking, return_to: str | None) -> Booking:
    """Gets the payment page for a booking that is waiting for payment, and remembers it. If Stripe can't, the held time
    is given back and the customer is told to pay at the shop instead."""
    client = stripe_payments.get_client()
    try:
        if client is None:
            raise PaymentError("online payment is not set up")
        origin = _return_origin(return_to)
        expires = datetime.strptime(booking.hold_until, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        session = client.create_checkout_session(
            booking_id=booking.id,
            code=booking.code,
            amount_cents=booking.amount_cents,
            product_name=f"{booking.service_name or 'Appointment'} at {BRAND_NAME.title()}",
            success_url=f"{origin}/#/book?paid={booking.code}",
            cancel_url=f"{origin}/#/book?payment=cancelled",
            expires_at=int(expires.timestamp()),
            customer_email=booking.email,
        )
        bookings_db.attach_checkout(booking, session.id, session.url)
    except (PaymentError, PaymentUnavailable) as err:
        log("payment_checkout_failed", bookingId=booking.id, reason=type(err).__name__)
        try:
            bookings_db.cancel_booking(booking.id)  # the customer never got to pay, so the time goes back
        except Exception as undo:  # noqa: BLE001 - the sweep will find the hold and free it
            log("payment_release_failed", bookingId=booking.id, reason=type(undo).__name__)
        raise PaymentUnavailable() from None
    log("payment_checkout_created", bookingId=booking.id, amountCents=booking.amount_cents)
    return replace(booking, checkout_id=session.id, checkout_url=session.url)


def confirm(booking_id: str, payment_intent: str) -> bool:
    """A payment arrived. Marks the booking paid and tells Vic and the customer. True if this call did it, False if it
    was already confirmed. A payment for a booking that no longer exists (its time was given back) is refunded."""
    booking = bookings_db.get_booking(booking_id)
    if booking is None:
        log("payment_orphaned", bookingId=booking_id)
        client = stripe_payments.get_client()
        if client and payment_intent:
            client.refund(payment_intent, idempotency_key=f"orphan-{payment_intent}")  # raises: Stripe will send it again
            log("payment_orphan_refunded", bookingId=booking_id)
        return False
    if not bookings_db.mark_paid(booking, payment_intent):
        log("payment_already_confirmed", bookingId=booking_id)
        return False
    log("payment_confirmed", bookingId=booking_id, amountCents=booking.amount_cents)
    notifications.booking_created(replace(booking, payment="paid", payment_intent=payment_intent, hold_until="", checkout_url=""))
    return True


def release(booking: Booking) -> str:
    """Gives up an unpaid booking and frees its time. Returns:
      "released"  it is gone and the time is free
      "paid"      Stripe says it WAS paid after all, so it is now confirmed instead
      "gone"      it no longer existed
      "kept"      Stripe could not be asked, so nothing was changed (the sweep tries again later)
    """
    client = stripe_payments.get_client()
    if client is not None and booking.checkout_id:
        try:
            status = client.get_session(booking.checkout_id)
            if status.status == "complete" and status.paid:
                confirm(booking.id, status.payment_intent)
                return "paid"
            if status.status == "open":
                client.expire_session(booking.checkout_id)  # from here on the customer can no longer pay it
        except PaymentError:
            return "kept"
    try:
        bookings_db.cancel_booking(booking.id)
    except NotFound:
        return "gone"
    log("payment_hold_released", bookingId=booking.id)
    return "released"


def refund(booking: Booking) -> None:
    """Gives a paid booking's money back. Raises RefundFailed if the card could not be refunded."""
    client = stripe_payments.get_client()
    if client is None or not booking.payment_intent:
        log("refund_failed", bookingId=booking.id, reason="no_payment_to_refund")
        raise RefundFailed()
    try:
        client.refund(booking.payment_intent, idempotency_key=f"refund-{booking.code}")
    except PaymentError as err:
        if err.code == "charge_already_refunded":
            log("refund_already_done", bookingId=booking.id)  # Vic already refunded it in Stripe
            return
        log("refund_failed", bookingId=booking.id, reason=err.code or "stripe_error")
        raise RefundFailed() from None
    log("payment_refunded", bookingId=booking.id, amountCents=booking.amount_cents)


def handle_webhook(payload: bytes, signature: str, now: float | None = None) -> str:
    """One message from Stripe. Returns what was done (for the log). Raises BadWebhook for a message that isn't Stripe's."""
    secret = stripe_payments.webhook_secret()
    if not secret:
        raise NotConfigured()
    try:
        event = webhook.verify(payload, signature, secret, now if now is not None else time.time())
    except PaymentError as err:
        log("webhook_rejected", reason=str(err)[:80])
        raise BadWebhook() from None
    kind = str(event.get("type", ""))
    session = (event.get("data") or {}).get("object") or {}
    booking_id = str((session.get("metadata") or {}).get("bookingId", ""))
    if kind in ("checkout.session.completed", "checkout.session.async_payment_succeeded"):
        if session.get("payment_status") != "paid":
            outcome = "ignored_not_paid"  # a delayed payment method: its own "async_payment_succeeded" comes later
        else:
            outcome = "confirmed" if confirm(booking_id, str(session.get("payment_intent") or "")) else "already_handled"
    elif kind == "checkout.session.expired":
        booking = bookings_db.get_booking(booking_id) if booking_id else None
        if booking is not None and booking.payment == "pending":
            bookings_db.cancel_booking(booking.id)
            log("payment_hold_released", bookingId=booking.id)
            outcome = "released"
        else:
            outcome = "already_handled"
    else:
        outcome = "ignored"
    log("webhook_handled", type=kind, outcome=outcome)
    return outcome


def release_expired(now: datetime) -> int:
    """The sweep: gives back the time of every unpaid booking whose hold ended a while ago. Returns how many."""
    cutoff = iso_utc(now - timedelta(minutes=SWEEP_GRACE_MINUTES))
    freed = 0
    for booking_id, until in bookings_db.holds_ending_before(cutoff):
        try:
            booking = bookings_db.get_booking(booking_id)
            if booking is None or booking.payment != "pending":
                bookings_db.forget_hold(booking_id, until)  # a marker nothing needs any more
            elif release(booking) == "released":
                freed += 1
        except Exception as exc:  # noqa: BLE001 - one stuck hold must not stop the others
            log("hold_sweep_error", bookingId=booking_id, reason=type(exc).__name__)
    if freed:
        log("holds_released", count=freed)
    return freed
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
"""Reminders before appointments. A scheduled run (every 15 minutes, see infra/template.yaml) calls send_due().

Vic chooses the reminder times in his settings (default: 24 hours and 2 hours before). For each upcoming booking the
sweep works out which of those moments have arrived, and sends the reminder by email (if the customer left one) and by
text (if they agreed to texts).

Rules that keep it from being annoying:
  - each reminder is marked as sent BEFORE it is sent, so it goes out at most once, even if two sweeps overlap
  - a reminder whose moment had already passed when the booking was made (or moved) is never sent
    (someone who books at noon for 2 pm does not get a "24 hours before" reminder)
  - if two reminders are due at once (the sweep was down for a while), only the nearest one is sent
  - nothing is sent after the appointment has started
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..core.logs import log
from ..database import reminders as reminders_db
from ..domain import shop
from ..domain.models import Booking
from . import notifications
from . import settings as settings_service


def _tag(hours: int) -> str:
    return f"{hours}h"


def _updated(booking: Booking) -> datetime:
    """When the booking was made or last moved (UTC). Unreadable or missing counts as long ago."""
    try:
        return datetime.fromisoformat(booking.updated_at).astimezone(timezone.utc)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def _handle(booking: Booking, hours_list: tuple[int, ...], now: datetime) -> bool:
    """Sends the reminder this booking is due, if any. Returns True when one was sent."""
    if booking.payment == "pending":
        return False  # still waiting for the customer to pay online: it is not a real appointment yet
    starts = shop.starts_at(booking.day, booking.start).astimezone(timezone.utc)
    if now >= starts:
        return False
    changed = _updated(booking)
    due: list[int] = []  # reminder moments that have arrived and are still wanted
    for hours in hours_list:
        tag = _tag(hours)
        moment = starts - timedelta(hours=hours)
        if tag in booking.reminders_sent or moment > now:
            continue
        if moment < changed:  # already in the past when it was booked or moved: skip it for good
            reminders_db.claim(booking, tag)
            log("reminder_skipped", bookingId=booking.id, tag=tag, reason="past_when_booked")
            continue
        due.append(hours)
    if not due:
        return False
    nearest = min(due)
    for hours in due:
        if hours != nearest:
            reminders_db.claim(booking, _tag(hours))  # an older one that was overtaken: mark it, send only the nearest
    if not reminders_db.claim(booking, _tag(nearest)):
        return False
    log("reminder_sending", bookingId=booking.id, tag=_tag(nearest), smsConsent=booking.sms_consent, hasEmail=bool(booking.email))
    notifications.booking_reminder(booking)
    return True


def send_due(now: datetime | None = None) -> dict[str, int]:
    """One sweep. Returns how many reminders were sent and how many bookings could not be handled."""
    moment = (now or shop.now_local()).astimezone(timezone.utc)
    hours_list = settings_service.current().reminder_hours
    result = {"sent": 0, "errors": 0}
    if not hours_list:
        log("reminders_swept", sent=0, errors=0, examined=0, note="no reminder times are switched on")
        return result
    first = shop.today(moment)
    last: date = first + timedelta(days=max(hours_list) // 24 + 2)
    upcoming = reminders_db.upcoming(first, last)
    for booking in upcoming:
        try:
            if _handle(booking, hours_list, moment):
                result["sent"] += 1
        except Exception as exc:  # one broken booking must not stop everyone else's reminder
            result["errors"] += 1
            log("reminder_error", reason=type(exc).__name__)
    log("reminders_swept", examined=len(upcoming), reminderHours=list(hours_list), **result)
    return result
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
"""The texts. Short and plain (no emoji, no links) so they send as few segments as possible and are never filtered.

Every text to a customer says who it is from and ends with the opt-out line carriers expect. Texts to Vic himself
do not need it. Everything a customer typed is flattened to one line first.

NO WEB ADDRESSES OR EMAIL ADDRESSES in a text. Textbelt refuses any message that looks like it holds a link ("ability to
send URLs via text is limited to verified accounts"), and "vicslegacy89@gmail.com" looks like one because of the ".com". So
the texts say "email Vic" and leave the address to the email and the website. A test checks that no text can contain one,
even when a customer types a name like "shop.com".
"""

from __future__ import annotations

import re

from ..core.brand import ADDRESS_LINES, BRAND_NAME
from ..domain import shop
from ..domain.models import Booking

OPT_OUT = "Reply STOP to opt out."


EMAIL_HINT = "To change it, email Vic (his address is on our site)."


def _line(text: str, limit: int) -> str:
    """One line, no control characters, and nothing that looks like a web or email address, cut to `limit` characters.
    A dot between letters or digits (shop.com) and an @ are turned into spaces so Textbelt never reads it as a link."""
    clean = "".join(c if c.isprintable() else " " for c in text)
    clean = re.sub(r"(?<=\w)[.@/:](?=\w)", " ", clean)
    return " ".join(clean.split())[:limit]


def _when(booking: Booking) -> str:
    """'Tue, Oct 13 at 12:45 pm'."""
    d = booking.day
    return f"{d:%a}, {d:%b} {d.day} at {shop.label(booking.start)}"


def _service(booking: Booking) -> str:
    if booking.service_name:
        return booking.service_name
    service = shop.DEFAULT_SETTINGS.service(booking.service_id)
    return service.name if service else booking.service_id


def _text(*parts: str) -> str:
    """Joins the parts of a text with line breaks; '' makes a blank line. Only our own wording passes through here,
    anything a customer typed has already been through `_line`, which removes line breaks."""
    return "\n".join(parts)


def owner_new_booking(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "New booking",
        "",
        f"{_line(booking.name, 40)}",
        f"{_line(_service(booking), 50)}",
        f"{_when(booking)}",
        "",
        f"Phone: {booking.phone}",
        f"Code: {booking.code}",
        f"Payment: {booking.payment_label}",
    )


def customer_confirmation(booking: Booking) -> str:
    first = _line(booking.name.split()[0] if booking.name.split() else "", 20)
    return _text(
        f"{BRAND_NAME}",
        f"You're booked, {first}!" if first else "You're booked!",
        "",
        f"{_when(booking)}",
        f"{_line(_service(booking), 50)} with Vic",
        f"Code: {booking.code}",
        "",
        "Paid online. Thank you!" if booking.payment == "paid" else "Pay at the shop.",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )


def customer_cancellation(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Your appointment was cancelled.",
        "",
        f"Was: {_when(booking)}",
        "",
        "Your online payment will be refunded to your card." if booking.payment == "paid" else "You can book a new time anytime on our site.",
        "",
        OPT_OUT,
    )


def customer_rescheduled(before: Booking, after: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Your appointment moved.",
        "",
        f"Now: {_when(after)}",
        f"Was: {_when(before)}",
        f"Code: {after.code}",
        "",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )


def customer_reminder(booking: Booking) -> str:
    return _text(
        f"{BRAND_NAME}",
        "Reminder: you're booked.",
        "",
        f"{_when(booking)}",
        f"{ADDRESS_LINES[0]}",
        f"Code: {booking.code}",
        "",
        EMAIL_HINT,
        "",
        OPT_OUT,
    )
VICBLESS_EOF
cat > "$STAGE/16" <<'VICBLESS_EOF'
"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock, classic_grid   run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails
    texts                catches outgoing texts (and sets Vic's number)
    stripe               online payment switched on, with a fake Stripe
    logged               the log lines the app wrote, as dicts

Shared test data and shortcuts live in tests/helpers/ (builders, api shortcuts, constants).
"""

from tests.fixtures.api import admin_setup, auth, client  # noqa: F401
from tests.fixtures.aws import atomic_transactions, aws  # noqa: F401
from tests.fixtures.clock import fixed_clock  # noqa: F401
from tests.fixtures.email import sent  # noqa: F401
from tests.fixtures.logs import logged  # noqa: F401
from tests.fixtures.settings import classic_grid  # noqa: F401
from tests.fixtures.sms import texts  # noqa: F401
from tests.fixtures.stripe import stripe  # noqa: F401
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
"""A fake Stripe for the tests: the same questions and answers as the real API, nothing sent over the network."""

import hashlib
import hmac
import io
import json
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

from tests.helpers.aws import put_param

SECRET_KEY = "sk_test_secret"
WEBHOOK_SECRET = "whsec_test"
SITE = "https://vicbless.com"


class FakeStripe:
    """Holds the payment pages ("sessions") it has made. Tests change `fail` / `refund_error` to make Stripe misbehave."""

    def __init__(self):
        self.sessions: dict[str, dict] = {}
        self.calls: list[tuple[str, str, dict, dict]] = []  # (method, path, form, headers)
        self.refunds: list[dict] = []
        self.fail: set[str] = set()  # "create", "get", "expire", "refund": that call answers with an error
        self.refund_error: str = ""  # Stripe's code for a refused refund

    def _error(self, url, status, code=""):
        body = io.BytesIO(json.dumps({"error": {"code": code}}).encode())
        return urllib.error.HTTPError(url, status, "error", {}, body)

    def handle(self, request):
        path = request.full_url.removeprefix("https://api.stripe.com/v1")
        form = {k: v[0] for k, v in urllib.parse.parse_qs((request.data or b"").decode()).items()}
        headers = {k.lower(): v for k, v in request.header_items()}
        self.calls.append((request.get_method(), path, form, headers))
        if request.get_method() == "POST" and path == "/checkout/sessions":
            if "create" in self.fail:
                raise self._error(request.full_url, 500)
            sid = f"cs_test_{len(self.sessions) + 1}"
            self.sessions[sid] = {
                "id": sid, "url": f"https://checkout.stripe.test/c/{sid}", "status": "open", "payment_status": "unpaid",
                "payment_intent": f"pi_{sid}", "form": form,
            }  # fmt: skip
            return {"id": sid, "url": self.sessions[sid]["url"]}
        if path.startswith("/checkout/sessions/") and path.endswith("/expire"):
            sid = path.split("/")[3]
            if "expire" in self.fail or self.sessions[sid]["status"] != "open":
                raise self._error(request.full_url, 400, "checkout_session_not_open")
            self.sessions[sid]["status"] = "expired"
            return {"id": sid, "status": "expired"}
        if request.get_method() == "GET" and path.startswith("/checkout/sessions/"):
            if "get" in self.fail:
                raise self._error(request.full_url, 500)
            return self.sessions[path.split("/")[3]]
        if path == "/refunds":
            if "refund" in self.fail or self.refund_error:
                raise self._error(request.full_url, 400, self.refund_error)
            self.refunds.append({"form": form, "headers": headers})
            return {"id": "re_1"}
        raise AssertionError(f"unexpected Stripe call: {request.get_method()} {path}")

    def pay(self, session_id: str):
        """The customer pays that payment page."""
        self.sessions[session_id].update(status="complete", payment_status="paid")


@pytest.fixture
def stripe(monkeypatch):
    """Online payment switched on (keys in the fake Parameter Store) and a fake Stripe to talk to."""
    fake = FakeStripe()

    class Response:
        def __init__(self, answer):
            self.answer = answer

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return json.dumps(self.answer).encode()

    monkeypatch.setattr(urllib.request, "urlopen", lambda request, timeout=None: Response(fake.handle(request)))
    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", f"{SITE}, https://www.vicbless.com")
    put_param("stripe-secret-key", SECRET_KEY)
    put_param("stripe-webhook-secret", WEBHOOK_SECRET)
    return fake


def signed(event: dict, *, secret: str = WEBHOOK_SECRET, at: float | None = None) -> tuple[bytes, dict]:
    """(body, headers) of a webhook the way Stripe sends it."""
    body = json.dumps(event).encode()
    stamp = str(int(at if at is not None else time.time()))
    digest = hmac.new(secret.encode(), stamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    return body, {"stripe-signature": f"t={stamp},v1={digest}", "content-type": "application/json"}


def session_event(kind: str, session: dict, booking_id: str, *, paid: bool | None = None) -> dict:
    """A Stripe event about a payment page. `paid` defaults to what the fake says."""
    is_paid = session["payment_status"] == "paid" if paid is None else paid
    return {
        "id": "evt_1",
        "type": kind,
        "data": {
            "object": {
                "id": session["id"],
                "payment_status": "paid" if is_paid else "unpaid",
                "payment_intent": session["payment_intent"],
                "metadata": {"bookingId": booking_id},
            }
        },
    }
VICBLESS_EOF
cat > "$STAGE/18" <<'VICBLESS_EOF'
"""Paying online with Stripe: the signature check, the Stripe bridge, and the life of an online booking."""

import time
import urllib.error

import pytest

from app.database import schedule as schedule_db
from app.payments import PaymentError, webhook
from app.payments.stripe import StripeClient
from app.services import payments as payments_service
from app.services import reminders
from tests.fixtures.stripe import SECRET_KEY, SITE, WEBHOOK_SECRET, session_event, signed
from tests.helpers.api import book, busy, schedule_of
from tests.helpers.builders import booking_body, booking_model
from tests.helpers.constants import NOW, TUESDAY

from datetime import timedelta


def holds():
    return schedule_db.query_range("HOLD#", "HOLD#~")


def the_session(stripe):
    [session] = stripe.sessions.values()
    return session


def online(client, **over):
    return book(client, payment="online", **over)


def webhook_call(client, event, **kw):
    body, headers = signed(event, **kw)
    return client.post("/api/stripe/webhook", content=body, headers=headers)


def pay(client, stripe, booking_id):
    """The customer pays the page, and Stripe tells us."""
    session = the_session(stripe)
    stripe.pay(session["id"])
    return webhook_call(client, session_event("checkout.session.completed", session, booking_id))


def booking_id_of(client, auth):
    [item] = schedule_of(client, auth)["items"]
    return item["id"]


# --- the signature check -------------------------------------------------------------------------------------------


def test_a_good_signature_gives_the_event():
    body, headers = signed({"type": "x"})
    assert webhook.verify(body, headers["stripe-signature"], WEBHOOK_SECRET, time.time()) == {"type": "x"}


@pytest.mark.parametrize("problem", ["secret", "body", "old", "missing", "garbage"])
def test_a_bad_signature_is_refused(problem):
    body, headers = signed({"type": "x"}, secret="other" if problem == "secret" else WEBHOOK_SECRET, at=time.time() - (900 if problem == "old" else 0))
    header = headers["stripe-signature"]
    if problem == "body":
        body = body + b" "
    if problem == "missing":
        header = ""
    if problem == "garbage":
        header = "t=abc,v1="
    with pytest.raises(PaymentError):
        webhook.verify(body, header, WEBHOOK_SECRET, time.time())


def test_stripe_may_send_several_signatures_and_one_good_one_is_enough():
    body, headers = signed({"type": "x"})
    header = "v1=deadbeef," + headers["stripe-signature"]
    assert webhook.verify(body, header, WEBHOOK_SECRET, time.time()) == {"type": "x"}


# --- the Stripe bridge --------------------------------------------------------------------------------------------


def test_a_payment_page_is_asked_for_with_the_key_and_the_booking_in_it(stripe):
    session = StripeClient(SECRET_KEY).create_checkout_session(
        booking_id="b1", code="VB-AAAAAA", amount_cents=5500, product_name="Men's haircut at Vicbless Barbershop",
        success_url="https://x/ok", cancel_url="https://x/no", expires_at=1234, customer_email="m@example.com",
    )  # fmt: skip
    method, path, form, headers = stripe.calls[0]
    assert (method, path, session.id) == ("POST", "/checkout/sessions", "cs_test_1")
    assert headers["authorization"] == f"Bearer {SECRET_KEY}" and headers["idempotency-key"] == "checkout-b1"
    assert form["mode"] == "payment" and form["line_items[0][price_data][unit_amount]"] == "5500"
    assert form["metadata[bookingId]"] == "b1" and form["customer_email"] == "m@example.com"
    assert form["line_items[0][price_data][currency]"] == "usd" and form["expires_at"] == "1234"


def test_an_empty_email_is_not_sent_to_stripe(stripe):
    StripeClient(SECRET_KEY).create_checkout_session(
        booking_id="b1", code="c", amount_cents=100, product_name="x", success_url="u", cancel_url="u", expires_at=1
    )
    assert "customer_email" not in stripe.calls[0][2]


def test_stripe_errors_become_payment_errors_with_its_code(stripe):
    stripe.refund_error = "charge_already_refunded"
    with pytest.raises(PaymentError) as err:
        StripeClient(SECRET_KEY).refund("pi_1", idempotency_key="r")
    assert err.value.code == "charge_already_refunded"


def test_an_unreachable_stripe_is_a_payment_error(monkeypatch):
    def down(*a, **k):
        raise urllib.error.URLError("down")

    monkeypatch.setattr(urllib.request, "urlopen", down)
    with pytest.raises(PaymentError):
        StripeClient(SECRET_KEY).expire_session("cs_1")


# --- is it switched on? ----------------------------------------------------------------------------------------------


def test_the_site_only_offers_online_payment_when_stripe_is_set_up(client):
    assert client.get("/api/settings").json()["payOnline"] is False


def test_with_the_keys_set_up_online_payment_is_offered(client, stripe):
    assert client.get("/api/settings").json()["payOnline"] is True


def test_online_payment_is_refused_when_it_is_not_set_up_and_nothing_is_booked(client):
    r = online(client)
    assert r.status_code == 503 and r.json()["error"]["code"] == "payment_unavailable"
    assert busy(client) == []


def test_paying_at_the_shop_works_as_before_and_vic_is_told_it_is_unpaid(client, auth, sent, texts, stripe):
    r = book(client, email="m@example.com", smsConsent=True)
    assert r.status_code == 201 and r.json()["payment"] == "shop" and "checkoutUrl" not in r.json()
    assert stripe.calls == []  # Stripe was never asked
    [item] = schedule_of(client, auth)["items"]
    assert item["payment"] == "shop" and item["amountCents"] == 5500
    owner_email = next(m for m in sent if m.to == "vic@example.com")
    assert "Payment: Pay at the shop ($55)" in owner_email.text
    assert any("Payment: Pay at the shop ($55)" in t.body for t in texts)
    assert any("Pay at the shop." in t.body for t in texts if t.to == "5550101234")


# --- an online booking -----------------------------------------------------------------------------------------------


def test_an_online_booking_holds_the_time_and_sends_the_customer_to_stripe(client, auth, stripe, sent, texts):
    r = online(client, email="m@example.com", smsConsent=True)
    assert r.status_code == 201
    body = r.json()
    assert body["payment"] == "pending" and body["checkoutUrl"] == "https://checkout.stripe.test/c/cs_test_1"
    assert busy(client) == [720]  # nobody else can take it while they pay
    [item] = schedule_of(client, auth)["items"]
    assert item["payment"] == "pending" and item["amountCents"] == 5500
    assert len(holds()) == 1
    assert sent == [] and texts == []  # nobody is told about a booking that is not paid yet
    form = stripe.calls[0][2]
    assert form["line_items[0][price_data][unit_amount]"] == "5500"
    assert form["success_url"] == f"{SITE}/#/book?paid={body['code']}" and form["cancel_url"] == f"{SITE}/#/book?payment=cancelled"
    assert form["metadata[bookingId]"] == item["id"]


def test_the_return_address_must_be_one_of_ours(client, stripe):
    online(client, returnTo="https://evil.example")
    assert stripe.calls[0][2]["success_url"].startswith(f"{SITE}/#/")
    stripe.sessions.clear()
    online(client, start=755, returnTo="https://www.vicbless.com", phone="(555) 010-9999")
    assert stripe.calls[-1][2]["success_url"].startswith("https://www.vicbless.com/#/")


def test_dev_accepts_any_site_but_only_a_plain_address(client, stripe, monkeypatch):
    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", "*")
    online(client, returnTo="https://d111.cloudfront.net/")
    assert stripe.calls[0][2]["success_url"].startswith("https://d111.cloudfront.net/#/book?paid=")
    bad = online(client, start=755, phone="(555) 010-9999", returnTo="javascript:alert(1)")
    assert bad.status_code == 503  # dev knows no real address to fall back to, so it refuses rather than guess
    assert len(stripe.calls) == 1 and busy(client) == [720]


def test_if_stripe_cannot_make_a_payment_page_the_time_goes_back(client, stripe):
    stripe.fail.add("create")
    r = online(client)
    assert r.status_code == 503 and r.json()["error"]["code"] == "payment_unavailable"
    assert busy(client) == [] and holds() == []


def test_the_same_online_request_twice_gets_the_same_payment_page(client, stripe):
    first = online(client)
    second = online(client)
    assert (first.status_code, second.status_code) == (201, 200)
    assert second.json()["code"] == first.json()["code"] and second.json()["checkoutUrl"] == first.json()["checkoutUrl"]
    assert len(stripe.sessions) == 1


def test_coming_back_and_choosing_to_pay_at_the_shop_gives_up_the_payment_page(client, auth, stripe):
    online(client, email="m@example.com")
    r = book(client, email="m@example.com")  # same person and time, but "at the shop" this time
    assert r.status_code == 201 and r.json()["payment"] == "shop"
    assert the_session(stripe)["status"] == "expired" and holds() == []
    assert busy(client) == [720] and schedule_of(client, auth)["items"][0]["payment"] == "shop"


def test_a_booking_made_for_the_shop_cannot_be_turned_into_an_online_one_by_a_retry(client, stripe):
    book(client)
    r = online(client)
    assert r.status_code == 409 and r.json()["error"]["code"] == "slot_taken"


def test_a_payment_page_that_ran_out_is_given_up_when_the_same_request_comes_back(client, stripe, monkeypatch):
    first = online(client)
    stripe.sessions["cs_test_1"]["status"] = "expired"
    monkeypatch.setattr("app.domain.shop.now_local", lambda: NOW + timedelta(minutes=45))
    monkeypatch.setattr("app.domain.shop.check_bookable", lambda *a, **k: None)
    second = online(client)
    assert second.status_code == 201 and second.json()["code"] != first.json()["code"]
    assert len(holds()) == 1 and len(stripe.sessions) == 2


def test_reminders_skip_a_booking_that_is_not_paid_yet(client, stripe, sent, texts):
    online(client, email="m@example.com", smsConsent=True)
    result = reminders.send_due(NOW + timedelta(hours=20))
    assert result == {"sent": 0, "errors": 0} and sent == [] and texts == []


# --- Stripe's messages ------------------------------------------------------------------------------------------------


def test_a_paid_message_confirms_the_booking_and_tells_vic_and_the_customer(client, auth, stripe, sent, texts):
    online(client, email="m@example.com", smsConsent=True)
    bid = booking_id_of(client, auth)
    r = pay(client, stripe, bid)
    assert r.status_code == 200 and r.json() == {"received": True}
    [item] = schedule_of(client, auth)["items"]
    assert item["payment"] == "paid" and item["amountCents"] == 5500 and holds() == []
    owner_email = next(m for m in sent if m.to == "vic@example.com")
    assert "Payment: Paid online ($55)" in owner_email.text
    customer_email = next(m for m in sent if m.to == "m@example.com")
    assert "Paid online, thank you." in customer_email.text and "Pay at the shop" not in customer_email.text
    assert any("Payment: Paid online ($55)" in t.body for t in texts)
    assert any("Paid online. Thank you!" in t.body for t in texts if t.to == "5550101234")


def test_the_same_paid_message_twice_tells_nobody_twice(client, auth, stripe, sent, texts):
    online(client, email="m@example.com", smsConsent=True)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    count = (len(sent), len(texts))
    r = webhook_call(client, session_event("checkout.session.completed", the_session(stripe), bid))
    assert r.status_code == 200 and (len(sent), len(texts)) == count


def test_a_message_with_a_bad_signature_changes_nothing(client, auth, stripe, sent):
    online(client)
    bid = booking_id_of(client, auth)
    stripe.pay("cs_test_1")
    body, headers = signed(session_event("checkout.session.completed", the_session(stripe), bid), secret="not-the-secret")
    r = client.post("/api/stripe/webhook", content=body, headers=headers)
    assert r.status_code == 400 and r.json()["error"]["code"] == "bad_signature"
    assert schedule_of(client, auth)["items"][0]["payment"] == "pending" and sent == []


def test_the_webhook_is_not_available_before_stripe_is_set_up(client):
    body, headers = signed({"type": "x"})
    assert client.post("/api/stripe/webhook", content=body, headers=headers).status_code == 503


def test_an_expired_message_gives_the_time_back(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    r = webhook_call(client, session_event("checkout.session.expired", the_session(stripe), bid))
    assert r.status_code == 200 and busy(client) == [] and holds() == []


def test_an_expired_message_for_a_paid_booking_changes_nothing(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    webhook_call(client, session_event("checkout.session.expired", the_session(stripe), bid))
    assert busy(client) == [720]


def test_a_payment_that_is_not_paid_yet_is_ignored(client, auth, stripe, sent):
    online(client)
    bid = booking_id_of(client, auth)
    webhook_call(client, session_event("checkout.session.completed", the_session(stripe), bid, paid=False))
    assert schedule_of(client, auth)["items"][0]["payment"] == "pending" and sent == []


def test_other_messages_are_acknowledged_and_ignored(client, stripe):
    assert webhook_call(client, {"type": "charge.updated", "data": {"object": {}}}).status_code == 200


def test_a_payment_for_a_time_that_was_given_back_is_refunded(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    session = the_session(stripe)
    webhook_call(client, session_event("checkout.session.expired", session, bid))  # the time is freed
    stripe.pay(session["id"])  # ...and then the money still arrives
    r = webhook_call(client, session_event("checkout.session.completed", session, bid))
    assert r.status_code == 200
    assert stripe.refunds and stripe.refunds[0]["form"] == {"payment_intent": "pi_cs_test_1"}
    assert busy(client) == []


# --- the sweep ---------------------------------------------------------------------------------------------------------


def test_the_sweep_frees_a_hold_that_ran_out_and_closes_the_payment_page(client, stripe):
    online(client)
    later = NOW + timedelta(minutes=payments_service.HOLD_MINUTES + payments_service.SWEEP_GRACE_MINUTES + 1)
    assert payments_service.release_expired(later) == 1
    assert busy(client) == [] and holds() == [] and the_session(stripe)["status"] == "expired"


def test_the_sweep_leaves_a_hold_that_has_not_ended(client, stripe):
    online(client)
    assert payments_service.release_expired(NOW + timedelta(minutes=20)) == 0
    assert busy(client) == [720]


def test_the_sweep_waits_a_few_minutes_after_the_hold_ends(client, stripe):
    online(client)
    assert payments_service.release_expired(NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1)) == 0


def test_the_sweep_confirms_a_payment_whose_message_never_arrived(client, auth, stripe, sent):
    online(client, email="m@example.com")
    stripe.pay("cs_test_1")  # paid, but no webhook came
    later = NOW + timedelta(hours=1)
    assert payments_service.release_expired(later) == 0
    assert schedule_of(client, auth)["items"][0]["payment"] == "paid" and sent  # confirmed, and Vic told


def test_the_sweep_keeps_a_hold_when_stripe_cannot_be_asked(client, stripe):
    online(client)
    stripe.fail.add("get")
    assert payments_service.release_expired(NOW + timedelta(hours=1)) == 0
    assert busy(client) == [720]  # tried again at the next sweep


def test_the_sweep_drops_a_marker_whose_booking_is_gone(client, stripe):
    online(client)
    client.app  # noqa: B018
    from app.database import bookings as bookings_db

    [(booking_id, until)] = bookings_db.holds_ending_before("9999")
    from app.database import table
    from app.database.keys import PK, booking_sk
    from app.domain.models import parse_id

    day, start = parse_id(booking_id)
    table.table().delete_item(Key={"pk": PK, "sk": booking_sk(day, start, booking_id)})
    payments_service.release_expired(NOW + timedelta(hours=1))
    assert holds() == []


def test_the_scheduled_event_also_runs_the_sweep(client, stripe, monkeypatch):
    from app.handler import lambda_handler

    online(client)
    monkeypatch.setattr("app.domain.shop.now_local", lambda: NOW + timedelta(hours=1))
    assert lambda_handler({"source": "aws.events"}, None)["holdsReleased"] == 1


# --- Vic cancels or moves ----------------------------------------------------------------------------------------------


def test_cancelling_a_booking_that_is_waiting_for_payment_closes_the_payment_page(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    assert client.delete(f"/api/admin/bookings/{bid}", headers=auth).status_code == 200
    assert busy(client) == [] and holds() == [] and the_session(stripe)["status"] == "expired"
    assert stripe.refunds == []


def test_cancelling_one_that_was_paid_a_moment_ago_refunds_it(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    stripe.pay("cs_test_1")  # paid, webhook not here yet
    assert client.delete(f"/api/admin/bookings/{bid}", headers=auth).status_code == 200
    assert len(stripe.refunds) == 1 and busy(client) == []


def test_cancelling_a_paid_booking_refunds_it_and_tells_the_customer(client, auth, stripe, sent, texts):
    online(client, email="m@example.com", smsConsent=True)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    sent.clear()
    texts.clear()
    assert client.delete(f"/api/admin/bookings/{bid}", headers=auth).status_code == 200
    [refund] = stripe.refunds
    assert refund["form"] == {"payment_intent": "pi_cs_test_1"} and refund["headers"]["idempotency-key"].startswith("refund-VB-")
    assert busy(client) == []
    assert "refunded" in sent[0].text and any("refunded" in t.body for t in texts)


def test_if_the_refund_fails_nothing_is_cancelled(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    stripe.fail.add("refund")
    r = client.delete(f"/api/admin/bookings/{bid}", headers=auth)
    assert r.status_code == 502 and r.json()["error"]["code"] == "refund_failed"
    assert busy(client) == [720] and schedule_of(client, auth)["items"][0]["payment"] == "paid"


def test_a_payment_vic_already_refunded_in_stripe_does_not_block_the_cancel(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    stripe.refund_error = "charge_already_refunded"
    assert client.delete(f"/api/admin/bookings/{bid}", headers=auth).status_code == 200
    assert busy(client) == []


def test_cancelling_a_shop_booking_never_touches_stripe(client, auth, stripe):
    book(client)
    bid = booking_id_of(client, auth)
    assert client.delete(f"/api/admin/bookings/{bid}", headers=auth).status_code == 200
    assert stripe.calls == []


def test_a_booking_waiting_for_payment_cannot_be_moved(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    r = client.patch(f"/api/admin/bookings/{bid}", json={"dateKey": TUESDAY, "start": 755}, headers=auth)
    assert r.status_code == 422 and "waiting for the customer to pay" in r.json()["error"]["message"]


def test_a_paid_booking_keeps_its_payment_when_it_is_moved(client, auth, stripe):
    online(client)
    bid = booking_id_of(client, auth)
    pay(client, stripe, bid)
    r = client.patch(f"/api/admin/bookings/{bid}", json={"dateKey": TUESDAY, "start": 755}, headers=auth)
    assert r.status_code == 200 and r.json()["payment"] == "paid" and r.json()["amountCents"] == 5500
    new_id = r.json()["id"]
    client.delete(f"/api/admin/bookings/{new_id}", headers=auth)
    assert stripe.refunds  # the payment came along, so the refund still works


# --- how it reads --------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "payment,cents,label",
    [
        ("shop", 5500, "Pay at the shop ($55)"),
        ("paid", 6550, "Paid online ($65.50)"),
        ("pending", 5500, "Waiting for online payment ($55)"),
        ("shop", 0, "Pay at the shop"),
    ],
)
def test_the_payment_label(payment, cents, label):
    assert booking_model(payment=payment, amount_cents=cents).payment_label == label


def test_the_customer_sees_the_state_but_not_the_internal_id(client, stripe):
    body = online(client).json()
    assert "id" not in body and body["payment"] == "pending"
VICBLESS_EOF
cat > "$STAGE/19" <<'VICBLESS_EOF'
"""Reminders: which ones go out when, never twice, never late, and what Vic can change."""

from datetime import date, datetime

import pytest

from app.database import bookings as bookings_db
from app.database import keys
from app.domain import shop
from app.services import notifications, reminders
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import raw_table
from tests.helpers.builders import make_booking
from tests.helpers.constants import TUESDAY

TUE = date(2026, 10, 13)  # the appointment day; 12:00 pm is 28 hours after the tests' "now" (Mon 10:00 am)


def ny(day: int, hour: int, minute: int = 0) -> datetime:
    """A moment in October 2026, in the shop's timezone."""
    return datetime(2026, 10, day, hour, minute, tzinfo=shop.TIMEZONE)


def appointment(updated=None, **over):
    """A booking Tuesday 12:00 pm. `updated` is when it was made, in the shop's timezone (long ago unless given)."""
    over.setdefault("email", "m@example.com")
    over.setdefault("sms_consent", True)
    b = make_booking(start=720, day=TUE, **over)
    stamp = (updated or ny(1, 9)).isoformat()
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(b.day, b.start, b.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": stamp},
    )
    return bookings_db.get_booking(b.id)


@pytest.fixture
def outbox(sent, texts):
    """Everything sent: emails in `.emails`, texts in `.texts`."""

    class Box:
        emails = sent
        texts_ = texts

    return Box


def count(box):
    return len(box.emails), len(box.texts_)


def test_nothing_is_due_a_day_and_a_half_ahead(outbox):
    appointment()
    assert reminders.send_due(ny(12, 10)) == {"sent": 0, "errors": 0}  # 26 hours before
    assert count(outbox) == (0, 0)


def test_the_24_hour_reminder_goes_out_by_email_and_text(outbox):
    appointment()
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 1  # a sweep 10 minutes after the 24 hour moment
    assert count(outbox) == (1, 1)
    assert "Reminder" in outbox.emails[0].subject and "Reminder" in outbox.texts_[0].body
    assert outbox.texts_[0].to == "5550101234"


def test_a_reminder_is_never_sent_twice(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert reminders.send_due(ny(12, 12, 25))["sent"] == 0
    assert reminders.send_due(ny(12, 18))["sent"] == 0
    assert count(outbox) == (1, 1)


def test_the_2_hour_reminder_follows_the_24_hour_one(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert reminders.send_due(ny(13, 10, 5))["sent"] == 1
    assert count(outbox) == (2, 2)


def test_two_sweeps_at_once_cannot_both_send(outbox, monkeypatch):
    b = appointment()
    from app.database import reminders as db

    assert db.claim(b, "24h") is True
    assert db.claim(b, "24h") is False
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 0  # it was already marked
    assert count(outbox) == (0, 0)


def test_a_reminder_for_a_time_already_passed_when_booked_is_skipped(outbox):
    appointment(updated=ny(12, 13))  # made Monday 1:00 pm: the 24 hour moment (Monday 12:00) was already over
    assert reminders.send_due(ny(12, 13, 15))["sent"] == 0
    assert reminders.send_due(ny(13, 10, 5))["sent"] == 1  # but the 2 hour one is still ahead
    assert count(outbox) == (1, 1)


def test_if_both_are_due_only_the_nearest_is_sent(outbox):
    b = appointment()
    assert reminders.send_due(ny(13, 10, 30))["sent"] == 1  # the sweep was down all night
    assert count(outbox) == (1, 1)
    assert set(bookings_db.get_booking(b.id).reminders_sent) == {"24h", "2h"}


def test_nothing_is_sent_once_the_appointment_has_started(outbox):
    appointment()
    assert reminders.send_due(ny(13, 12, 5))["sent"] == 0
    assert count(outbox) == (0, 0)


def test_only_the_channels_the_customer_chose_are_used(outbox):
    appointment(email="", sms_consent=True)
    appointment_two = make_booking(start=765, day=TUE, phone="5550102222", email="x@example.com", sms_consent=False)
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(appointment_two.day, appointment_two.start, appointment_two.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(1, 9).isoformat()},
    )
    assert reminders.send_due(ny(12, 12, 50))["sent"] == 2
    assert [m.to for m in outbox.texts_] == ["5550101234"]  # the second customer did not agree to texts
    assert [m.to for m in outbox.emails] == ["x@example.com"]  # the first left no email


def test_vic_is_not_sent_the_customers_reminder(outbox):
    appointment()
    reminders.send_due(ny(12, 12, 10))
    assert all(m.to != "5550100777" for m in outbox.texts_) and all(m.to != "vic@example.com" for m in outbox.emails)


def test_a_cancelled_booking_gets_no_reminder(client, auth, outbox):
    book(client, smsConsent=True, email="a@example.com")
    item = schedule_of(client, auth)["items"][0]
    client.delete(f"/api/admin/bookings/{item['id']}", headers=auth)
    outbox.emails.clear()
    outbox.texts_.clear()
    assert reminders.send_due(ny(12, 12, 10))["sent"] == 0 and count(outbox) == (0, 0)


def test_a_moved_booking_starts_over(client, auth, outbox):
    b = appointment()
    reminders.send_due(ny(12, 12, 10))
    assert "24h" in bookings_db.get_booking(b.id).reminders_sent
    r = client.patch(f"/api/admin/bookings/{b.id}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    assert r.status_code == 200
    moved = bookings_db.get_booking(r.json()["id"])
    assert moved.reminders_sent == () and moved.sms_consent is True and moved.code == b.code


def test_a_moved_booking_is_not_reminded_about_moments_before_the_move(client, auth, outbox):
    b = appointment()
    r = client.patch(f"/api/admin/bookings/{b.id}", headers=auth, json={"dateKey": "2026-10-13", "start": 755})
    assert r.status_code == 200, r.text
    new_id = r.json()["id"]
    raw_table().update_item(  # pretend the move happened Tuesday 8:30 am
        Key={"pk": keys.PK, "sk": keys.booking_sk(TUE, 755, new_id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(13, 8, 30).isoformat()},
    )
    outbox.emails.clear()
    outbox.texts_.clear()
    assert reminders.send_due(ny(13, 8, 40))["sent"] == 0  # the 24 hour moment was before the move
    assert reminders.send_due(ny(13, 10, 50))["sent"] == 1  # the 2 hour moment (12:35 - 2h = 10:35) has come
    assert count(outbox) == (1, 1)


def test_one_broken_booking_does_not_stop_the_others(outbox, monkeypatch):
    appointment()
    other = make_booking(start=765, day=TUE, phone="5550102222", email="x@example.com", sms_consent=False)
    raw_table().update_item(
        Key={"pk": keys.PK, "sk": keys.booking_sk(other.day, other.start, other.id)},
        UpdateExpression="SET updatedAt = :u",
        ExpressionAttributeValues={":u": ny(1, 9).isoformat()},
    )
    real = notifications.booking_reminder
    calls = []

    def flaky(booking):
        calls.append(booking.code)
        if len(calls) == 1:
            raise RuntimeError("boom")
        real(booking)

    monkeypatch.setattr(notifications, "booking_reminder", flaky)
    result = reminders.send_due(ny(12, 12, 50))
    assert result == {"sent": 1, "errors": 1}


# --- what Vic can change --------------------------------------------------------------------------------------


def put(client, auth, **extra):
    from tests.test_settings import settings_body

    return client.put("/api/admin/settings", headers=auth, json={**settings_body(), **extra})


def test_the_default_is_24_and_2_hours(client):
    assert client.get("/api/settings").json()["reminderHours"] == [24, 2]


def test_vic_can_choose_the_reminder_times(client, auth):
    assert put(client, auth, reminderHours=[2, 12, 4]).json()["reminderHours"] == [12, 4, 2]  # saved biggest first
    assert client.get("/api/settings").json()["reminderHours"] == [12, 4, 2]


def test_leaving_the_field_out_keeps_what_was_saved(client, auth):
    put(client, auth, reminderHours=[6])
    from tests.test_settings import settings_body

    assert client.put("/api/admin/settings", headers=auth, json=settings_body()).json()["reminderHours"] == [6]


@pytest.mark.parametrize("hours", [[5], [24, 24], [0], [-2], [100], ["24"]])
def test_only_listed_reminder_times_are_accepted(client, auth, hours):
    assert put(client, auth, reminderHours=hours).status_code == 422


def test_no_reminders_at_all_is_allowed_and_sends_nothing(client, auth, outbox):
    assert put(client, auth, reminderHours=[]).json()["reminderHours"] == []
    appointment()
    assert reminders.send_due(ny(13, 10, 30)) == {"sent": 0, "errors": 0}
    assert count(outbox) == (0, 0)


def test_a_new_reminder_time_takes_effect_at_once(client, auth, outbox):
    appointment()
    put(client, auth, reminderHours=[4])
    assert reminders.send_due(ny(13, 8, 5))["sent"] == 1  # 4 hours before 12:00
    assert count(outbox) == (1, 1)


def test_a_damaged_stored_reminder_list_falls_back_to_the_default(client):
    raw_table().put_item(Item={"pk": keys.PK, "sk": "SETTINGS", "reminderHours": ["soon", 5]})
    assert client.get("/api/settings").json()["reminderHours"] == [24, 2]


# --- the scheduled run ------------------------------------------------------------------------------------------


def test_a_scheduled_event_runs_the_sweep(monkeypatch):
    from app import handler

    monkeypatch.setattr(reminders, "send_due", lambda: {"sent": 3, "errors": 0})
    event = {"version": "0", "source": "aws.events", "detail-type": "Scheduled Event", "detail": {}}
    assert handler.lambda_handler(event, None) == {"sent": 3, "errors": 0, "holdsReleased": 0}


def test_a_web_request_still_goes_to_the_api():
    from app.handler import lambda_handler
    from tests.test_handler import http_api_event

    assert lambda_handler(http_api_event("GET", "/api/health"), None)["statusCode"] == 200


def test_a_real_sweep_through_the_handler_with_nothing_to_do():
    from app.handler import lambda_handler

    assert lambda_handler({"source": "aws.events"}, None) == {"sent": 0, "errors": 0, "holdsReleased": 0}
VICBLESS_EOF
cat > "$STAGE/20" <<'VICBLESS_EOF'
"""Vic's settings: the services and prices, and how long an appointment is on each weekday."""

import pytest

from app.database import schedule as schedule_db
from app.domain import shop
from tests.fixtures.settings import REAL_DEFAULTS
from tests.helpers.api import book, busy, schedule_of
from tests.helpers.aws import raw_table
from tests.helpers.builders import booking_body, make_booking, taken_units
from tests.helpers.constants import MONDAY, SATURDAY, TUESDAY, WEDNESDAY

SAT = "2026-10-17"


def settings_body(**slots) -> dict:
    """A valid PUT body: the starting services, and the starting lengths unless a test overrides some days."""
    lengths = dict(zip(shop.WEEKDAY_KEYS, REAL_DEFAULTS.slot_minutes))
    lengths.update(slots)
    services = [{"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in REAL_DEFAULTS.services]
    return {"services": services, "slotMinutes": lengths}


def put(client, auth, body):
    return client.put("/api/admin/settings", headers=auth, json=body)


@pytest.fixture
def real_defaults(monkeypatch):
    """Back to the shop's real starting settings (Monday and Tuesday 45 minutes), for tests about them."""
    monkeypatch.setattr(shop, "DEFAULT_SETTINGS", REAL_DEFAULTS)


# --- what customers and the dashboard read -------------------------------------------------------------


def test_customers_read_the_services_and_lengths(client, real_defaults):
    r = client.get("/api/settings")
    assert r.status_code == 200
    body = r.json()
    assert body["slotMinutes"] == {"mon": 45, "tue": 45, "wed": 35, "thu": 35, "fri": 35, "sat": 35, "sun": 35}
    assert [s["id"] for s in body["services"]] == ["mens-cut", "mens-design", "mens-beard-eyebrow", "buzz-beard", "kids-design"]
    assert body["services"][1] == {
        "id": "mens-design",
        "name": "Men's haircut with design",
        "price": 65,
        "from": True,
        "note": "Small or freestyle design",
    }
    assert r.headers["cache-control"] == "no-store"


def test_the_settings_routes_need_sign_in_only_for_vic(client):
    assert client.get("/api/settings").status_code == 200  # customers need it to draw the pages
    assert client.get("/api/admin/settings").status_code == 401
    assert client.put("/api/admin/settings", json=settings_body()).status_code == 401


def test_vic_reads_what_he_saved(client, auth, real_defaults):
    assert client.get("/api/admin/settings", headers=auth).json()["slotMinutes"]["mon"] == 45
    body = settings_body(mon=30, sat=50)
    assert put(client, auth, body).status_code == 200
    saved = client.get("/api/admin/settings", headers=auth).json()
    assert saved["slotMinutes"]["mon"] == 30 and saved["slotMinutes"]["sat"] == 50
    public = client.get("/api/settings").json()
    assert public.pop("payOnline") is False  # no Stripe keys here
    assert public == saved  # customers see the same thing at once


def test_a_damaged_stored_item_falls_back_to_the_defaults(client, real_defaults):
    raw_table().put_item(Item={"pk": "STAFF#vic", "sk": "SETTINGS", "slotMinutes": [1, 2], "services": "nonsense"})
    assert client.get("/api/settings").json()["slotMinutes"]["mon"] == 45  # not 1, and the site did not break


# --- saving: services -------------------------------------------------------------------------------------


def test_a_new_service_gets_an_id_and_old_ones_keep_theirs(client, auth):
    body = settings_body()
    body["services"].append({"name": "  Hot towel   shave ", "price": 25, "from": False, "note": ""})
    saved = put(client, auth, body).json()
    assert [s["id"] for s in saved["services"][:5]] == [s.id for s in REAL_DEFAULTS.services]
    new = saved["services"][5]
    assert new["id"].startswith("svc-") and new["name"] == "Hot towel shave" and new["price"] == 25
    again = put(client, auth, {"services": saved["services"], "slotMinutes": saved["slotMinutes"]}).json()
    assert again["services"][5]["id"] == new["id"]  # saving again does not hand out a new id


def test_services_can_be_renamed_repriced_reordered_and_removed(client, auth):
    body = settings_body()
    body["services"] = [body["services"][2], body["services"][0]]  # fewer, and in a new order
    body["services"][1]["price"] = 60
    body["services"][0]["name"] = "Cut, beard and eyebrow"
    saved = put(client, auth, body).json()
    assert [(s["id"], s["name"], s["price"]) for s in saved["services"]] == [
        ("mens-beard-eyebrow", "Cut, beard and eyebrow", 65),
        ("mens-cut", "Men's haircut", 60),
    ]


@pytest.mark.parametrize(
    "mutate,fragment",
    [
        (lambda b: b["services"].clear(), "between 1 and 12"),
        (lambda b: b["services"].extend([{"name": f"Extra {i}", "price": 5} for i in range(8)]), "between 1 and 12"),
        (lambda b: b["services"][0].update(name="x"), "needs a name"),
        (lambda b: b["services"][0].update(name="n" * 61), "needs a name"),
        (lambda b: b["services"][0].update(price=-1), "whole number of dollars"),
        (lambda b: b["services"][0].update(price=1000), "whole number of dollars"),
        (lambda b: b["services"][0].update(price=12.5), "Please check"),  # not a whole number
        (lambda b: b["services"][0].update(price="12"), "Please check"),
        (lambda b: b["services"][0].update(note="n" * 121), "service note"),
        (lambda b: b["services"][1].update(name="men's HAIRCUT"), "same name"),
        (lambda b: b["services"][1].update(id="mens-cut"), "Something is wrong"),
        (lambda b: b["services"][0].update(id="Bad Id!"), "Something is wrong"),
    ],
)
def test_bad_services_are_refused_with_a_clear_sentence(client, auth, mutate, fragment):
    body = settings_body()
    mutate(body)
    r = put(client, auth, body)
    assert r.status_code == 422 and fragment in r.json()["error"]["message"]
    assert client.get("/api/settings").json()["services"][0]["name"] == "Men's haircut"  # nothing was saved


# --- saving: appointment lengths ------------------------------------------------------------------------


@pytest.mark.parametrize("minutes", [10, 14, 17, 36, 121, 125, 0, -35])
def test_lengths_must_be_in_range_and_in_steps_of_five(client, auth, minutes):
    r = put(client, auth, settings_body(thu=minutes))
    assert r.status_code == 422 and "between 15 and 120 minutes, in steps of 5" in r.json()["error"]["message"]


@pytest.mark.parametrize("minutes", [15, 25, 35, 45, 60, 120])
def test_lengths_in_steps_of_five_are_accepted(client, auth, minutes):
    assert put(client, auth, settings_body(thu=minutes)).status_code == 200


def test_every_weekday_is_required_and_nothing_else_is_allowed(client, auth):
    body = settings_body()
    del body["slotMinutes"]["fri"]
    assert put(client, auth, body).status_code == 422
    body = settings_body()
    body["slotMinutes"]["funday"] = 30
    assert put(client, auth, body).status_code == 422
    body = settings_body()
    body["slotMinutes"]["mon"] = "45"  # text, not a number
    assert put(client, auth, body).status_code == 422


# --- the 45 minute Monday and Tuesday (Vic's request) -------------------------------------------------------


def test_tuesday_is_45_minutes_by_default(client, real_defaults):
    day = client.get(f"/api/availability?from={TUESDAY}&to={TUESDAY}").json()[TUESDAY]
    assert day["slotMinutes"] == 45
    r = book(client, start=12 * 60 + 45)  # 12:45 is on the 45 minute grid
    assert r.status_code == 201 and r.json()["minutes"] == 45
    assert busy(client) == [12 * 60 + 45]
    assert len(taken_units(date_of(TUESDAY))) == 9  # nine 5 minute units
    assert book(client, start=12 * 60 + 35, name="Other Person", phone="5550109999").status_code == 422  # the old 35 grid


def test_wednesday_is_closed_and_thursday_is_still_35(client, real_defaults):
    days = client.get("/api/availability?from=2026-10-14&to=2026-10-16").json()
    assert days["2026-10-14"]["busy"] == [] and days["2026-10-15"]["slotMinutes"] == 35
    assert book(client, dateKey="2026-10-15", start=11 * 60 + 35).status_code == 201


def date_of(key: str):
    from datetime import date

    return date.fromisoformat(key)


def test_a_length_change_applies_to_new_bookings_straight_away(client, auth):
    assert book(client).status_code == 201  # Tuesday 12:00, 35 minutes (the test default)
    assert put(client, auth, settings_body(tue=25)).status_code == 200
    day = client.get(f"/api/availability?from={TUESDAY}&to={TUESDAY}").json()[TUESDAY]
    assert day["slotMinutes"] == 25 and day["busy"] == [720, 745]  # 12:00-12:25 and 12:25-12:50 both touch the 12:00-12:35 booking
    assert book(client, start=12 * 60 + 50, name="B Person", phone="5550108888").json()["minutes"] == 25


# --- mixed lengths can never double book ------------------------------------------------------------------


def test_a_booking_from_the_old_grid_blocks_every_new_slot_it_overlaps(client, auth):
    assert book(client, start=755).status_code == 201  # Tuesday 12:35 to 1:10 on the old 35 minute grid
    assert put(client, auth, settings_body(tue=45)).status_code == 200  # now 12:00, 12:45, 1:30 ...
    day = client.get(f"/api/availability?from={TUESDAY}&to={TUESDAY}").json()[TUESDAY]
    assert day["busy"] == [720, 765]  # 12:00-12:45 and 12:45-1:30 both overlap 12:35-1:10; 1:30 is free
    for start in (720, 765):
        r = book(client, start=start, name="Late Comer", phone="5550107777")
        assert r.status_code == 409 and r.json()["error"]["code"] == "slot_taken"
    assert book(client, start=810, name="Late Comer", phone="5550107777").status_code == 201


def test_two_grids_cannot_claim_the_same_time_at_the_database(client):
    from app.core.errors import SlotTaken

    make_booking(start=720, minutes=35)  # 12:00 to 12:35
    with pytest.raises(SlotTaken):
        make_booking(start=730, minutes=45, phone="5550102222")  # 12:10 to 12:55 overlaps the end of it
    make_booking(start=755, minutes=45, phone="5550103333")  # 12:35 to 1:20 starts exactly when the first ends: fine


def test_a_block_off_covers_overlapping_slots_of_a_different_length(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": TUESDAY, "start": 720, "end": 780})  # 12:00 to 1:00
    assert r.status_code == 201
    assert put(client, auth, settings_body(tue=45)).status_code == 200
    assert busy(client) == [720, 765]  # 12:00-12:45 and 12:45-1:30 (it starts inside the block)


def test_moving_to_a_day_with_another_length_takes_that_days_length(client, auth):
    assert put(client, auth, settings_body(tue=35, thu=45)).status_code == 200
    book(client, start=720)
    booking = schedule_of(client, auth)["items"][0]
    assert booking["minutes"] == 35
    r = client.patch(f"/api/admin/bookings/{booking['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 11 * 60 + 45})
    assert r.status_code == 200 and r.json()["minutes"] == 45
    assert busy(client, TUESDAY) == []
    assert len(taken_units(date_of("2026-10-15"))) == 9


# --- removed and renamed services -------------------------------------------------------------------------


def test_booking_a_service_vic_has_removed_is_refused(client, auth):
    body = settings_body()
    body["services"] = body["services"][1:]  # "mens-cut" is gone
    put(client, auth, body)
    r = book(client)
    assert r.status_code == 422 and r.json()["error"]["field"] == "serviceId"
    assert busy(client) == []


def test_a_booking_keeps_the_service_name_it_was_made_with(client, auth, sent):
    book(client, email="a@example.com")
    body = settings_body()
    body["services"][0]["name"] = "Signature cut"
    put(client, auth, body)
    item = schedule_of(client, auth)["items"][0]
    assert item["serviceName"] == "Men's haircut"  # what the customer booked
    client.patch(f"/api/admin/bookings/{item['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    moved = [m for m in sent if "moved" in m.subject][0]
    assert "Men's haircut" in moved.text and "Signature cut" not in moved.text
    assert "Signature cut" in [s["name"] for s in client.get("/api/settings").json()["services"]]


# --- a long block needs several transactions ---------------------------------------------------------------


@pytest.fixture
def small_transactions(monkeypatch):
    """Pretend DynamoDB allows only 30 items per transaction, so Saturday (89 units) needs several pieces.

    The real hours never exceed 96 units (Thursday), but Vic can edit lengths and the code must stay safe."""
    from app.database import transactions

    monkeypatch.setattr(transactions, "MAX_TRANSACTION_ITEMS", 30)
    monkeypatch.setattr(transactions, "CHUNK_CLAIMS", 20)


def test_a_whole_saturday_is_written_in_pieces_but_is_still_all_or_nothing(client, auth, small_transactions):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": SAT, "whole": True})
    assert r.status_code == 201
    assert len(schedule_db.query_range(f"{SAT}#CLAIM#", f"{SAT}#CLAIM#~")) == 89  # 36 units before noon + 53 after 12:35
    assert client.delete(f"/api/admin/blocks/{r.json()['id']}", headers=auth).status_code == 200
    assert schedule_db.query_range(f"{SAT}#", f"{SAT}#~") == []  # the claims AND the block are all gone


def test_a_conflict_in_a_later_piece_undoes_the_earlier_pieces(client, auth, small_transactions):
    make_booking(start=16 * 60, day=date_of(SAT), minutes=35)  # 4:00 pm, late in the day, so in a later piece
    before = schedule_db.query_range(f"{SAT}#", f"{SAT}#~")
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": SAT, "whole": True})
    assert r.status_code == 409
    assert schedule_db.query_range(f"{SAT}#", f"{SAT}#~") == before  # not one stray claim or block was left behind


def test_closed_days_report_their_length_but_no_times(client, real_defaults):
    day = client.get(f"/api/availability?from={WEDNESDAY}&to={WEDNESDAY}").json()[WEDNESDAY]
    assert day == {"busy": [], "dayOff": False, "slotMinutes": 35}
VICBLESS_EOF
cat > "$STAGE/21" <<'VICBLESS_EOF'
"""Keeps the backend easy to find your way around. Each layer may only use the layers listed here.

    routes -> services -> database -> domain -> core
Breaking one of these rules fails the tests, so the folders cannot quietly turn back into a tangle.
"""

import ast
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "app"

ALLOWED = {
    "core": set(),
    "domain": {"core"},
    "schemas": {"core", "domain"},
    "database": {"core", "domain"},
    "emailing": {"core", "domain"},
    "texting": {"core", "domain"},
    "payments": {"core", "domain"},
    "services": {"core", "domain", "schemas", "database", "emailing", "texting", "payments"},
    "routes": {"core", "domain", "schemas", "services"},
}
WEB_OK = {"routes", "core/web.py", "main.py", "handler.py"}  # the only places that may import fastapi / starlette
BOTO_OK = {"core/aws.py"}
BOTOCORE_OK_DIR = "database"


def py_files():
    return [p for p in APP.rglob("*.py") if "__pycache__" not in p.parts]


def imports(path: Path):
    """Yield (kind, name): ('app', 'database') for our own packages, ('lib', 'fastapi') for others."""
    rel = path.relative_to(APP)
    package = ["app", *rel.parts[:-1]]
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield "lib", a.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0:
                yield "lib", (node.module or "").split(".")[0]
                continue
            base = package[: len(package) - (node.level - 1)]
            target = base + (node.module.split(".") if node.module else [])
            if len(target) >= 2:
                yield "app", target[1]
            else:  # "from .. import x": x is itself a package or module of app
                for a in node.names:
                    yield "app", a.name


def layer_of(path: Path):
    parts = path.relative_to(APP).parts
    return parts[0] if len(parts) > 1 else None


def test_every_layer_only_uses_the_layers_below_it():
    problems = []
    for path in py_files():
        layer = layer_of(path)
        if layer not in ALLOWED:
            continue
        for kind, name in imports(path):
            if kind == "app" and name != layer and name not in ALLOWED[layer]:
                problems.append(
                    f"{path.relative_to(APP)} imports app.{name} ({layer} may only use {sorted(ALLOWED[layer]) or 'nothing else'})"
                )
    assert not problems, "\n".join(problems)


def test_only_the_web_layer_knows_about_fastapi():
    problems = []
    for path in py_files():
        rel = path.relative_to(APP).as_posix()
        if any(rel == ok or rel.startswith(ok + "/") for ok in WEB_OK):
            continue
        for kind, name in imports(path):
            if kind == "lib" and name in ("fastapi", "starlette", "mangum"):
                problems.append(f"{rel} imports {name}")
    assert not problems, "\n".join(problems)


def test_aws_libraries_stay_in_their_place():
    problems = []
    for path in py_files():
        rel = path.relative_to(APP).as_posix()
        for kind, name in imports(path):
            if kind == "lib" and name == "boto3" and rel not in BOTO_OK:
                problems.append(f"{rel} imports boto3 (only core/aws.py may)")
            if kind == "lib" and name == "botocore" and not rel.startswith(BOTOCORE_OK_DIR + "/"):
                problems.append(f"{rel} imports botocore (only database/ may)")
    assert not problems, "\n".join(problems)


def test_no_loose_modules_beyond_the_entry_points():
    loose = {p.name for p in APP.glob("*.py")}
    assert loose == {"__init__.py", "main.py", "handler.py"}, loose
VICBLESS_EOF
cat > "$STAGE/22" <<'VICBLESS_EOF'
import { useEffect, useMemo, useRef, useState } from 'react'
import { HOURS } from '../config.js'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { formatPhone, mailtoHref, telHref } from '../lib/format.js'
import { findService, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import BlockOff from './BlockOff.jsx'
import ConfirmBox from './ConfirmBox.jsx'
import JumpToDate from './JumpToDate.jsx'
import MoveBooking from './MoveBooking.jsx'
import NoteText from './NoteText.jsx'
import { describeRange } from './blocks.js'
import { cancelBooking, getDay, removeBlock } from './adminApi.js'
import { buildDayRows } from './schedule.js'
import { cancelMessage, paymentLabel, textsLabel } from './notify.js'

const Chevron = ({ direction }) => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path
      d={direction === 'left' ? 'M15 5l-7 7 7 7' : 'M9 5l7 7-7 7'}
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
)

// `ctl` is the set of actions the schedule gives every card (see `ctl` in Schedule below).
function BookingCard({ item, ctl }) {
  const shop = useShopSettings()
  // The name the customer booked, even if Vic has renamed or removed the service since.
  const service = findService(shop, item.serviceId)
  const serviceName = item.serviceName || (service ? service.name : 'Appointment')
  const tel = telHref(item.phone)
  // Tapping the email opens his email app, addressed to the customer, with the subject already written.
  const mail = mailtoHref(
    item.email,
    `Your Vicbless appointment on ${fromKey(item.dateKey).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })} at ${fmtTime(item.start)}`,
  )
  const texts = textsLabel(item)
  const pay = paymentLabel(item)
  const confirming = ctl.isCancelling(item)
  const moving = ctl.isMoving(item)
  return (
    <article className="admin-card">
      <div className="admin-card-head">
        <h3>
          {item.name}
          {item.source === 'sample' && <span className="admin-sample-badge">sample</span>}
        </h3>
        {item.source !== 'sample' && item.code && (
          <p className="admin-code" aria-label="Booking code">
            {item.code}
          </p>
        )}
      </div>
      <p className="admin-meta">
        {serviceName}, {item.minutes} min
      </p>
      <p className="admin-pay-row">
        <span className={`pay-badge pay-${pay.state}`}>
          <span aria-hidden="true">{pay.mark}</span> {pay.words}
        </span>
      </p>
      {item.phone && (
        <div className="admin-phone-row">
          {tel ? (
            <a className="phone-link" href={tel}>
              {formatPhone(item.phone)}
            </a>
          ) : (
            <span>{formatPhone(item.phone)}</span>
          )}
          <span className={`texts-badge ${texts.on ? 'texts-on' : 'texts-off'}`} title={texts.on ? 'Agreed to texts' : "Didn't agree to texts"}>
            <span aria-hidden="true">{texts.mark}</span> {texts.words}
          </span>
        </div>
      )}
      {item.email &&
        (mail ? (
          <a className="email-link" href={mail}>
            {item.email}
          </a>
        ) : (
          <span className="email-link">{item.email}</span>
        ))}
      {item.notes && <NoteText text={item.notes} who={item.name} />}

      {confirming && (
        <ConfirmBox
          label={`Cancel ${item.name}'s booking?`}
          keepLabel="Keep it"
          yesLabel="Yes, cancel it"
          workingLabel="Cancelling…"
          working={ctl.working}
          onKeep={ctl.keep}
          onYes={() => ctl.doCancel(item)}
        >
          {cancelMessage(item, fmtTime(item.start), serviceName)}
        </ConfirmBox>
      )}

      {moving && <MoveBooking item={item} onClose={ctl.closeMove} onMoved={ctl.doMoved} />}

      {!confirming && !moving && (
        <div className="admin-card-actions">
          {item.payment !== 'pending' && (
            <button type="button" className="admin-box-btn" onClick={() => ctl.askMove(item)} aria-label={`Change ${item.name}'s ${fmtTime(item.start)} booking time`}>
              Change time
            </button>
          )}
          <button type="button" className="admin-box-btn admin-box-danger" onClick={() => ctl.askCancel(item)} aria-label={`Cancel ${item.name}'s ${fmtTime(item.start)} booking`}>
            Cancel
          </button>
        </div>
      )}
    </article>
  )
}

function BlockCard({ block, ctl }) {
  const range = describeRange(block.start, block.end)
  const confirming = ctl.isUnblocking(block)
  return (
    <article className="admin-card admin-card-block">
      <h3>{block.whole ? 'Day off' : 'Blocked'}</h3>
      <p className="admin-meta">{range}</p>
      {block.note && <p className="admin-notes">{block.note}</p>}

      {confirming ? (
        <ConfirmBox
          label="Open this time back up?"
          keepLabel="Keep it blocked"
          yesLabel="Yes, open it up"
          workingLabel="Opening…"
          working={ctl.working}
          onKeep={ctl.keep}
          onYes={() => ctl.doUnblock(block)}
        >
          Open {range} back up? Customers will be able to book it again.
        </ConfirmBox>
      ) : (
        <button type="button" className="admin-box-btn" onClick={() => ctl.askUnblock(block)} aria-label={`Remove block ${range}`}>
          Remove block
        </button>
      )}
    </article>
  )
}

export default function Schedule() {
  const shop = useShopSettings()
  const [dateKey, setDateKey] = useState(() => keyOf(new Date()))
  const [state, setState] = useState({ status: 'loading' })
  const [attempt, setAttempt] = useState(0)
  const [confirm, setConfirm] = useState(null) // { kind: 'cancel' | 'unblock', id }
  const [movingId, setMovingId] = useState(null) // the booking whose "Change time" panel is open
  const [working, setWorking] = useState(false)
  const [actionError, setActionError] = useState('')
  const [flash, setFlash] = useState('')
  const [blockOpen, setBlockOpen] = useState(false)
  const dateKeyRef = useRef(dateKey)
  dateKeyRef.current = dateKey

  useEffect(() => {
    let alive = true
    setState({ status: 'loading' })
    getDay(dateKey)
      .then((day) => alive && setState({ status: 'ready', day }))
      .catch(() => alive && setState({ status: 'error' }))
    return () => {
      alive = false
    }
  }, [dateKey, attempt])

  // Moving to another day closes anything that was open.
  useEffect(() => {
    setConfirm(null)
    setMovingId(null)
    setActionError('')
    setFlash('')
    setBlockOpen(false)
  }, [dateKey])

  // The confirmation message fades after a few seconds.
  useEffect(() => {
    if (!flash) return undefined
    const timer = setTimeout(() => setFlash(''), 8000)
    return () => clearTimeout(timer)
  }, [flash])

  const date = fromKey(dateKey)
  const today = keyOf(new Date())

  const view = useMemo(
    () =>
      state.status === 'ready'
        ? buildDayRows({
            date: fromKey(dateKey),
            hours: HOURS,
            items: state.day.items,
            blocks: state.day.blocks,
            slotMinutes: slotFor(shop, fromKey(dateKey)),
          })
        : null,
    [state, dateKey, shop],
  )

  function shift(days) {
    const d = fromKey(dateKey)
    d.setDate(d.getDate() + days)
    setDateKey(keyOf(d))
  }

  // Fetches the day again without the "Loading" flash, so the screen updates in place.
  async function refresh() {
    const day = await getDay(dateKey)
    if (dateKeyRef.current === dateKey) setState({ status: 'ready', day })
  }

  async function run(action, message) {
    setWorking(true)
    setActionError('')
    try {
      await action()
      await refresh()
      setConfirm(null)
      setFlash(message)
    } catch (err) {
      // A reason written for Vic (the card could not be refunded) is shown as it is.
      setActionError(err && err.friendly ? err.message : 'That did not work. Nothing was changed. Try again.')
    } finally {
      setWorking(false)
    }
  }

  // Only one panel is open at a time: asking to cancel closes "Change time", and the other way round.
  const askCancel = (item) => {
    setMovingId(null)
    setConfirm({ kind: 'cancel', id: item.id })
  }
  const askUnblock = (block) => setConfirm({ kind: 'unblock', id: block.id })
  const askMove = (item) => {
    setConfirm(null)
    setActionError('')
    setMovingId(item.id)
  }
  const keep = () => setConfirm(null)
  const doCancel = (item) =>
    run(() => cancelBooking(item), `Cancelled ${item.name} at ${fmtTime(item.start)}. That time is open again.`)
  const doUnblock = (block) =>
    run(() => removeBlock(block.id), `Opened ${describeRange(block.start, block.end)} back up.`)
  // Called by the "Change time" panel once the booking has moved: reload the day, close the panel, say what happened.
  const doMoved = async (message) => {
    await refresh()
    setMovingId(null)
    setFlash(message)
  }

  // Everything a card needs, in one object, so the cards don't each need six separate props.
  const ctl = {
    isCancelling: (item) => confirm?.kind === 'cancel' && confirm.id === item.id,
    isUnblocking: (block) => confirm?.kind === 'unblock' && confirm.id === block.id,
    isMoving: (item) => movingId === item.id,
    working,
    askCancel,
    askUnblock,
    askMove,
    closeMove: () => setMovingId(null),
    keep,
    doCancel,
    doUnblock,
    doMoved,
  }

  return (
    <section aria-label="Day schedule">
      <div className="admin-day-nav">
        <button type="button" className="admin-icon-btn" aria-label="Previous day" onClick={() => shift(-1)}>
          <Chevron direction="left" />
        </button>
        <div className="admin-day-title">
          <h2>{date.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })}</h2>
          <div className="admin-day-tools">
            {dateKey === today ? (
              <span className="admin-today-tag">Today</span>
            ) : (
              <button type="button" className="admin-link-btn" onClick={() => setDateKey(today)}>
                Back to today
              </button>
            )}
            <JumpToDate value={dateKey} onPick={setDateKey} />
          </div>
        </div>
        <button type="button" className="admin-icon-btn" aria-label="Next day" onClick={() => shift(1)}>
          <Chevron direction="right" />
        </button>
      </div>

      <div role="status" aria-live="polite" className="admin-flash-wrap">
        {flash && <p className="admin-flash">{flash}</p>}
      </div>

      {actionError && (
        <p className="notice" role="alert">
          {actionError}
        </p>
      )}

      {state.status === 'loading' && (
        <p role="status" className="admin-status">
          Loading the day…
        </p>
      )}

      {state.status === 'error' && (
        <div>
          <p className="notice" role="alert">
            Could not load this day.
          </p>
          <button type="button" className="btn" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      )}

      {view && view.closed && <p className="empty">Closed on {date.toLocaleDateString(undefined, { weekday: 'long' })}s.</p>}

      {view && !view.closed && (
        <>
          <div className="admin-summary-row">
            <p className="admin-summary">
              {view.booked} booked, {view.blocked > 0 ? `${view.blocked} blocked, ` : ''}
              {view.open} open
            </p>
            {!blockOpen && (
              <button type="button" className="btn" aria-expanded={false} onClick={() => setBlockOpen(true)}>
                Block off time
              </button>
            )}
          </div>

          {blockOpen && (
            <BlockOff
              dateKey={dateKey}
              items={state.day.items}
              blocks={state.day.blocks}
              onClose={() => setBlockOpen(false)}
              onSaved={async (message) => {
                await refresh()
                setBlockOpen(false)
                setFlash(message)
              }}
            />
          )}

          <ol className="admin-rows">
            {view.groups.map((group, gi) => (
              <GroupRows key={group.open} group={group} previous={view.groups[gi - 1]} ctl={ctl} />
            ))}
          </ol>

          {(view.unmatched.length > 0 || view.unmatchedBlocks.length > 0) && (
            <div className="admin-unmatched">
              <h3>Other items on this day</h3>
              <p className="admin-meta">These are not on a regular time block, so they are listed here.</p>
              {view.unmatched.map((item) => (
                <div key={item.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(item.start)}</span>
                  <BookingCard item={item} ctl={ctl} />
                </div>
              ))}
              {view.unmatchedBlocks.map((block) => (
                <div key={block.id} className="admin-row-lone">
                  <span className="admin-time">{fmtTime(block.start)}</span>
                  <BlockCard block={block} ctl={ctl} />
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </section>
  )
}

function GroupRows({ group, previous, ctl }) {
  return (
    <>
      {previous && (
        <li className="admin-break">
          Break, {fmtTime(previous.close)} to {fmtTime(group.open)}
        </li>
      )}
      {group.rows.map((row) => (
        <li key={row.start} className={`admin-row admin-${row.kind}`}>
          <span className="admin-time">{fmtTime(row.start)}</span>
          <div className="admin-slot">
            {row.kind === 'booking' && <BookingCard item={row.item} ctl={ctl} />}
            {row.kind === 'continues' && <p className="admin-continues">Still with {row.item.name}</p>}
            {row.kind === 'blocked' && <BlockCard block={row.block} ctl={ctl} />}
            {row.kind === 'blocked-continues' && <p className="admin-continues">Still blocked</p>}
            {row.kind === 'open' && <p className="admin-open-label">Open</p>}
          </div>
        </li>
      ))}
    </>
  )
}
VICBLESS_EOF
cat > "$STAGE/23" <<'VICBLESS_EOF'
/* Admin screens. Every rule starts with .admin so nothing here can touch the public pages. */

.admin {
  max-width: 720px;
  margin: 0 auto;
  padding: calc(16px + env(safe-area-inset-top, 0px)) 16px calc(48px + env(safe-area-inset-bottom, 0px));
}

/* The big welcome line, the page heading. Vic's name is picked out in the accent colour. */
.admin-greeting {
  margin: 20px 0 8px;
  font-size: clamp(2.1rem, 9vw, 3.3rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.admin-name {
  color: var(--accent);
}

.admin-lede {
  margin: 0 0 24px;
  color: var(--muted);
}

/* ---- The logo: goes around an oval like a carousel and turns as it goes ----
   Facing you at the front of the oval, edge-on at the sides, facing away at the back (where the writing
   reads backwards, like a mirror). Bigger at the front, smaller at the back. Always flat.
   To adjust, change these on .admin-loop:
     --orbit-time  seconds for one lap (3.5s now)
     --ax          how wide the oval is, as a % of the logo's own width
     --by          how tall the oval is, as a % of the logo's own height
     --depth       how much bigger at the front / smaller at the back (0.28 = 28%)
   --persp (set per spot below) is how strong the 3D looks: smaller means stronger.
   The logo's size in each spot is the width on its .admin-loop-orbit rule. A bigger logo needs a bigger
   frame, because the whole lap has to fit inside it. */
.admin-loop {
  --orbit-time: 3.5s;
  --ax: 28;
  --by: 20;
  --depth: 0.28;
}

/* Anything outside the frame is cut off, so the frame is sized to hold the whole lap.
   The front of the oval swings low and big, so the logo sits a little higher in its frame (--lift)
   to give that swing room. */
.admin-loop-frame {
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: center;
  padding-bottom: calc(var(--lift) * 2);
  overflow: hidden;
}

.admin-loop-orbit {
  animation: admin-orbit var(--orbit-time) linear infinite;
}

.admin-loop-still {
  animation: none;
  transform: none;
}

.admin-loop .logo {
  width: 100%;
}

/* Sign-in: a little smaller than the old still logo, to leave room for the lap. The frame is the full
   width of the screen (it cancels the page's 16px side padding). */
.admin-loop-hero {
  --persp: 880px;
  --lift: 13px;
  width: calc(100% + 32px);
  height: 160px;
  margin: 0 -16px 8px;
}

.admin-loop-hero .admin-loop-frame {
  width: 100%;
  height: 100%;
}

/* 260px, but on a narrower phone it shrinks so the whole lap (about 1.45 times the logo's width)
   still fits on the screen. */
.admin-loop-hero .admin-loop-orbit {
  width: min(260px, calc((100vw - 12px) / 1.5));
}

/* Dashboard top bar: the logo's place in the bar is this tall, but its frame is the whole width of the bar. */
.admin-loop-bar {
  --persp: 490px;
  --lift: 7px;
  width: 144px;
  height: 94px;
}

.admin-loop-bar .admin-loop-frame {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 14px;
  left: 0;
  pointer-events: none;
}

.admin-loop-bar .admin-loop-orbit {
  width: 144px;
}

.admin-bar .menu-toggle {
  position: relative;
  z-index: 3;
  background: var(--bg);
}

@keyframes admin-orbit {
  0% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(0deg);
  }

  2.0833% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(7.5deg);
  }

  4.1667% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(15deg);
  }

  6.25% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(22.5deg);
  }

  8.3333% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(30deg);
  }

  10.4167% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(37.5deg);
  }

  12.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(45deg);
  }

  14.5833% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(52.5deg);
  }

  16.6667% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(60deg);
  }

  18.75% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(67.5deg);
  }

  20.8333% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(75deg);
  }

  22.9167% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(82.5deg);
  }

  25% {
    transform: translate(calc(var(--ax) * -1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(90deg);
  }

  27.0833% {
    transform: translate(calc(var(--ax) * -0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(97.5deg);
  }

  29.1667% {
    transform: translate(calc(var(--ax) * -0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(105deg);
  }

  31.25% {
    transform: translate(calc(var(--ax) * -0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(112.5deg);
  }

  33.3333% {
    transform: translate(calc(var(--ax) * -0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(120deg);
  }

  35.4167% {
    transform: translate(calc(var(--ax) * -0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(127.5deg);
  }

  37.5% {
    transform: translate(calc(var(--ax) * -0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(135deg);
  }

  39.5833% {
    transform: translate(calc(var(--ax) * -0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(142.5deg);
  }

  41.6667% {
    transform: translate(calc(var(--ax) * -0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(150deg);
  }

  43.75% {
    transform: translate(calc(var(--ax) * -0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(157.5deg);
  }

  45.8333% {
    transform: translate(calc(var(--ax) * -0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(165deg);
  }

  47.9167% {
    transform: translate(calc(var(--ax) * -0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(172.5deg);
  }

  50% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * -1%)) scale(calc(1 + var(--depth) * -1)) perspective(var(--persp)) rotateY(180deg);
  }

  52.0833% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * -0.9914%)) scale(calc(1 + var(--depth) * -0.9914)) perspective(var(--persp)) rotateY(187.5deg);
  }

  54.1667% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * -0.9659%)) scale(calc(1 + var(--depth) * -0.9659)) perspective(var(--persp)) rotateY(195deg);
  }

  56.25% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * -0.9239%)) scale(calc(1 + var(--depth) * -0.9239)) perspective(var(--persp)) rotateY(202.5deg);
  }

  58.3333% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * -0.866%)) scale(calc(1 + var(--depth) * -0.866)) perspective(var(--persp)) rotateY(210deg);
  }

  60.4167% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * -0.7934%)) scale(calc(1 + var(--depth) * -0.7934)) perspective(var(--persp)) rotateY(217.5deg);
  }

  62.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * -0.7071%)) scale(calc(1 + var(--depth) * -0.7071)) perspective(var(--persp)) rotateY(225deg);
  }

  64.5833% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * -0.6088%)) scale(calc(1 + var(--depth) * -0.6088)) perspective(var(--persp)) rotateY(232.5deg);
  }

  66.6667% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * -0.5%)) scale(calc(1 + var(--depth) * -0.5)) perspective(var(--persp)) rotateY(240deg);
  }

  68.75% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * -0.3827%)) scale(calc(1 + var(--depth) * -0.3827)) perspective(var(--persp)) rotateY(247.5deg);
  }

  70.8333% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * -0.2588%)) scale(calc(1 + var(--depth) * -0.2588)) perspective(var(--persp)) rotateY(255deg);
  }

  72.9167% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * -0.1305%)) scale(calc(1 + var(--depth) * -0.1305)) perspective(var(--persp)) rotateY(262.5deg);
  }

  75% {
    transform: translate(calc(var(--ax) * 1%), calc(var(--by) * 0%)) scale(calc(1 + var(--depth) * 0)) perspective(var(--persp)) rotateY(270deg);
  }

  77.0833% {
    transform: translate(calc(var(--ax) * 0.9914%), calc(var(--by) * 0.1305%)) scale(calc(1 + var(--depth) * 0.1305)) perspective(var(--persp)) rotateY(277.5deg);
  }

  79.1667% {
    transform: translate(calc(var(--ax) * 0.9659%), calc(var(--by) * 0.2588%)) scale(calc(1 + var(--depth) * 0.2588)) perspective(var(--persp)) rotateY(285deg);
  }

  81.25% {
    transform: translate(calc(var(--ax) * 0.9239%), calc(var(--by) * 0.3827%)) scale(calc(1 + var(--depth) * 0.3827)) perspective(var(--persp)) rotateY(292.5deg);
  }

  83.3333% {
    transform: translate(calc(var(--ax) * 0.866%), calc(var(--by) * 0.5%)) scale(calc(1 + var(--depth) * 0.5)) perspective(var(--persp)) rotateY(300deg);
  }

  85.4167% {
    transform: translate(calc(var(--ax) * 0.7934%), calc(var(--by) * 0.6088%)) scale(calc(1 + var(--depth) * 0.6088)) perspective(var(--persp)) rotateY(307.5deg);
  }

  87.5% {
    transform: translate(calc(var(--ax) * 0.7071%), calc(var(--by) * 0.7071%)) scale(calc(1 + var(--depth) * 0.7071)) perspective(var(--persp)) rotateY(315deg);
  }

  89.5833% {
    transform: translate(calc(var(--ax) * 0.6088%), calc(var(--by) * 0.7934%)) scale(calc(1 + var(--depth) * 0.7934)) perspective(var(--persp)) rotateY(322.5deg);
  }

  91.6667% {
    transform: translate(calc(var(--ax) * 0.5%), calc(var(--by) * 0.866%)) scale(calc(1 + var(--depth) * 0.866)) perspective(var(--persp)) rotateY(330deg);
  }

  93.75% {
    transform: translate(calc(var(--ax) * 0.3827%), calc(var(--by) * 0.9239%)) scale(calc(1 + var(--depth) * 0.9239)) perspective(var(--persp)) rotateY(337.5deg);
  }

  95.8333% {
    transform: translate(calc(var(--ax) * 0.2588%), calc(var(--by) * 0.9659%)) scale(calc(1 + var(--depth) * 0.9659)) perspective(var(--persp)) rotateY(345deg);
  }

  97.9167% {
    transform: translate(calc(var(--ax) * 0.1305%), calc(var(--by) * 0.9914%)) scale(calc(1 + var(--depth) * 0.9914)) perspective(var(--persp)) rotateY(352.5deg);
  }

  100% {
    transform: translate(calc(var(--ax) * 0%), calc(var(--by) * 1%)) scale(calc(1 + var(--depth) * 1)) perspective(var(--persp)) rotateY(360deg);
  }
}

/* Sign-in is a single centred column. */
.admin-signin {
  max-width: 440px;
  text-align: center;
}

.admin-signin form {
  text-align: left;
}

.admin-signin .btn {
  width: 100%;
}

.admin-signin a {
  color: var(--accent);
}

.admin-foot {
  margin-top: 40px;
  padding-top: 20px;
  font-size: 0.85rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-align: center;
  color: var(--muted);
  border-top: 1px solid var(--line);
}

.admin-preview-note {
  margin: 12px 0 20px;
  padding: 10px 12px;
  font-size: 0.88rem;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

/* Top bar: menu on the left, logo in the middle (the same arrangement as the public site). */
.admin-bar {
  position: relative; /* the menu panel hangs just under the bar */
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  gap: 12px;
  padding-bottom: 14px;
  border-bottom: 2px solid var(--accent);
}

.admin-bar .site-menu {
  justify-self: start;
}

.admin-bar .menu-panel {
  left: 0;
  max-height: calc(100vh - 120px);
  max-height: calc(100svh - 120px);
}

/* ---- day navigation ---- */
.admin-day-nav {
  display: grid;
  grid-template-columns: 48px 1fr 48px;
  gap: 8px;
  align-items: center;
  margin-bottom: 12px;
}

.admin-icon-btn {
  display: grid;
  place-items: center;
  width: 48px;
  height: 48px;
  padding: 0;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-icon-btn:hover {
  border-color: var(--accent);
}

.admin-day-title {
  text-align: center;
}

.admin-day-title h2 {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 800;
}

/* Under the date: Today (or Back to today) and the Pick a date button. */
.admin-day-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 10px;
  margin-top: 8px;
}

/* Pick a date: a big pill. The real date field is invisible and covers all of it, so any tap opens the
   phone's own date picker. 16px text stops iPhones from zooming in. */
.admin-jump {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 48px;
  padding: 0 18px;
  font-weight: 800;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--accent);
  border-radius: 999px;
  cursor: pointer;
}

.admin-jump:hover {
  background: var(--bg);
}

.admin-jump:focus-within {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.admin-jump input[type='date'] {
  position: absolute;
  inset: -2px; /* reaches over the pill's own 2px outline too, so every part of it is the real field */
  width: calc(100% + 4px);
  height: calc(100% + 4px);
  margin: 0;
  padding: 0;
  font-size: 16px;
  opacity: 0;
  cursor: pointer;
}

.admin-jump input[type='date']::-webkit-calendar-picker-indicator {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0;
  cursor: pointer;
}

.admin-today-tag {
  display: inline-block;
  margin-top: 2px;
  padding: 1px 10px;
  font-size: 0.78rem;
  font-weight: 700;
  color: var(--on-accent);
  background: var(--accent);
  border-radius: 999px;
}

.admin-link-btn {
  min-height: 44px;
  padding: 8px 12px;
  font-size: 0.85rem;
  font-weight: 600;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
  background: none;
  border: 0;
}

.admin-status {
  color: var(--muted);
}

.admin-summary {
  margin: 0 0 8px;
  color: var(--muted);
  font-weight: 600;
}

/* ---- the day ---- */
.admin-rows {
  margin: 0;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.admin-row {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  align-items: start;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-time {
  padding-top: 2px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.admin-open-label,
.admin-continues {
  margin: 0;
  padding: 4px 0;
  color: var(--muted);
}

.admin-open .admin-time {
  color: var(--muted);
  font-weight: 600;
}

.admin-card {
  padding: 10px 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-card h3 {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 800;
}

.admin-card p {
  margin: 2px 0 0;
}

.admin-meta {
  font-size: 0.92rem;
  color: var(--muted);
}

.admin-notes {
  font-size: 0.92rem;
  font-style: italic;
}

.admin-card .phone-link,
.admin-card .email-link {
  display: block;
  width: fit-content;
  max-width: 100%;
  padding: 6px 0;
  overflow-wrap: anywhere;
}

.admin-card .email-link {
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-card span.email-link {
  color: var(--ink);
  text-decoration: none;
}

.admin-sample-badge {
  margin-left: 8px;
  padding: 1px 8px;
  font-size: 0.7rem;
  font-weight: 600;
  vertical-align: middle;
  color: var(--muted);
  border: 1px solid var(--line);
  border-radius: 999px;
}

.admin-break {
  padding: 10px 0;
  font-size: 0.85rem;
  text-align: center;
  color: var(--muted);
  border-bottom: 1px dashed var(--line);
}

.admin-unmatched {
  margin-top: 24px;
}

.admin-unmatched h3 {
  margin: 0 0 4px;
}

.admin-row-lone {
  display: grid;
  grid-template-columns: 84px 1fr;
  gap: 12px;
  margin-top: 10px;
}

/* ---- actions: cancel, block off time ---- */
.admin-summary-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin: 0 0 8px;
}

.admin-summary-row .admin-summary {
  margin: 0;
}

.admin-summary-row .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

/* Cancel and Remove block: real boxes with a big, easy tap target. */
.admin-box-btn {
  display: block;
  width: 100%;
  max-width: 280px;
  min-height: 52px;
  margin-top: 12px;
  padding: 12px 18px;
  font-size: 1rem;
  font-weight: 800;
  text-align: center;
  color: var(--ink);
  background: transparent;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-box-btn:hover {
  border-color: var(--ink);
}

.admin-box-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-box-danger:hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-confirm {
  margin-top: 10px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-confirm-text {
  margin: 0 0 14px;
  font-size: 0.95rem;
}

.admin-confirm-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.admin-confirm-actions .btn {
  padding: 10px 14px;
  font-size: 0.92rem;
}

.admin-danger {
  color: var(--danger);
  border-color: var(--danger);
}

.admin-danger:not(:disabled):hover {
  color: var(--bg);
  background: var(--danger);
  border-color: var(--danger);
}

.admin-card-block {
  background: transparent;
  border-style: dashed;
  border-left: 5px solid var(--muted);
}

.admin-blocked-continues .admin-time,
.admin-blocked .admin-time {
  color: var(--muted);
}

.admin-flash-wrap {
  min-height: 0;
}

.admin-flash {
  margin: 0 0 12px;
  padding: 10px 12px;
  font-weight: 600;
  border: 2px solid var(--accent);
  border-radius: 8px;
}

/* ---- block off time form ---- */
.admin-block-form {
  margin: 4px 0 16px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-block-form h3 {
  margin: 0 0 8px;
  font-size: 1.2rem;
  font-weight: 800;
}

.admin-block-form fieldset {
  margin: 0 0 8px;
  padding: 0;
  border: 0;
}

.admin-block-form legend {
  margin-bottom: 4px;
  padding: 0;
  font-weight: 700;
}

.admin-radio {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 44px;
}

.admin-radio input {
  width: 20px;
  height: 20px;
  accent-color: var(--accent);
}

.admin-block-times {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.admin-block-form select {
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-block-form select:focus {
  border-color: var(--accent);
}

.admin-conflicts {
  margin: 0 0 12px;
  padding: 10px 12px;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.admin-conflicts p {
  margin: 0;
  font-weight: 600;
}

.admin-conflicts p + p {
  margin-top: 6px;
}

/* ---- Phones: a roomier "Block off time" ----
   Bigger time pickers, radio buttons and buttons, because the compact sizes that suit a mouse are small for a
   thumb. This applies to phones and touch tablets only; computers keep the compact sizes. */
@media (max-width: 640px), (pointer: coarse) {
  .admin-summary-row {
    flex-wrap: wrap;
    gap: 10px;
  }

  .admin-summary-row .btn {
    min-height: 56px;
    padding: 12px 20px;
    font-size: 1.05rem;
    white-space: nowrap;
  }

  .admin-block-form {
    padding: 18px;
  }

  .admin-block-form legend,
  .admin-block-form .field label {
    font-size: 1.05rem;
  }

  .admin-radio {
    gap: 14px;
    min-height: 58px;
    font-size: 1.1rem;
  }

  .admin-radio input {
    width: 28px;
    height: 28px;
  }

  .admin-block-times {
    gap: 14px;
  }

  .admin-block-form select {
    min-height: 64px;
    padding: 14px 16px;
    font-size: 1.15rem;
    font-weight: 700;
  }

  .admin-block-form .field input {
    min-height: 60px;
    font-size: 1.1rem;
  }

  .admin-block-form .actions .btn {
    flex: 1;
    min-height: 60px;
    font-size: 1.1rem;
  }
}

/* On the narrowest phones the From and Until pickers stack, so each one is full width and big. */
@media (max-width: 380px) {
  .admin-block-times {
    grid-template-columns: 1fr;
  }

  .admin-summary-row .btn {
    flex: 1 1 100%;
  }
}

/* On phones the two buttons at the bottom of the form stack, one per row, so each label fits on one line. */
@media (max-width: 480px) {
  .admin-block-form .actions {
    flex-direction: column;
  }
}

/* ---- long notes: wrap inside the card, fold behind "Show more" ---- */

/* A grid column can't shrink below its widest word unless told it may. This is what stopped a long note
   (or one long unbroken string) from pushing the page sideways. */
.admin-row,
.admin-row-lone {
  grid-template-columns: 84px minmax(0, 1fr);
}

.admin-slot,
.admin-row-lone > :last-child,
.admin-card {
  min-width: 0;
}

.admin-notes {
  white-space: pre-line; /* keep the customer's line breaks, wrap everything else */
  overflow-wrap: anywhere;
}

.admin-notes-folded {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  overflow: hidden;
}

.admin-notes-toggle {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 44px;
  margin-top: 2px;
  padding: 0 6px 0 0;
  font-size: 0.92rem;
  font-weight: 700;
  color: var(--accent);
  background: transparent;
  border: 0;
  cursor: pointer;
}

.admin-notes-toggle:hover {
  text-decoration: underline;
  text-underline-offset: 3px;
}

.admin-chevron {
  transition: transform 0.15s ease;
}

.admin-chevron.open {
  transform: rotate(180deg);
}

@media (prefers-reduced-motion: reduce) {
  .admin-chevron {
    transition: none;
  }
}

/* ---- Change time / Cancel buttons, and the Change time panel ---- */
.admin-card-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 12px;
}

.admin-card-actions .admin-box-btn {
  flex: 1 1 140px;
  width: auto;
  max-width: none;
  margin-top: 0;
}

.admin-move-form {
  margin: 12px 0 0;
  background: var(--bg);
}

.admin-move-form h3 {
  margin: 0 0 2px;
}

.admin-move-form .field input[type='date'] {
  width: 100%;
}

.admin-move-times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(104px, 1fr));
  gap: 8px;
  margin: 0 0 12px;
}

.admin-move-time {
  position: relative;
  min-height: 52px;
  padding: 8px 6px;
  font-size: 1rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.admin-move-time:not(:disabled):hover {
  border-color: var(--accent);
}

.admin-move-time[aria-pressed='true'] {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

.admin-move-time:disabled {
  cursor: not-allowed;
  color: var(--muted);
  background: transparent;
  opacity: 0.55;
}

.admin-move-taken,
.admin-move-past {
  text-decoration: line-through;
}

.admin-move-now {
  display: block;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.admin-move-summary {
  margin: 0 0 12px;
  font-weight: 600;
}

/* ---- shop settings (Menu > Settings > Shop settings) ---- */
.admin-settings {
  margin: 12px 0 24px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.admin-settings-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px 12px;
}

.admin-settings h2 {
  margin: 0;
  font-size: 1.4rem;
  font-weight: 800;
}

.admin-settings-group {
  margin: 20px 0 0;
  padding: 0;
  border: 0;
}

.admin-settings-group legend {
  margin-bottom: 8px;
  padding: 0;
  font-size: 1.1rem;
  font-weight: 800;
}

.admin-svc-list,
.admin-slot-list {
  margin: 0 0 12px;
  padding: 0;
  list-style: none;
}

.admin-svc {
  margin-bottom: 12px;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
}

.admin-svc .field input {
  min-height: 48px;
}

.admin-svc-price {
  display: grid;
  grid-template-columns: minmax(96px, 140px) 1fr;
  gap: 4px 14px;
  align-items: start;
}

.admin-svc-from {
  margin-top: 26px;
}

.admin-svc-actions {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(112px, 1fr));
  gap: 8px;
}

.admin-slot-row {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 4px 12px;
  align-items: center;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
}

.admin-slot-day label {
  display: block;
  font-weight: 700;
}

.admin-slot-input {
  display: flex;
  align-items: center;
  gap: 8px;
}

.admin-slot-input input {
  width: 92px;
  min-height: 48px;
  padding: 10px 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.admin-slot-input input:focus {
  border-color: var(--accent);
}

.admin-slot-input input[aria-invalid='true'] {
  border-color: var(--danger);
}

.admin-slot-row .err {
  grid-column: 1 / -1;
  min-height: 0;
}

.admin-svc-actions .admin-box-btn {
  width: 100%;
  max-width: none;
  min-width: 0;
  margin-top: 0;
}

.admin-remind-list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.admin-svc-actions .admin-box-btn {
  padding-inline: 8px;
  font-size: 0.95rem;
}

.admin-card-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 10px;
}

.admin-card .admin-code {
  flex: none;
  margin: 0;
  padding: 4px 10px;
  font-size: 0.82rem;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.admin-phone-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 12px;
}

.texts-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 10px;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.82rem;
  font-weight: 700;
  white-space: nowrap;
}

.texts-on {
  color: #5fd18a;
}

.texts-off {
  color: var(--muted);
}

.admin-card .admin-pay-row {
  margin: 4px 0 2px;
}

.pay-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 10px;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.82rem;
  font-weight: 700;
  white-space: nowrap;
}

.pay-paid {
  color: #5fd18a;
}

.pay-shop {
  color: var(--muted);
}

.pay-pending {
  color: #f0b44c;
}
VICBLESS_EOF
cat > "$STAGE/24" <<'VICBLESS_EOF'
// MOCK admin data layer. Replace with calls to the real backend later. Shapes to keep:
//   signIn(password)        ->  POST   /admin/login
//   getDay(dateKey)         ->  GET    /admin/schedule?date=YYYY-MM-DD   { items, blocks } for that day
//   cancelBooking(item)     ->  DELETE /admin/bookings/{id}              (frees the time)
//   addBlock(block)         ->  POST   /admin/blocks                     (409 if it overlaps a booking or block)
//   removeBlock(id)         ->  DELETE /admin/blocks/{id}
//   getAdminSettings()      ->  GET    /admin/settings
//   saveSettings(body)      ->  PUT    /admin/settings
//   moveBooking(item, {dateKey, start})  ->  PATCH /admin/bookings/{id}   body { dateKey, start }
//                                         (409 if the time is taken; the booking comes back with a NEW id)
//
// For now it shows real bookings made through the site in this browser, plus sample bookings for the
// blocks the public mock marks as taken, so the schedule and the customer-facing time grid always
// agree. Sample ones are marked so they are never mistaken for real customers.

import { HOURS } from '../config.js'
import { getBusy } from '../lib/mockApi.js'
import { fromKey, slotStarts } from '../lib/availability.js'
import { fromApi, toApi } from '../lib/shopSettings.js'
import {
  blockedStartsFor,
  overlaps,
  readBlocks,
  readBookings,
  readCancelledSamples,
  readShopSettings,
  slotMinutesOn,
  writeBlocks,
  writeBookings,
  writeCancelledSamples,
  writeShopSettings,
} from '../lib/mockStore.js'
import { findConflicts } from './blocks.js'

const SESSION_KEY = 'vicbless.admin.session'
const delay = (ms) => new Promise((r) => setTimeout(r, ms))

export function isSignedIn() {
  try {
    return localStorage.getItem(SESSION_KEY) === 'preview'
  } catch {
    return false
  }
}

export async function signIn(password) {
  await delay(300)
  if (!String(password ?? '').trim()) throw new Error('Please enter your password.')
  try {
    localStorage.setItem(SESSION_KEY, 'preview')
  } catch {
    /* storage blocked: the session just will not survive a reload */
  }
}

export function signOut() {
  try {
    localStorage.removeItem(SESSION_KEY)
  } catch {
    /* nothing to clear */
  }
}

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

const FIRST = ['Marcus', 'Dre', 'Tyrell', 'Jamal', 'Chris', 'Devon', 'Andre', 'Malik', 'Terrence', 'Jordan', 'Isaiah', 'Cameron']
const LAST = ['J.', 'W.', 'B.', 'H.', 'T.', 'R.', 'M.', 'G.']
const NOTES = ['Wants it shorter on the sides', 'Bringing his son next', 'Regular, same as last time', 'Beard line-up too if there is time']

function sampleItem(dateKey, start) {
  const h = hash(`${dateKey}|sample|${start}`)
  const services = readShopSettings().services
  const service = services[h % services.length]
  return {
    id: `sample-${dateKey}-${start}`,
    dateKey,
    source: 'sample',
    start,
    minutes: slotMinutesOn(dateKey),
    serviceId: service.id,
    serviceName: service.name,
    name: `${FIRST[h % FIRST.length]} ${LAST[(h >>> 4) % LAST.length]}`,
    phone: `(555) 010-${String(100 + (h % 90)).padStart(4, '0').slice(-4)}`,
    // about two in three sample customers left an email, so the layout can be seen with and without
    email: h % 3 === 0 ? '' : `${FIRST[h % FIRST.length].toLowerCase()}${h % 97}@example.com`,
    notes: h % 4 === 0 ? NOTES[(h >>> 8) % NOTES.length] : '',
    // about half of the sample customers agreed to texts
    smsConsent: (h >>> 3) % 2 === 0,
    // and about one in three paid online, so the badges can be seen both ways
    payment: h % 3 === 1 ? 'paid' : 'shop',
    amountCents: service.price * 100,
    code: 'VB-SAMPLE',
  }
}

export async function getDay(dateKey) {
  const busyByDay = await getBusy([dateKey])
  const busy = busyByDay[dateKey] || []
  const real = readBookings().filter((b) => b.dateKey === dateKey)

  const items = real.map((b) => ({
    id: b.code,
    dateKey,
    source: 'online',
    start: b.start,
    minutes: b.minutes,
    serviceId: b.serviceId,
    serviceName: b.serviceName || '',
    name: b.name,
    phone: b.phone,
    email: b.email || '',
    notes: b.notes || '',
    smsConsent: b.smsConsent === true,
    payment: b.payment || 'shop',
    amountCents: b.amountCents || 0,
    code: b.code,
  }))

  // real bookings and blocked time are never shown as sample bookings
  const slot = slotMinutesOn(dateKey)
  const covered = new Set(blockedStartsFor(dateKey))
  for (const start of busy) {
    if (real.some((b) => overlaps(start, start + slot, b.start, b.start + b.minutes))) covered.add(start)
  }
  for (const start of [...busy].sort((a, b) => a - b)) {
    if (!covered.has(start)) items.push(sampleItem(dateKey, start))
  }
  items.sort((a, b) => a.start - b.start)

  const blocks = readBlocks()
    .filter((b) => b.dateKey === dateKey)
    .sort((a, b) => a.start - b.start)

  return { dateKey, items, blocks }
}

// Frees the time. A real booking is removed; a sample one is remembered as cancelled.
export async function cancelBooking(item) {
  await delay(250)
  if (item.source === 'online') {
    writeBookings(readBookings().filter((b) => !(b.code === item.id && b.dateKey === item.dateKey && b.start === item.start)))
  } else {
    const list = readCancelledSamples()
    if (!list.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
      writeCancelledSamples([...list, { dateKey: item.dateKey, start: item.start }])
    }
  }
}

// The "backend" has the final say: it refuses a block that overlaps a booking or other blocked time,
// even if the screen did not catch it (for example when something changed a moment ago).
export async function addBlock({ dateKey, start, end, note = '', whole = false }) {
  await delay(250)
  const day = await getDay(dateKey)
  const slot = slotMinutesOn(dateKey)
  const grid = slotStarts(fromKey(dateKey), HOURS, slot)
  const conflicts = findConflicts({ range: { start, end }, grid, items: day.items, blocks: day.blocks, slotMinutes: slot })
  if (conflicts.bookings.length > 0 || conflicts.blocks.length > 0) {
    const error = new Error('That time overlaps a booking or blocked time.')
    error.code = 'CONFLICT'
    throw error
  }
  const block = {
    id: `blk-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    dateKey,
    start,
    end,
    note: String(note ?? '').trim().slice(0, 80),
    whole: !!whole,
  }
  writeBlocks([...readBlocks(), block])
  return block
}

export async function removeBlock(id) {
  await delay(150)
  writeBlocks(readBlocks().filter((b) => b.id !== id))
}

// Moves a booking to another day and time. The "backend" has the final say, like the real one will:
// it refuses a time that is not on the grid, or that is taken or blocked (except by this booking itself).
// A real booking keeps its code. A sample booking becomes a real one at the new time, and its old time is freed.
export async function moveBooking(item, { dateKey, start }) {
  await delay(300)
  // The booking takes the new day's appointment length, like the real backend.
  const slot = slotMinutesOn(dateKey)
  if (!slotStarts(fromKey(dateKey), HOURS, slot).includes(start)) {
    const error = new Error('That is not a time Vic works.')
    error.code = 'INVALID'
    throw error
  }

  const busy = new Set((await getBusy([dateKey]))[dateKey] || [])
  if (item.dateKey === dateKey) {
    // the appointment starts that only overlap this booking itself are not in its way
    for (const s of [...busy]) if (overlaps(s, s + slot, item.start, item.start + item.minutes)) busy.delete(s)
  }
  if (busy.has(start)) {
    const error = new Error('That time is taken.')
    error.code = 'CONFLICT'
    throw error
  }

  if (item.source === 'online') {
    writeBookings(
      readBookings().map((b) => (b.code === item.id && b.dateKey === item.dateKey && b.start === item.start ? { ...b, dateKey, start, minutes: slot } : b)),
    )
    return
  }

  // sample booking: free its old time, then make a real booking at the new one
  const cancelled = readCancelledSamples()
  if (!cancelled.some((c) => c.dateKey === item.dateKey && c.start === item.start)) {
    writeCancelledSamples([...cancelled, { dateKey: item.dateKey, start: item.start }])
  }
  const code = 'VB-' + Math.random().toString(36).slice(2, 7).toUpperCase()
  writeBookings([
    ...readBookings(),
    {
      staffId: 'vic',
      serviceId: item.serviceId,
      dateKey,
      start,
      minutes: slot,
      serviceName: item.serviceName || '',
      name: item.name,
      phone: item.phone,
      email: item.email,
      notes: item.notes,
      smsConsent: item.smsConsent === true,
      payment: item.payment || 'shop',
      amountCents: item.amountCents || 0,
      code,
    },
  ])
}

// The settings screen: read what is saved, and save a new version. Takes and gives the API's shape.
export async function getAdminSettings() {
  await delay(150)
  return toApi(readShopSettings())
}

export async function saveSettings(body) {
  await delay(300)
  const parsed = fromApi({
    // A new service has no id yet; the real backend makes one, so the mock does too.
    services: body.services.map((s) => ({ ...s, id: s.id || `svc-${Math.random().toString(16).slice(2, 8)}` })),
    slotMinutes: body.slotMinutes,
    reminderHours: body.reminderHours,
  })
  if (!parsed) throw new Error('Those settings are not valid.')
  const saved = toApi(parsed)
  writeShopSettings(saved)
  return saved
}
VICBLESS_EOF
cat > "$STAGE/25" <<'VICBLESS_EOF'
// Who is told when Vic cancels a booking: a text if the customer ticked the box, an email if they left one.
// This mirrors the backend, which texts only customers who agreed and emails only those who left an address.

export function whoIsTold(item) {
  return { text: item.smsConsent === true, email: Boolean(item.email && item.email.trim()) }
}

// '$65' or '$65.50' from cents; '' when there is no amount (a booking made before prices were kept).
export function money(cents) {
  if (!Number.isInteger(cents) || cents <= 0) return ''
  const dollars = Math.floor(cents / 100)
  const rest = cents % 100
  return rest ? `$${dollars}.${String(rest).padStart(2, '0')}` : `$${dollars}`
}

export function cancelMessage(item, timeLabel, serviceName) {
  const { text, email } = whoIsTold(item)
  const head = `Cancel ${item.name}'s ${timeLabel} ${serviceName}? The time opens up for other customers.`
  let told
  if (text && email) told = 'They are sent a text and an email saying it was cancelled.'
  else if (text) told = 'They are sent a text saying it was cancelled.'
  else if (email) told = 'They are sent an email saying it was cancelled.'
  else told = "They won't be told, because they didn't agree to texts or leave an email."
  let money_ = ''
  if (item.payment === 'paid') {
    const amount = money(item.amountCents)
    money_ = ` They paid${amount ? ` ${amount}` : ''} online, and it is refunded to their card automatically.`
  } else if (item.payment === 'pending') {
    money_ = ' They had not paid yet, so their payment page is closed.'
  }
  return `${head} ${told}${money_}`
}

// How the customer is paying, for the badge on the card: paid online, still to pay online, or paying at the shop.
export function paymentLabel(item) {
  const amount = money(item.amountCents)
  const tail = amount ? ` · ${amount}` : ''
  if (item.payment === 'paid') return { state: 'paid', mark: '✓', words: `Paid online${tail}` }
  if (item.payment === 'pending') return { state: 'pending', mark: '…', words: `Waiting for payment${tail}` }
  return { state: 'shop', mark: '$', words: `Pay at the shop${tail}` }
}

// The short label beside the phone number. The mark and the words both say it, so colour is never the only clue.
export function textsLabel(item) {
  return item.smsConsent === true ? { mark: '✓', words: 'Text Reminders', on: true } : { mark: '✗', words: 'No Text Reminders', on: false }
}
VICBLESS_EOF
cat > "$STAGE/26" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { cancelMessage, money, paymentLabel, textsLabel, whoIsTold } from './notify'

const base = { name: 'Rayner Codes', smsConsent: false, email: '' }
const msg = (o) => cancelMessage({ ...base, ...o }, '3:05 pm', "Men's haircut with design")

describe('cancel message', () => {
  it('says text and email when both apply', () => {
    expect(msg({ smsConsent: true, email: 'a@b.co' })).toContain('a text and an email')
  })
  it('says text only when they only agreed to texts', () => {
    const m = msg({ smsConsent: true })
    expect(m).toContain('a text saying')
    expect(m).not.toContain('email')
  })
  it('says email only when they only left an email', () => {
    const m = msg({ email: 'a@b.co' })
    expect(m).toContain('an email saying')
    expect(m).not.toContain('a text')
  })
  it('says nobody is told when neither applies', () => {
    expect(msg({})).toContain("won't be told")
    expect(msg({ email: '   ' })).toContain("won't be told")
  })
  it('always names the booking and frees the time', () => {
    expect(msg({})).toMatch(/^Cancel Rayner Codes's 3:05 pm Men's haircut with design\? The time opens up/)
  })
  it('only a true consent counts', () => {
    expect(whoIsTold({ smsConsent: 'yes', email: '' }).text).toBe(false)
    expect(whoIsTold({ email: 'x@y.co' }).email).toBe(true)
  })
})

describe('texts label', () => {
  it('has a mark and words either way', () => {
    expect(textsLabel({ smsConsent: true })).toEqual({ mark: '✓', words: 'Text Reminders', on: true })
    expect(textsLabel({})).toEqual({ mark: '✗', words: 'No Text Reminders', on: false })
  })
})

describe('money', () => {
  it('writes dollars, with cents only when there are some', () => {
    expect(money(5500)).toBe('$55')
    expect(money(6550)).toBe('$65.50')
    expect(money(5)).toBe('$0.05')
  })
  it('says nothing for no amount', () => {
    for (const v of [0, -1, undefined, null, 12.5, '5500']) expect(money(v)).toBe('')
  })
})

describe('payment', () => {
  it('labels how the customer pays', () => {
    expect(paymentLabel({ payment: 'paid', amountCents: 5500 })).toEqual({ state: 'paid', mark: '✓', words: 'Paid online · $55' })
    expect(paymentLabel({ payment: 'shop', amountCents: 6500 })).toEqual({ state: 'shop', mark: '$', words: 'Pay at the shop · $65' })
    expect(paymentLabel({ payment: 'pending', amountCents: 5500 })).toMatchObject({ state: 'pending', words: 'Waiting for payment · $55' })
  })
  it('treats a booking from before payments existed as paying at the shop, with no amount', () => {
    expect(paymentLabel({})).toEqual({ state: 'shop', mark: '$', words: 'Pay at the shop' })
  })
  it('warns that a paid booking is refunded when cancelled', () => {
    const m = msg({ payment: 'paid', amountCents: 5500, smsConsent: true })
    expect(m).toContain('They paid $55 online, and it is refunded to their card automatically.')
    expect(m).toContain('a text saying')
  })
  it('says the payment page is closed when it was still waiting for payment', () => {
    expect(msg({ payment: 'pending', amountCents: 5500 })).toContain('payment page is closed')
  })
  it('says nothing about money for a booking paid at the shop', () => {
    expect(msg({ payment: 'shop', amountCents: 5500 })).not.toMatch(/paid|refund|payment/)
  })
})
VICBLESS_EOF
cat > "$STAGE/27" <<'VICBLESS_EOF'
// Errors shared by the mock and the real data layer, so the pages can catch one kind of error
// whichever layer is behind them.

// The time a customer picked is no longer free (somebody got there first, or it has passed).
// Book.jsx catches this one: it sends the customer back to the time grid with fresh availability.
export class SlotTakenError extends Error {
  constructor(message = 'That time was just taken.') {
    super(message)
    this.name = 'SlotTakenError'
  }
}

// Backend error codes whose message was written to be read by a person, so the pages show it as it is.
// (Anything else, like a 500, gets the pages' own generic wording instead of a technical message.)
const FRIENDLY = new Set(['validation_error', 'invalid_slot', 'too_many_bookings', 'too_many_attempts', 'unauthorized', 'payment_unavailable', 'refund_failed'])

// Anything the real API (or the network on the way to it) answers with an error.
//   status   HTTP status, or 0 when the server could not be reached at all
//   apiCode  the backend's word for it: 'slot_taken', 'conflict', 'validation_error', 'network', ...
//   code     same as apiCode, except the admin screens use the older 'CONFLICT' / 'INVALID' words
//            (see realAdminApi.js), so that is the one they branch on
//   field    which input the message is about, when the backend says (validation errors)
//   friendly true when `message` is safe and useful to show as it is
export class ApiError extends Error {
  constructor({ status, code, message, field }) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.apiCode = code
    this.code = code
    this.field = field || ''
    this.friendly = FRIENDLY.has(code)
  }
}
VICBLESS_EOF
cat > "$STAGE/28" <<'VICBLESS_EOF'
// MOCK customer data layer, used by npm run dev and the tests (see api.js and mode.js). The real one is realApi.js.
//
//   getAvailability(dateKeys) -> GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD
//        { '2026-10-09': { busy: [660, 695], dayOff: false }, ... }  taken times, and whether the day is off
//   getShopSettings()   -> GET /settings   { services, slotMinutes: { mon: 45, ... } }
//   createBooking(data) ->  POST /bookings   (return 409 when the slot is taken)
//
// Keep the same return shapes and the pages will not need to change.
// Until then it fakes busy times per day and keeps bookings, blocked time and cancelled
// sample bookings in localStorage (through mockStore.js), so a booked, blocked or freed time
// shows up on the customer grid and in Vic's dashboard alike.

import { HOURS } from '../config.js'
import { SlotTakenError } from './errors.js'
import { DAY_KEYS } from './shopSettings.js'
import { fromKey, slotStarts } from './availability.js'
import {
  blockedStartsFor,
  isDayOff,
  overlaps,
  readBookings,
  readCancelledSamples,
  readShopSettings,
  slotMinutesOn,
  writeBookings,
} from './mockStore.js'

const delay = (ms) => new Promise((r) => setTimeout(r, ms))

// SlotTakenError lives in errors.js, shared with the real data layer.

function hash(str) {
  let h = 2166136261
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

function busyFor(dateKey) {
  const busy = new Set()
  const slot = slotMinutesOn(dateKey) // how long an appointment is on this day right now

  // pretend-busy blocks, unless Vic cancelled them in the dashboard
  const cancelled = new Set(readCancelledSamples().filter((c) => c.dateKey === dateKey).map((c) => c.start))
  for (const s of slotStarts(fromKey(dateKey), HOURS, slot)) {
    if (hash(dateKey + s) % 100 < 30 && !cancelled.has(s)) busy.add(s)
  }

  // real bookings made through the site: every appointment start they overlap is taken, whatever length they had
  const bookings = readBookings().filter((b) => b.dateKey === dateKey)
  for (const s of slotStarts(fromKey(dateKey), HOURS, slot)) {
    if (bookings.some((b) => overlaps(s, s + slot, b.start, b.start + b.minutes))) busy.add(s)
  }

  // time Vic blocked off
  for (const s of blockedStartsFor(dateKey)) busy.add(s)

  return [...busy]
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off (shown to customers as "Closed" instead of "Full").
export async function getAvailability(dateKeys) {
  await delay(150)
  return Object.fromEntries(dateKeys.map((k) => [k, { busy: busyFor(k), dayOff: isDayOff(k), slotMinutes: slotMinutesOn(k) }]))
}

// Just the taken times, for code that does not care about days off (the admin mock).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

// The services and appointment lengths, in the API's shape. In the mock they are kept in this browser.
export async function getShopSettings() {
  await delay(100)
  const settings = readShopSettings()
  return {
    services: settings.services.map((s) => ({ id: s.id, name: s.name, price: s.price, from: s.from, note: s.note })),
    slotMinutes: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.slotMinutes[day]])),
    reminderHours: settings.reminderHours,
    payOnline: true, // the preview shows the card option; "paying" in it simply marks the booking paid
  }
}

export async function createBooking(payload) {
  await delay(500)
  const slot = slotMinutesOn(payload.dateKey)
  if (busyFor(payload.dateKey).includes(payload.start) || !slotStarts(fromKey(payload.dateKey), HOURS, slot).includes(payload.start)) {
    throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  // The service's name is kept with the booking, like the real backend does, so a later rename does not change it.
  const service = readShopSettings().services.find((s) => s.id === payload.serviceId)
  // Paying online is pretended here: the booking is simply marked paid. The real API sends the customer to Stripe.
  const payment = payload.payment === 'online' ? 'paid' : 'shop'
  const amountCents = service ? service.price * 100 : 0
  const booking = { ...payload, minutes: slot, serviceName: service ? service.name : '', code, payment, amountCents }
  writeBookings([...readBookings(), booking])
  return booking
}
VICBLESS_EOF
cat > "$STAGE/29" <<'VICBLESS_EOF'
// Paying online sends the customer to Stripe and back. This remembers what they were booking while they are away, and
// reads the address Stripe sends them back to:
//   #/book?paid=VB-XXXXXX      they paid: show the "You're booked" screen
//   #/book?payment=cancelled   they came back without paying: put their details back so they can try again
// The memory is the browser tab's own (sessionStorage), and only what the customer typed plus the booking's answer.

export const PENDING_KEY = 'vicbless.pendingPayment'

const CODE = /^VB-[A-Z0-9]{4,12}$/

// What the address says about a trip to Stripe: { kind: 'paid', code } | { kind: 'cancelled' } | null.
export function readReturn(hash) {
  const query = String(hash || '').split('?')[1] || ''
  const params = new URLSearchParams(query)
  const paid = params.get('paid')
  if (paid && CODE.test(paid)) return { kind: 'paid', code: paid }
  if (params.get('payment') === 'cancelled') return { kind: 'cancelled' }
  return null
}

// { request: { serviceId, dateKey, time, form }, booking } is what the booking page saves before leaving for Stripe.
export function savePending(storage, pending) {
  try {
    storage?.setItem(PENDING_KEY, JSON.stringify(pending))
  } catch {
    /* storage blocked: the customer just starts the form again */
  }
}

export function loadPending(storage) {
  try {
    const saved = JSON.parse(storage?.getItem(PENDING_KEY) || 'null')
    if (saved && saved.request && saved.booking && typeof saved.booking.code === 'string') return saved
  } catch {
    /* unreadable: treated as nothing saved */
  }
  return null
}

export function clearPending(storage) {
  try {
    storage?.removeItem(PENDING_KEY)
  } catch {
    /* nothing to clear */
  }
}

// The browser tab's storage, or null when it is blocked.
export function tabStorage() {
  try {
    return window.sessionStorage
  } catch {
    return null
  }
}
VICBLESS_EOF
cat > "$STAGE/30" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { clearPending, loadPending, PENDING_KEY, readReturn, savePending } from './paymentReturn'

const fakeStorage = (initial = {}) => {
  const data = { ...initial }
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => {
      data[k] = v
    },
    removeItem: (k) => {
      delete data[k]
    },
  }
}

describe('reading the address Stripe sends people back to', () => {
  it('knows a paid booking', () => {
    expect(readReturn('#/book?paid=VB-K7M2QX')).toEqual({ kind: 'paid', code: 'VB-K7M2QX' })
  })
  it('knows a cancelled payment', () => {
    expect(readReturn('#/book?payment=cancelled')).toEqual({ kind: 'cancelled' })
  })
  it('ignores everything else', () => {
    for (const hash of ['', '#/book', '#/book?service=mens-cut', '#/book?paid=nonsense', '#/book?paid=<script>', undefined]) {
      expect(readReturn(hash)).toBe(null)
    }
  })
})

describe('remembering a booking while the customer is at Stripe', () => {
  const pending = { request: { serviceId: 'mens-cut', dateKey: '2026-10-21', time: 720, form: { name: 'A' } }, booking: { code: 'VB-AAAAAA' } }

  it('saves and loads it', () => {
    const s = fakeStorage()
    savePending(s, pending)
    expect(loadPending(s)).toEqual(pending)
  })
  it('forgets it', () => {
    const s = fakeStorage()
    savePending(s, pending)
    clearPending(s)
    expect(loadPending(s)).toBe(null)
  })
  it('treats damaged or half-saved data as nothing', () => {
    expect(loadPending(fakeStorage({ [PENDING_KEY]: '{oops' }))).toBe(null)
    expect(loadPending(fakeStorage({ [PENDING_KEY]: JSON.stringify({ request: {} }) }))).toBe(null)
  })
  it('does not break when storage is blocked or missing', () => {
    expect(() => savePending(null, pending)).not.toThrow()
    expect(loadPending(null)).toBe(null)
    const blocked = { getItem: () => { throw new Error('no') }, setItem: () => { throw new Error('no') }, removeItem: () => { throw new Error('no') } }
    expect(() => savePending(blocked, pending)).not.toThrow()
    expect(loadPending(blocked)).toBe(null)
    expect(() => clearPending(blocked)).not.toThrow()
  })
})
VICBLESS_EOF
cat > "$STAGE/31" <<'VICBLESS_EOF'
// The real customer-facing data layer: the same functions as mockApi.js, backed by the API.
//
//   getAvailability(dateKeys) -> GET  /api/availability?from=&to=
//   getShopSettings()         -> GET  /api/settings
//   createBooking(data)       -> POST /api/bookings
//
// Return shapes match the mock exactly, so the pages do not know which one they are talking to.

import { fromKey, keyOf } from './availability.js'
import { ApiError, SlotTakenError } from './errors.js'
import { request } from './http.js'

// The API answers for at most this many days per call (shop.MAX_RANGE_DAYS in the backend).
const MAX_DAYS_PER_CALL = 31

function addDays(dateKey, n) {
  const d = fromKey(dateKey)
  d.setDate(d.getDate() + n)
  return keyOf(d)
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off. One call covers the whole range; a longer range is split so the API never refuses it.
export async function getAvailability(dateKeys) {
  const keys = [...dateKeys].sort()
  const result = {}
  if (keys.length === 0) return result

  let from = keys[0]
  const last = keys[keys.length - 1]
  const calls = []
  while (from <= last) {
    const to = addDays(from, MAX_DAYS_PER_CALL - 1) < last ? addDays(from, MAX_DAYS_PER_CALL - 1) : last
    calls.push(request('GET', `/availability?from=${from}&to=${to}`))
    from = addDays(to, 1)
  }
  for (const part of await Promise.all(calls)) Object.assign(result, part)

  // A day the API says nothing about is treated as completely free, never as an error.
  return Object.fromEntries(keys.map((k) => [k, result[k] || { busy: [], dayOff: false }]))
}

// The services, prices and appointment lengths Vic has set (customers read them to draw the pages).
export const getShopSettings = () => request('GET', '/settings')

// Just the taken times (the admin mock uses this one; kept so both layers have the same exports).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

// Books the time. Resolves to the booking, which has everything the "You're booked" screen shows.
// The API's answer has no name (it only returns what a stranger could safely be told), so what the
// customer typed is merged back in. The API's code/date/time win, they are what was actually saved.
export async function createBooking(payload) {
  try {
    const saved = await request('POST', '/bookings', {
      body: {
        staffId: payload.staffId,
        serviceId: payload.serviceId,
        dateKey: payload.dateKey,
        start: payload.start,
        name: payload.name,
        phone: payload.phone,
        email: payload.email,
        notes: payload.notes,
        smsConsent: payload.smsConsent === true, // only a ticked box counts as a yes
        payment: payload.payment === 'online' ? 'online' : 'shop',
        // where Stripe sends the customer back to (the API only accepts the site's own address)
        ...(payload.payment === 'online' && payload.returnTo ? { returnTo: payload.returnTo } : {}),
        // `minutes` is deliberately not sent: the API looks the length up from the service.
      },
    })
    return { ...payload, ...saved }
  } catch (err) {
    // Both mean "pick another time": taken by somebody else, or no longer bookable (already past, too soon).
    if (err instanceof ApiError && (err.apiCode === 'slot_taken' || err.apiCode === 'slot_unavailable')) {
      throw new SlotTakenError(err.message)
    }
    throw err
  }
}
VICBLESS_EOF
cat > "$STAGE/32" <<'VICBLESS_EOF'
// The real data layer against a pretend fetch: what it sends, how it reads answers, how it reports failures.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, SlotTakenError } from './errors.js'
import { createBooking, getAvailability } from './realApi.js'

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const errorBody = (code, message, field) => ({ error: { code, message, ...(field ? { field } : {}) } })

let calls
beforeEach(() => {
  calls = []
})
afterEach(() => vi.unstubAllGlobals())
const stub = (...answers) => {
  const queue = [...answers]
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    calls.push({ url, init })
    const next = queue.length > 1 ? queue.shift() : queue[0]
    if (typeof next === 'function') return next(url, init)
    return next.clone() // a Response body can be read once; every call gets its own copy
  }))
}

const payload = {
  staffId: 'vic', serviceId: 'haircut', dateKey: '2026-10-13', start: 660, minutes: 35,
  name: 'Marcus Jones', phone: '(555) 010-1234', email: '', notes: '',
}

describe('getAvailability', () => {
  it('asks for the whole range in one call and fills in days the API did not mention', async () => {
    stub(json(200, { '2026-10-13': { busy: [660], dayOff: false } }))
    const out = await getAvailability(['2026-10-14', '2026-10-13', '2026-10-15'])
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe('/api/availability?from=2026-10-13&to=2026-10-15')
    expect(out['2026-10-13']).toEqual({ busy: [660], dayOff: false })
    expect(out['2026-10-14']).toEqual({ busy: [], dayOff: false })
    expect(Object.keys(out).sort()).toEqual(['2026-10-13', '2026-10-14', '2026-10-15'])
  })

  it('splits a range longer than the API allows (31 days)', async () => {
    stub(json(200, {}))
    await getAvailability(['2026-11-01', '2026-12-10'])
    expect(calls.length).toBe(2)
    expect(calls[0].url).toBe('/api/availability?from=2026-11-01&to=2026-12-01')
    expect(calls[1].url).toBe('/api/availability?from=2026-12-02&to=2026-12-10')
  })

  it('returns an empty answer without calling the API when no days are asked for', async () => {
    stub(json(200, {}))
    expect(await getAvailability([])).toEqual({})
    expect(calls).toHaveLength(0)
  })

  it('fails with an ApiError that has a readable message when the server cannot be reached', async () => {
    stub(() => { throw new TypeError('Failed to fetch') })
    await expect(getAvailability(['2026-10-13'])).rejects.toMatchObject({ name: 'ApiError', apiCode: 'network', status: 0 })
  })
})

describe('createBooking', () => {
  it('sends the booking without `minutes`, and merges what the customer typed into the reply', async () => {
    stub(json(201, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    const booking = await createBooking(payload)
    expect(calls[0].url).toBe('/api/bookings')
    expect(calls[0].init.method).toBe('POST')
    const sent = JSON.parse(calls[0].init.body)
    expect(sent).not.toHaveProperty('minutes')
    expect(sent).toMatchObject({ serviceId: 'haircut', dateKey: '2026-10-13', start: 660, name: 'Marcus Jones' })
    expect(booking).toMatchObject({ code: 'ABC23', name: 'Marcus Jones', serviceId: 'haircut', start: 660 })
  })

  it('sends the text consent only when the box was ticked', async () => {
    stub(json(201, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    await createBooking(payload)
    expect(JSON.parse(calls[0].init.body).smsConsent).toBe(false) // nothing said means no
    await createBooking({ ...payload, smsConsent: 'yes' })
    expect(JSON.parse(calls[1].init.body).smsConsent).toBe(false) // only a real true counts
    await createBooking({ ...payload, smsConsent: true })
    expect(JSON.parse(calls[2].init.body).smsConsent).toBe(true)
  })

  it('pays at the shop unless online was asked for, and only then sends where to come back to', async () => {
    stub(json(201, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    await createBooking({ ...payload, returnTo: 'https://vicbless.com' })
    expect(JSON.parse(calls[0].init.body)).toMatchObject({ payment: 'shop' })
    expect(JSON.parse(calls[0].init.body)).not.toHaveProperty('returnTo')
    await createBooking({ ...payload, payment: 'whatever' })
    expect(JSON.parse(calls[1].init.body).payment).toBe('shop')
    await createBooking({ ...payload, payment: 'online', returnTo: 'https://vicbless.com' })
    expect(JSON.parse(calls[2].init.body)).toMatchObject({ payment: 'online', returnTo: 'https://vicbless.com' })
  })

  it('hands back the payment page address when the API sends one', async () => {
    stub(json(201, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic', payment: 'pending', checkoutUrl: 'https://checkout.stripe.test/c/1' }))
    const booking = await createBooking({ ...payload, payment: 'online' })
    expect(booking).toMatchObject({ payment: 'pending', checkoutUrl: 'https://checkout.stripe.test/c/1' })
  })

  it('treats a repeat of the same booking (200) as success', async () => {
    stub(json(200, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    expect((await createBooking(payload)).code).toBe('ABC23')
  })

  it.each(['slot_taken', 'slot_unavailable'])('turns %s into SlotTakenError', async (code) => {
    stub(json(409, errorBody(code, 'Sorry, that time was just taken. Please pick another.')))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(SlotTakenError)
    expect(err.message).toMatch(/pick another/)
  })

  it.each([
    [422, 'validation_error', true],
    [422, 'invalid_slot', true],
    [429, 'too_many_bookings', true],
    [500, 'server_error', false],
  ])('keeps %i %s as an ApiError (friendly=%s)', async (status, code, friendly) => {
    stub(json(status, errorBody(code, 'Words for a person.', code === 'validation_error' ? 'phone' : undefined)))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect(err.apiCode).toBe(code)
    expect(err.friendly).toBe(friendly)
    if (code === 'validation_error') expect(err.field).toBe('phone')
  })

  it('does not show technical text when something other than the API answers (a CloudFront error page)', async () => {
    stub(new Response('<html>Bad gateway</html>', { status: 502 }))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect(err.status).toBe(502)
    expect(err.message).not.toMatch(/html|gateway/i)
    expect(err.friendly).toBe(false)
  })
})
VICBLESS_EOF
cat > "$STAGE/33" <<'VICBLESS_EOF'
// Vic's shop settings: the services with their prices, and how long an appointment is on each weekday.
//
// The real values live in the database (Vic edits them in his dashboard). This file holds the pure helpers that
// turn what the API sends into what the screens use, check what Vic typed, and a tiny shared store so every page
// sees the same settings. Nothing here talks to the network except loadShopSettings().
//
// Shape used by the screens ("settings"):
//   { services: [{ id, name, price, from, note }], slotMinutes: { 0: 35, 1: 45, ... 6: 35 }, reminderHours: [24, 2] }
//   (0 = Sunday; reminderHours = how many hours before an appointment a reminder goes out, biggest first)
// The API uses weekday names instead of numbers ({ mon: 45 }); fromApi / toApi convert.

import {
  MAX_SERVICES,
  REMINDER_CHOICES,
  REMINDER_HOURS_DEFAULT,
  SERVICES,
  SLOT_MAX,
  SLOT_MIN,
  SLOT_MINUTES_BY_DAY,
  SLOT_STEP,
} from '../config.js'

// Index = JavaScript's Date.getDay() (0 is Sunday). The API uses these same short names.
export const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']
export const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

// Limits Vic's typing is checked against. The API enforces the same ones (a backend test compares them).
export const NAME_MIN = 2
export const NAME_MAX = 60
export const NOTE_MAX = 120
export const PRICE_MAX = 999

// The shop's starting values: used until the API answers, and if it never does.
export const DEFAULT_SHOP_SETTINGS = Object.freeze({
  services: SERVICES.map((s) => ({ id: s.id, name: s.name, price: s.price, from: !!s.from, note: s.note || '' })),
  slotMinutes: { ...SLOT_MINUTES_BY_DAY },
  reminderHours: [...REMINDER_HOURS_DEFAULT],
})

// Reminder times, biggest first, only ones Vic is allowed to pick, each once.
const cleanHours = (list) => [...new Set(list)].filter((h) => REMINDER_CHOICES.includes(h)).sort((a, b) => b - a)

const isLength = (n) => Number.isInteger(n) && n >= SLOT_MIN && n <= SLOT_MAX && n % SLOT_STEP === 0

// What the API sent -> what the screens use. Anything malformed gives null (the caller keeps what it had).
export function fromApi(raw) {
  if (!raw || !Array.isArray(raw.services) || !raw.slotMinutes || typeof raw.slotMinutes !== 'object') return null
  const services = []
  for (const s of raw.services) {
    if (!s || typeof s.id !== 'string' || typeof s.name !== 'string' || !Number.isInteger(s.price)) return null
    services.push({ id: s.id, name: s.name, price: s.price, from: !!s.from, note: typeof s.note === 'string' ? s.note : '' })
  }
  if (services.length === 0) return null
  const slotMinutes = {}
  for (let day = 0; day < 7; day++) {
    const minutes = raw.slotMinutes[DAY_KEYS[day]]
    if (!isLength(minutes)) return null
    slotMinutes[day] = minutes
  }
  // An answer from before reminders existed has no list: keep the starting one.
  let reminderHours = [...REMINDER_HOURS_DEFAULT]
  if (raw.reminderHours !== undefined) {
    if (!Array.isArray(raw.reminderHours) || !raw.reminderHours.every((h) => REMINDER_CHOICES.includes(h))) return null
    reminderHours = cleanHours(raw.reminderHours)
  }
  // Whether customers can pay by card. Only the customer-facing answer says so (Vic's own settings do not).
  const online = raw.payOnline === undefined ? {} : { payOnline: raw.payOnline === true }
  return { services, slotMinutes, reminderHours, ...online }
}

// What the screens hold -> what the API wants. A service without an id (a new one) is sent without it.
export function toApi(settings) {
  return {
    services: settings.services.map((s) => ({
      ...(s.id ? { id: s.id } : {}),
      name: s.name,
      price: s.price,
      from: !!s.from,
      note: s.note || '',
    })),
    slotMinutes: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.slotMinutes[day]])),
    reminderHours: cleanHours(settings.reminderHours),
  }
}

// How long an appointment is on `date` (a Date).
export const slotFor = (settings, date) => settings.slotMinutes[date.getDay()]

export const findService = (settings, id) => settings.services.find((s) => s.id === id) || null

// ---- the editor's draft: what Vic is typing, before it is saved ------------------------------------------------

let draftCounter = 0

// A draft keeps prices and lengths as TEXT (that is what an input holds) and gives every service row a key that
// never changes, so the row stays put while its name is edited. New rows have no id until they are saved.
export function draftFrom(settings) {
  return {
    services: settings.services.map((s) => ({
      key: s.id,
      id: s.id,
      name: s.name,
      price: String(s.price),
      from: !!s.from,
      note: s.note || '',
    })),
    slots: Object.fromEntries(Object.entries(settings.slotMinutes).map(([day, minutes]) => [day, String(minutes)])),
    reminders: cleanHours(settings.reminderHours),
  }
}

export function newDraftService() {
  draftCounter += 1
  return { key: `new-${draftCounter}`, id: '', name: '', price: '', from: false, note: '' }
}

// Switches one reminder time on or off in a draft, keeping the list biggest first.
export const toggleReminder = (draft, hours) => ({
  ...draft,
  reminders: cleanHours(draft.reminders.includes(hours) ? draft.reminders.filter((h) => h !== hours) : [...draft.reminders, hours]),
})

// Checks the draft the way the API will. Returns { ok: true, settings } or { ok: false, errors } where errors is
//   { general, services: { [key]: { name?, price?, note? } }, slots: { [day]: message } }
export function checkDraft(draft) {
  const errors = { general: '', services: {}, slots: {} }
  const services = []

  if (draft.services.length < 1 || draft.services.length > MAX_SERVICES) {
    errors.general = `List between 1 and ${MAX_SERVICES} services.`
  }

  const seen = new Set()
  for (const row of draft.services) {
    const problems = {}
    const name = row.name.trim().replace(/\s+/g, ' ')
    if (name.length < NAME_MIN || name.length > NAME_MAX) {
      problems.name = `Needs a name, ${NAME_MIN} to ${NAME_MAX} characters.`
    } else if (seen.has(name.toLowerCase())) {
      problems.name = 'Another service already has this name.'
    }
    seen.add(name.toLowerCase())

    const priceText = row.price.trim()
    const price = /^\d{1,3}$/.test(priceText) ? Number(priceText) : NaN
    if (!(price >= 0 && price <= PRICE_MAX)) problems.price = `Whole dollars, 0 to ${PRICE_MAX}.`

    if (row.note.length > NOTE_MAX) problems.note = `Up to ${NOTE_MAX} characters.`

    if (Object.keys(problems).length) errors.services[row.key] = problems
    services.push({ id: row.id, name, price, from: row.from, note: row.note.trim() })
  }

  const slotMinutes = {}
  for (let day = 0; day < 7; day++) {
    const text = String(draft.slots[day] ?? '').trim()
    const minutes = /^\d{1,3}$/.test(text) ? Number(text) : NaN
    if (!isLength(minutes)) errors.slots[day] = `${SLOT_MIN} to ${SLOT_MAX} minutes, in steps of ${SLOT_STEP}.`
    slotMinutes[day] = minutes
  }

  const bad = errors.general || Object.keys(errors.services).length || Object.keys(errors.slots).length
  return bad ? { ok: false, errors } : { ok: true, settings: { services, slotMinutes, reminderHours: cleanHours(draft.reminders) } }
}

// True when the draft differs from the saved settings (enables the Save button).
export function isChanged(draft, saved) {
  return JSON.stringify(draft) !== JSON.stringify(draftFrom(saved))
}

// ---- a tiny shared store so every page sees the same settings -------------------------------------------------

let current = DEFAULT_SHOP_SETTINGS
let loading = null
const listeners = new Set()

export const getShopSettingsNow = () => current
export const subscribeShopSettings = (fn) => {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

// Puts new settings into the store (after loading them, or after Vic saved) and tells every screen.
export function setShopSettings(settings) {
  // Vic's saved settings come back without the card-payment flag, so the one already known is kept
  current = settings.payOnline === undefined ? { ...settings, payOnline: current.payOnline === true } : settings
  for (const fn of listeners) fn()
}

// Asks the API once. `fetcher` returns the API's JSON. A failure keeps the starting values, never an error screen.
export function loadShopSettings(fetcher) {
  if (!loading) {
    loading = Promise.resolve()
      .then(fetcher)
      .then((raw) => {
        const parsed = fromApi(raw)
        if (parsed) setShopSettings(parsed)
      })
      .catch(() => {})
  }
  return loading
}

// For tests: back to the starting values.
export function resetShopSettings() {
  current = DEFAULT_SHOP_SETTINGS
  loading = null
  listeners.clear()
}
VICBLESS_EOF
cat > "$STAGE/34" <<'VICBLESS_EOF'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  DAY_KEYS,
  DEFAULT_SHOP_SETTINGS,
  checkDraft,
  draftFrom,
  findService,
  fromApi,
  getShopSettingsNow,
  isChanged,
  loadShopSettings,
  newDraftService,
  resetShopSettings,
  setShopSettings,
  slotFor,
  subscribeShopSettings,
  toggleReminder,
  toApi,
} from './shopSettings.js'

const apiBody = () => toApi(DEFAULT_SHOP_SETTINGS)

describe('defaults', () => {
  it('start with Monday and Tuesday at 45 minutes and the rest at 35', () => {
    expect(DEFAULT_SHOP_SETTINGS.slotMinutes).toEqual({ 0: 35, 1: 45, 2: 45, 3: 35, 4: 35, 5: 35, 6: 35 })
    expect(DEFAULT_SHOP_SETTINGS.services).toHaveLength(5)
  })

  it('slotFor reads the length for the weekday of a date', () => {
    expect(slotFor(DEFAULT_SHOP_SETTINGS, new Date(2026, 9, 13))).toBe(45) // Tuesday
    expect(slotFor(DEFAULT_SHOP_SETTINGS, new Date(2026, 9, 15))).toBe(35) // Thursday
  })

  it('finds a service by id', () => {
    expect(findService(DEFAULT_SHOP_SETTINGS, 'mens-cut').price).toBe(55)
    expect(findService(DEFAULT_SHOP_SETTINGS, 'nope')).toBeNull()
  })
})

describe('reminders', () => {
  it('start at 24 and 2 hours before', () => {
    expect(DEFAULT_SHOP_SETTINGS.reminderHours).toEqual([24, 2])
    expect(apiBody().reminderHours).toEqual([24, 2])
  })

  it('an answer from before reminders existed keeps the starting ones', () => {
    const body = apiBody()
    delete body.reminderHours
    expect(fromApi(body).reminderHours).toEqual([24, 2])
  })

  it('sorts biggest first, and refuses times that are not on the list', () => {
    expect(fromApi({ ...apiBody(), reminderHours: [2, 12, 4] }).reminderHours).toEqual([12, 4, 2])
    expect(fromApi({ ...apiBody(), reminderHours: [] }).reminderHours).toEqual([])
    expect(fromApi({ ...apiBody(), reminderHours: [5] })).toBeNull()
    expect(fromApi({ ...apiBody(), reminderHours: 'soon' })).toBeNull()
  })

  it('can be switched on and off in a draft', () => {
    let d = draftFrom(DEFAULT_SHOP_SETTINGS)
    d = toggleReminder(d, 6)
    expect(d.reminders).toEqual([24, 6, 2])
    d = toggleReminder(toggleReminder(d, 24), 2)
    expect(d.reminders).toEqual([6])
    expect(checkDraft(d).settings.reminderHours).toEqual([6])
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(true)
    expect(checkDraft(toggleReminder(d, 6)).settings.reminderHours).toEqual([]) // none at all is allowed
  })
})

describe('API shape', () => {
  it('round-trips', () => {
    expect(fromApi(apiBody())).toEqual(DEFAULT_SHOP_SETTINGS)
    expect(apiBody().slotMinutes).toEqual({ sun: 35, mon: 45, tue: 45, wed: 35, thu: 35, fri: 35, sat: 35 })
  })

  it('refuses anything malformed', () => {
    expect(fromApi(null)).toBeNull()
    expect(fromApi({ services: [], slotMinutes: apiBody().slotMinutes })).toBeNull()
    expect(fromApi({ ...apiBody(), slotMinutes: { ...apiBody().slotMinutes, mon: 47 } })).toBeNull()
    const noDay = { ...apiBody().slotMinutes }
    delete noDay.fri
    expect(fromApi({ ...apiBody(), slotMinutes: noDay })).toBeNull()
    expect(fromApi({ ...apiBody(), services: [{ id: 'x', name: 'X', price: '5' }] })).toBeNull()
  })

  it('leaves the id off a new service', () => {
    const s = { services: [{ id: '', name: 'Shave', price: 20, from: false, note: '' }], slotMinutes: DEFAULT_SHOP_SETTINGS.slotMinutes }
    expect(toApi(s).services[0]).toEqual({ name: 'Shave', price: 20, from: false, note: '' })
  })

  it('uses the weekday names the API expects', () => {
    expect(DAY_KEYS).toEqual(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'])
  })
})

describe('checkDraft', () => {
  const fresh = () => draftFrom(DEFAULT_SHOP_SETTINGS)

  it('accepts the starting settings unchanged', () => {
    const r = checkDraft(fresh())
    expect(r.ok).toBe(true)
    expect(r.settings).toEqual(DEFAULT_SHOP_SETTINGS)
  })

  it('turns typed text into numbers and tidies names', () => {
    const d = fresh()
    d.services[0].name = '  Fresh   cut '
    d.services[0].price = '60'
    d.slots[4] = '25'
    const r = checkDraft(d)
    expect(r.settings.services[0]).toMatchObject({ id: 'mens-cut', name: 'Fresh cut', price: 60 })
    expect(r.settings.slotMinutes[4]).toBe(25)
  })

  it.each([['14'], ['17'], ['125'], ['abc'], ['']])('refuses the length %j', (text) => {
    const d = fresh()
    d.slots[1] = text
    const r = checkDraft(d)
    expect(r.ok).toBe(false)
    expect(r.errors.slots[1]).toMatch(/15 to 120 minutes, in steps of 5/)
  })

  it.each([['-1'], ['1000'], ['12.5'], [''], ['abc']])('refuses the price %j', (text) => {
    const d = fresh()
    d.services[2].price = text
    expect(checkDraft(d).errors.services[d.services[2].key].price).toBeTruthy()
  })

  it('refuses a missing, too short or duplicate name', () => {
    const d = fresh()
    d.services[0].name = 'x'
    d.services[3].name = "MEN'S haircut with DESIGN" // same as the second service, apart from capitals
    d.services[2].name = ''
    const { errors } = checkDraft(d)
    expect(errors.services[d.services[0].key].name).toBeTruthy()
    expect(errors.services[d.services[3].key].name).toMatch(/already has this name/)
    expect(errors.services[d.services[2].key].name).toBeTruthy()
  })

  it('refuses a long note, no services and too many services', () => {
    const d = fresh()
    d.services[0].note = 'n'.repeat(121)
    expect(checkDraft(d).errors.services[d.services[0].key].note).toBeTruthy()
    expect(checkDraft({ ...fresh(), services: [] }).errors.general).toMatch(/between 1 and 12/)
    const many = fresh()
    while (many.services.length < 13) many.services.push({ ...newDraftService(), name: `Service ${many.services.length}`, price: '5' })
    expect(checkDraft(many).errors.general).toMatch(/between 1 and 12/)
  })

  it('gives each new row its own key and no id', () => {
    const a = newDraftService()
    const b = newDraftService()
    expect(a.key).not.toBe(b.key)
    expect(a.id).toBe('')
  })

  it('notices a change', () => {
    const d = fresh()
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(false)
    d.slots[0] = '40'
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(true)
  })
})

describe('the shared store', () => {
  beforeEach(() => resetShopSettings())

  it('starts with the defaults and tells listeners about changes', () => {
    const heard = vi.fn()
    const off = subscribeShopSettings(heard)
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
    const next = { ...DEFAULT_SHOP_SETTINGS, slotMinutes: { ...DEFAULT_SHOP_SETTINGS.slotMinutes, 3: 40 } }
    setShopSettings(next)
    expect(heard).toHaveBeenCalledTimes(1)
    expect(getShopSettingsNow().slotMinutes[3]).toBe(40)
    off()
    setShopSettings(DEFAULT_SHOP_SETTINGS)
    expect(heard).toHaveBeenCalledTimes(1)
  })

  it('loads once and keeps the defaults if the API fails or sends nonsense', async () => {
    const fetcher = vi.fn().mockRejectedValue(new Error('offline'))
    await loadShopSettings(fetcher)
    await loadShopSettings(fetcher)
    expect(fetcher).toHaveBeenCalledTimes(1)
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
    resetShopSettings()
    await loadShopSettings(() => ({ nonsense: true }))
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
  })

  it('uses what the API sends', async () => {
    const body = apiBody()
    body.slotMinutes.mon = 30
    await loadShopSettings(() => body)
    expect(getShopSettingsNow().slotMinutes[1]).toBe(30)
  })
})

describe('paying online', () => {
  beforeEach(() => resetShopSettings())

  it('is off until the API says it is set up', () => {
    expect(DEFAULT_SHOP_SETTINGS.payOnline).not.toBe(true) // card payment is offered only once the API says it is set up
    expect(fromApi({ ...apiBody(), payOnline: true }).payOnline).toBe(true)
    expect(fromApi({ ...apiBody(), payOnline: 'yes' }).payOnline).toBe(false) // only a real true counts
    expect(fromApi(apiBody())).not.toHaveProperty('payOnline') // Vic's own settings do not carry it
  })

  it('is never sent back when Vic saves his settings', () => {
    expect(toApi({ ...DEFAULT_SHOP_SETTINGS, payOnline: true })).not.toHaveProperty('payOnline')
  })

  it('survives Vic saving his settings, which come back without it', async () => {
    await loadShopSettings(() => ({ ...apiBody(), payOnline: true }))
    expect(getShopSettingsNow().payOnline).toBe(true)
    setShopSettings(fromApi(apiBody()))
    expect(getShopSettingsNow().payOnline).toBe(true)
  })
})
VICBLESS_EOF
cat > "$STAGE/35" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import LogoCheckerboard from '../components/LogoCheckerboard.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, SMS_CONSENT, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'
import { clearPending, loadPending, readReturn, savePending, tabStorage } from '../lib/paymentReturn.js'
import { slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'

const STEPS = ['Service', 'Time', 'Details']
const REFRESH_MS = 30000 // how often the time grid re-checks while it is open
const payLine = (s, paidOnline = false) => {
  if (paidOnline) {
    return s.from
      ? `Paid online. You paid the starting price of $${s.price}. Vic settles any difference at the shop.`
      : `Paid online. $${s.price} total, thank you.`
  }
  return s.from
    ? `Pay at the shop. Starts at $${s.price}, the final price depends on what you get.`
    : `Pay at the shop. $${s.price} total.`
}

function buildDays() {
  const start = new Date()
  start.setHours(0, 0, 0, 0)
  return Array.from({ length: DAYS_AHEAD }, (_, i) => {
    const d = new Date(start)
    d.setDate(start.getDate() + i)
    return d
  })
}

function dayLabel(d) {
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const diff = Math.round((d - today) / 86400000)
  const monthDay = d.toLocaleDateString(undefined, { month: 'long', day: 'numeric' })
  if (diff === 0) return `Today, ${monthDay}`
  if (diff === 1) return `Tomorrow, ${monthDay}`
  return d.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })
}

export default function Book() {
  const days = useMemo(buildDays, [])
  const staff = STAFF[0]
  // Vic's services and how long an appointment is on each weekday (he edits both in his dashboard).
  const shop = useShopSettings()
  const SERVICES = shop.services

  // For each day: the taken times, and whether the whole day is off.
  const [availability, setAvailability] = useState(null)
  const busy = useMemo(
    () => availability && Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy])),
    [availability],
  )
  const [loadError, setLoadError] = useState(false)
  // Back from Stripe: #/book?paid=CODE (they paid) or #/book?payment=cancelled (they did not). What they were booking was
  // remembered before they left, so they land on their confirmation, or back on their filled-in form to try again.
  const [back] = useState(() => {
    const kind = readReturn(window.location.hash)
    return kind ? { ...kind, pending: loadPending(tabStorage()) } : null
  })
  const resumed = back && back.kind === 'cancelled' ? back.pending : null
  // A service link on the home page (#/book?service=mens-design) arrives with the service chosen.
  const [preselected] = useState(() => (resumed ? resumed.request.serviceId : serviceIdFromHash(window.location.hash, shop.services)))
  const [step, setStep] = useState(resumed ? 2 : preselected ? 1 : 0)
  const [serviceId, setServiceId] = useState(preselected)
  const [dateKey, setDateKey] = useState(resumed ? resumed.request.dateKey : null)
  const [time, setTime] = useState(resumed ? resumed.request.time : null)
  const [form, setForm] = useState(resumed ? { ...resumed.request.form } : { name: '', phone: '', email: '', notes: '', sms: false, pay: 'shop' })
  const [errors, setErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [notice, setNotice] = useState(
    back && back.kind === 'cancelled'
      ? "Your payment wasn't completed. Your time is held for about half an hour, so you can pay now or choose to pay at the shop."
      : '',
  )
  // They paid: the booking they made before leaving, or just its code if this browser forgot the rest.
  const [done, setDone] = useState(() => {
    if (!back || back.kind !== 'paid') return null
    const saved = back.pending && back.pending.booking.code === back.code ? back.pending.booking : null
    return { ...(saved || { code: back.code, name: '', serviceId: '', dateKey: null, start: null }), payment: 'paid' }
  })
  // A time held for this customer while they pay shows as taken to everyone, themselves included, so it is not "just taken".
  const ownHold = resumed ? { dateKey: resumed.request.dateKey, time: resumed.request.time } : null

  const service = SERVICES.find((s) => s.id === serviceId) || null

  const loadBusy = () =>
    getAvailability(days.map(keyOf))
      .then((result) => {
        setAvailability(result)
        setLoadError(false)
      })
      .catch(() => setLoadError(true))

  useEffect(() => {
    loadBusy()
  }, [])

  // While the time step is open, check again every 30 seconds and whenever the tab comes back
  // into view, so a time someone else just booked turns grey instead of failing at the last step.
  useEffect(() => {
    if (step !== 1) return undefined
    const refresh = () => {
      if (document.visibilityState === 'visible') {
        getAvailability(days.map(keyOf))
          .then(setAvailability)
          .catch(() => {}) // a missed refresh is fine, the next one or the final check catches up
      }
    }
    const timer = window.setInterval(refresh, REFRESH_MS)
    document.addEventListener('visibilitychange', refresh)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', refresh)
    }
  }, [step])

  const slotsByDay = useMemo(() => {
    if (!busy || !service) return {}
    const now = new Date()
    const out = {}
    for (const d of days) {
      const k = keyOf(d)
      out[k] = slotsForDay({
        date: d,
        minutes: slotFor(shop, d),
        hours: HOURS,
        busy: busy[k] || [],
        now,
        slotMinutes: slotFor(shop, d),
      })
    }
    return out
  }, [busy, service, days, shop])

  // Preselect the first day that has openings when the time step opens.
  useEffect(() => {
    if (step !== 1 || dateKey) return
    const first = days.find((d) => (slotsByDay[keyOf(d)] || []).length > 0)
    if (first) setDateKey(keyOf(first))
  }, [step, dateKey, slotsByDay, days])

  // If the time you picked gets taken while the page is open, say so and let you pick again.
  useEffect(() => {
    if (time === null || !dateKey || !busy) return
    if (ownHold && ownHold.dateKey === dateKey && ownHold.time === time) return
    if (!(slotsByDay[dateKey] || []).includes(time)) {
      setTime(null)
      setNotice('That time was just taken. Pick another time.')
    }
  }, [slotsByDay])

  const reach = !service ? 0 : time === null ? 1 : 2
  // Card payment is offered when the API says it is set up and the service costs something; the choice is theirs.
  const canPayOnline = shop.payOnline === true && !!service && service.price > 0
  const wantsOnline = canPayOnline && form.pay === 'online'

  function chooseService(id) {
    if (id !== serviceId) setTime(null)
    setServiceId(id)
    setStep(1)
  }

  function updateField(e) {
    const { name, type, checked, value } = e.target
    setForm((f) => ({ ...f, [name]: type === 'checkbox' ? checked : value }))
  }

  async function submit(e) {
    e.preventDefault()
    const err = {}
    if (form.name.trim().length < 2) err.name = 'Enter your full name.'
    if (form.phone.replace(/\D/g, '').length < 10) err.phone = 'Enter a 10-digit mobile number so Vic can reach you.'
    if (form.email.trim() && !/^\S+@\S+\.\S+$/.test(form.email.trim())) err.email = "That email doesn't look right. Use something like name@example.com, or leave it blank."
    setErrors(err)
    if (Object.keys(err).length) return

    setSubmitting(true)
    setNotice('')
    try {
      const booking = await createBooking({
        staffId: staff.id,
        serviceId: service.id,
        dateKey,
        start: time,
        minutes: slotFor(shop, fromKey(dateKey)),
        name: form.name.trim(),
        phone: form.phone.trim(),
        email: form.email.trim(),
        notes: form.notes.trim(),
        smsConsent: form.sms,
        payment: wantsOnline ? 'online' : 'shop',
        returnTo: window.location.origin,
      })
      if (booking.checkoutUrl) {
        // Off to Stripe to pay. What they were booking is remembered for when they come back (or turn back).
        savePending(tabStorage(), { request: { serviceId: service.id, dateKey, time, form: { ...form, pay: 'online' } }, booking })
        window.location.assign(booking.checkoutUrl)
        return // the page is leaving: the button keeps saying so
      }
      clearPending(tabStorage())
      setDone(booking)
    } catch (ex) {
      if (ex instanceof SlotTakenError) {
        setNotice('That time was just taken. Pick another time.')
        setTime(null)
        setStep(1)
        await loadBusy()
      } else {
        // A message the API wrote for customers (a bad phone number, too many bookings) is shown as it is.
        setNotice(
          ex && ex.friendly ? (
            ex.message
          ) : (
            <>
              Something went wrong saving your booking. Try again, or email <EmailLink />.
            </>
          ),
        )
      }
    }
    setSubmitting(false)
  }

  if (done) {
    // the booking remembers the name it was made with; the price comes from the current list when it is still there
    const current = SERVICES.find((s) => s.id === done.serviceId)
    const booked = { ...(current || { price: 0 }), name: done.serviceName || (current && current.name) || 'Appointment' }
    return (
      <main className="book book-done">
        <LogoCheckerboard />
        <section className="done" aria-live="polite">
          <Reveal as="h1" from="above" className="done-headline">
            <span>{SUCCESS_HEADLINE[0]}</span> <span className="done-line-2">{SUCCESS_HEADLINE[1]}</span>
          </Reveal>
          <h2 className="book-title done-booked">{done.name ? `You're booked, ${done.name.split(' ')[0]}.` : "You're booked."}</h2>
          <p className="code" aria-label="Confirmation code">{done.code}</p>
          {done.dateKey ? (
            <>
              <p>
                <strong>{booked.name}</strong> with {staff.name}
              </p>
              <p>
                {dayLabel(fromKey(done.dateKey))} at {fmtTime(done.start)}
              </p>
              {current && <p>{payLine(booked, done.payment === 'paid')}</p>}
            </>
          ) : (
            <p>Your payment went through and Vic has your booking. Thank you!</p>
          )}
          <p className="muted">
            Need to change it? Email <EmailLink /> and quote your code.
          </p>
          <a className="btn btn-primary" href="#/">Back to home</a>
        </section>
      </main>
    )
  }

  const selectedDay = dateKey ? fromKey(dateKey) : null
  const daySlots = dateKey ? slotsByDay[dateKey] || [] : []
  const openTimes = new Set(daySlots)
  const dayStarts =
    selectedDay && service
      ? startsForDay({ date: selectedDay, minutes: slotFor(shop, selectedDay), hours: HOURS, slotMinutes: slotFor(shop, selectedDay) })
      : []

  return (
    <main className="book">
      <a className="back" href="#/">Back to home</a>
      <h1 className="book-title">Book with {staff.name}</h1>

      <ol className="steps" aria-label="Booking steps">
        {STEPS.map((label, i) => (
          <li key={label}>
            <button
              type="button"
              className={i < step ? 'done' : ''}
              aria-current={i === step ? 'step' : undefined}
              disabled={i > reach}
              onClick={() => setStep(i)}
            >
              <span className="n">{i < step ? '✓' : i + 1}</span>
              {label}
            </button>
          </li>
        ))}
      </ol>

      {loadError && (
        <p className="notice" role="alert">
          Could not load times. Refresh the page to try again.
        </p>
      )}
      {notice && (
        <p className="notice" role="alert">
          {notice}
        </p>
      )}

      {step === 0 && (
        <section className="panel">
          <h2>Choose a service</h2>
          {SERVICES.map((s) => (
            <button
              key={s.id}
              type="button"
              className="opt"
              aria-pressed={serviceId === s.id}
              onClick={() => chooseService(s.id)}
            >
              <span className="name">{s.name}</span>
              <span className="leader" />
              <span className="price">{priceLabel(s)}</span>
              {s.note && <span className="note">{s.note}</span>}
            </button>
          ))}
        </section>
      )}

      {step === 1 && (
        <section className="panel">
          <h2>Pick a day and time</h2>
          {!busy && !loadError && <p className="muted">Loading times…</p>}
          {busy && (
            <>
              <div className="days" role="group" aria-label="Days">
                {days.map((d) => {
                  const k = keyOf(d)
                  const closed = !HOURS[d.getDay()] || !!availability[k]?.dayOff // shop closed that weekday, or Vic took the day off
                  const free = (slotsByDay[k] || []).length
                  return (
                    <button
                      key={k}
                      type="button"
                      className="day"
                      aria-pressed={dateKey === k}
                      disabled={!free}
                      onClick={() => {
                        setDateKey(k)
                        setTime(null)
                      }}
                    >
                      <span className="dow">{d.toLocaleDateString(undefined, { weekday: 'short' })}</span>
                      <span className="dom">{d.getDate()}</span>
                      <span className="tag">{closed ? 'Closed' : free ? '' : 'Full'}</span>
                    </button>
                  )
                })}
              </div>

              {selectedDay && dayStarts.length > 0 && (
                <>
                  <div className="times" role="group" aria-label={`Times on ${dayLabel(selectedDay)}`}>
                    {dayStarts.map((m) => {
                      const open = openTimes.has(m)
                      return (
                        <button
                          key={m}
                          type="button"
                          className="time"
                          aria-pressed={time === m}
                          disabled={!open}
                          onClick={() => {
                            setTime(m)
                            setNotice('')
                          }}
                        >
                          {fmtTime(m)}
                          {!open && <span className="sr-only"> (unavailable)</span>}
                        </button>
                      )
                    })}
                  </div>
                  {daySlots.length < dayStarts.length && <p className="times-note">Greyed-out times are not available.</p>}
                </>
              )}
              {selectedDay && dayStarts.length === 0 && <p className="empty">No times on this day. Pick another day.</p>}
              {!selectedDay && <p className="empty">Pick a day to see open times.</p>}
            </>
          )}
          <div className="actions">
            <button type="button" className="btn" onClick={() => setStep(0)}>
              Back
            </button>
            <button type="button" className="btn btn-primary" disabled={time === null} onClick={() => setStep(2)}>
              Continue
            </button>
          </div>
        </section>
      )}

      {step === 2 && service && (
        <section className="panel">
          <h2>Your details</h2>
          <dl className="summary">
            <div>
              <dt>Service</dt>
              <dd>
                {service.name} ({slotFor(shop, fromKey(dateKey))} min), {priceLabel(service)}
              </dd>
            </div>
            <div>
              <dt>When</dt>
              <dd>
                {dayLabel(fromKey(dateKey))} at {fmtTime(time)}
              </dd>
            </div>
          </dl>

          <form onSubmit={submit} noValidate>
            <div className="field">
              <label htmlFor="f-name">Full name</label>
              <input id="f-name" name="name" maxLength={LIMITS.name} autoComplete="name" value={form.name} onChange={updateField} aria-invalid={!!errors.name} aria-describedby="e-name" />
              <p className="err" id="e-name">{errors.name}</p>
            </div>
            <div className="field">
              <label htmlFor="f-phone">Mobile number</label>
              <input id="f-phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" value={form.phone} onChange={updateField} aria-invalid={!!errors.phone} aria-describedby="e-phone" />
              <p className="err" id="e-phone">{errors.phone}</p>
              <label className="consent" htmlFor="f-sms">
                <input id="f-sms" name="sms" type="checkbox" checked={form.sms} onChange={updateField} />
                <span>{SMS_CONSENT}</span>
              </label>
            </div>
            <div className="field">
              <label htmlFor="f-email">
                Email <span className="hint">(optional, for a confirmation)</span>
              </label>
              <input id="f-email" name="email" type="email" autoComplete="email" value={form.email} onChange={updateField} aria-invalid={!!errors.email} aria-describedby="e-email" />
              <p className="err" id="e-email">{errors.email}</p>
            </div>
            <div className="field">
              <label htmlFor="f-notes">
                Notes for Vic <span className="hint">(optional)</span>
              </label>
              <textarea id="f-notes" name="notes" rows={3} maxLength={LIMITS.notes} value={form.notes} onChange={updateField} aria-describedby="notes-count" />
              <p
                id="notes-count"
                className={nearLimit(form.notes.length, LIMITS.notes) ? 'counter counter-near' : 'counter'}
              >
                {countLabel(form.notes.length, LIMITS.notes)}
              </p>
            </div>
            {canPayOnline ? (
              <fieldset className="pay-choice">
                <legend>How would you like to pay?</legend>
                <label className="pay-option" htmlFor="f-pay-shop">
                  <input id="f-pay-shop" type="radio" name="pay" value="shop" checked={!wantsOnline} onChange={updateField} />
                  <span>
                    <strong>Pay at the shop</strong>
                    <span className="hint">No card needed to book.</span>
                  </span>
                </label>
                <label className="pay-option" htmlFor="f-pay-online">
                  <input id="f-pay-online" type="radio" name="pay" value="online" checked={wantsOnline} onChange={updateField} />
                  <span>
                    <strong>Pay online now{service.from ? ` ($${service.price} starting price)` : ` ($${service.price})`}</strong>
                    <span className="hint">
                      Secure card payment with Stripe.
                      {service.from ? ' Vic settles any difference at the shop.' : ''}
                    </span>
                  </span>
                </label>
              </fieldset>
            ) : (
              <p className="muted">Pay at the shop. No card needed to book.</p>
            )}
            <div className="actions">
              <button type="button" className="btn" onClick={() => setStep(1)}>
                Back
              </button>
              <button type="submit" className="btn btn-primary" disabled={submitting}>
                {submitting ? (wantsOnline ? 'Taking you to payment…' : 'Confirming…') : wantsOnline ? 'Continue to payment' : 'Confirm booking'}
              </button>
            </div>
          </form>
        </section>
      )}
    </main>
  )
}
VICBLESS_EOF
cat > "$STAGE/36" <<'VICBLESS_EOF'
/* Vicbless: dark purple-black ground, light lavender ink, small purple accents. */
:root {
  --bg: #0a0612;
  --surface: #130c21;
  --ink: #f6efff;
  --muted: #b3a5c9;
  --line: #2f2347;
  --purple: #a855f7;
  --accent: #c084fc;
  --on-accent: #0a0612;
  --danger: #ff8aa0;
  --header-bg: rgba(10, 6, 18, 0.92);
  /* Text and accent that sit on top of photos and video. Always light, in either theme. */
  --on-media: #f6efff;
  --accent-media: #c084fc;
  --font: 'Archivo', 'Arial Narrow', system-ui, -apple-system, 'Segoe UI', sans-serif;
  color-scheme: dark;
}

/* Light theme. Switched with the Dark mode setting (see src/lib/settings.js). */
html[data-theme='light'] {
  --bg: #f8f4fd;
  --surface: #ffffff;
  --ink: #1b1030;
  --muted: #5a4a73;
  --line: #ddd0ee;
  --purple: #7e22ce;
  --accent: #7c3aed;
  --on-accent: #ffffff;
  --danger: #b3123b;
  --header-bg: rgba(248, 244, 253, 0.92);
  color-scheme: light;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font);
  font-size: 1rem;
  line-height: 1.5;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

button,
input,
textarea {
  font: inherit;
  color: inherit;
}

button {
  cursor: pointer;
}

:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- Home: pinned logo bar, video hero, shop info, footer ---------- */
:root {
  --brand-h: calc(84px + env(safe-area-inset-top, 0px));
}

/* Logo bar. Sticky, so it follows the page while scrolling. The logo sits in the
   middle column and the social links on the right. */
.brand {
  position: sticky;
  top: 0;
  z-index: 10;
  height: var(--brand-h);
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  padding: env(safe-area-inset-top, 0px) 16px 0;
  background: var(--header-bg);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}

.logo {
  margin: 0;
  width: min(100%, 880px);
}

.brand .logo {
  grid-column: 2;
  width: auto;
  height: 60px;
}

.logo svg {
  display: block;
  width: 100%;
  height: auto;
  filter: drop-shadow(0 0 3px var(--purple));
}

.brand .logo svg {
  width: auto;
  height: 100%;
}

.logo-link {
  display: block;
  height: 100%;
  color: inherit;
  border-radius: 6px;
}

.logo path {
  fill: var(--ink);
  stroke: var(--purple);
  stroke-width: 6;
  stroke-linejoin: round;
  paint-order: stroke;
}

.brand .socials {
  grid-column: 3;
  justify-self: end;
}

.socials {
  display: flex;
  align-items: center;
  gap: 2px;
}

.social {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  color: var(--ink);
  border-radius: 50%;
}

.social:hover {
  color: var(--accent);
}

/* The hero fills whatever is left of the first screen under the pinned bar. */
.hero {
  position: relative;
  height: calc(100vh - var(--brand-h));
  height: calc(100svh - var(--brand-h));
  min-height: 440px;
  overflow: hidden;
  background: var(--bg);
}

/* Blurred, dimmed poster fills the sides when the screen is wider than the video. */
.hero-backdrop {
  position: absolute;
  top: -48px;
  left: -48px;
  width: calc(100% + 96px);
  height: calc(100% + 96px);
  object-fit: cover;
  filter: blur(36px) brightness(0.5) saturate(1.2);
}

.hero-video {
  position: absolute;
  top: 0;
  left: 50%;
  /* Much taller than the window (165%): --pan (0 to 1, set while scrolling) slides the
     footage up through the extra 65% (that is 39.4% of the video's own height), so the
     view travels from the top of the video to the bottom. */
  transform: translate3d(-50%, calc(var(--pan, 0) * -39.4%), 0);
  will-change: transform;
  height: 165%;
  width: auto;
  max-width: 100%;
  aspect-ratio: 720 / 1084;
  object-fit: cover;
  background: var(--surface);
}

/* Soft shade behind the button so it reads over any frame of the video. */
.hero::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse 60% 40% at 50% 50%, rgba(10, 6, 18, 0.55), rgba(10, 6, 18, 0) 70%);
}

/* Words at the top of the video, right under the logo. A dark fade behind them keeps them readable
   on any frame. They use fixed light colours (like the other text on the video), so they look the
   same in dark and light mode, and they slide down into place when the page opens. */
.hero-tagline {
  position: absolute;
  top: 0;
  right: 0;
  left: 0;
  z-index: 1;
  margin: 0;
  padding: 18px 16px 48px;
  font-size: clamp(1.5rem, 6.2vw, 2.7rem);
  font-weight: 900;
  line-height: 1;
  letter-spacing: -0.01em;
  text-align: center;
  font-variation-settings: 'wdth' 70;
  color: var(--on-media);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.55);
  background: linear-gradient(to bottom, rgba(10, 6, 18, 0.72), rgba(10, 6, 18, 0));
  pointer-events: none;
}

.hero-tagline span {
  display: block;
  animation: tagline-in 0.8s cubic-bezier(0.2, 0.7, 0.2, 1) both;
  animation-delay: calc(0.3s + var(--i, 0) * 0.16s);
}

.hero-tagline .hero-tagline-accent {
  color: var(--accent-media);
}

@keyframes tagline-in {
  from {
    opacity: 0;
    transform: translateY(-22px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

.hero-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  pointer-events: none;
}

.hero .book-now {
  pointer-events: auto;
  max-width: min(88vw, 460px);
  padding: 20px 44px;
  font-size: clamp(1.15rem, 4.6vw, 1.5rem);
  line-height: 1.15;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  animation: ring 2.8s ease-out infinite;
}

@keyframes ring {
  0% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  }
  70%,
  100% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 22px rgba(192, 132, 252, 0);
  }
}

.hero-toggle {
  position: absolute;
  right: 14px;
  bottom: 14px;
  z-index: 2;
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--on-media);
  background: rgba(10, 6, 18, 0.6);
  border: 2px solid rgba(246, 239, 255, 0.7);
  border-radius: 50%;
}

.hero-toggle:hover {
  border-color: var(--on-media);
}

.info {
  max-width: 960px;
  margin: 0 auto;
  padding: 72px 20px 48px;
}

.info-grid {
  display: grid;
  grid-template-columns: 1.2fr 1fr;
  gap: 48px;
}

.info h2 {
  margin: 0 0 14px;
  font-size: 1.5rem;
  font-weight: 800;
  font-variation-settings: 'wdth' 85;
}

.menu,
.hours {
  margin: 0 0 32px;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.menu li {
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
}

.menu-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.menu-name {
  font-weight: 700;
}

.menu-leader {
  flex: 1;
  min-width: 12px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.menu-price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.menu-meta {
  margin: 2px 0 0;
  font-size: 0.9rem;
  color: var(--muted);
}

.hours li {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
}

.hours li span:last-child {
  text-align: right;
}

.hours .closed {
  color: var(--muted);
}

.info address {
  font-style: normal;
  color: var(--muted);
}

/* Contact links (the shop's email). A long address may break onto a second line on a narrow phone instead of running off the side. */
.phone-link {
  overflow-wrap: anywhere;
  font-weight: 700;
  color: var(--accent);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.phone-link:hover {
  text-decoration-thickness: 2px;
}

.info address .phone-link {
  display: inline-block;
  padding: 8px 0;
}

.notice .phone-link {
  color: inherit;
}

.info-cta {
  display: flex;
  justify-content: center;
  margin-top: 40px;
}

.site-foot {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 32px 20px calc(36px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.9rem;
}

.site-foot .copy {
  margin: 0;
  font-weight: 700;
  letter-spacing: 0.04em;
}

/* Quiet credit: small, muted, faint underline. Still readable, just out of the way. */
.site-foot .credit {
  margin: 4px 0 0;
  font-size: 0.74rem;
}

.site-foot .credit a {
  display: inline-block;
  padding: 6px 4px;
  color: var(--muted);
  text-decoration: underline;
  text-decoration-color: var(--line);
  text-underline-offset: 3px;
}

.site-foot .credit a:hover {
  color: var(--ink);
  text-decoration-color: currentColor;
}

/* Social links along the bottom of the video. */
.hero-socials {
  position: absolute;
  left: 50%;
  bottom: 14px;
  z-index: 2;
  transform: translateX(-50%);
}

.hero-socials .socials {
  padding: 2px 8px;
  background: rgba(10, 6, 18, 0.6);
  border: 1px solid rgba(246, 239, 255, 0.25);
  border-radius: 999px;
}

.hero-socials .social {
  color: var(--on-media);
}

.hero-socials .social:hover {
  color: var(--accent-media);
}

/* Scroll reveal: content below the video fades up as it enters the screen. */
.reveal {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0.7, 0.2, 1);
  transition-delay: var(--d, 0ms);
}

.reveal.in {
  opacity: 1;
  transform: none;
}

/* Branded CTA on each haircut type: a purple box, matching the other booking buttons. */
.svc-cta {
  display: inline-block;
  margin-top: 12px;
  padding: 12px 24px;
  font-weight: 800;
  text-align: center;
  color: var(--on-accent);
  text-decoration: none;
  background: var(--accent);
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.svc-cta:hover {
  filter: brightness(1.08);
}

/* Menu: three-line button on the left of the pinned bar, opens a panel under it. */
.brand .site-menu {
  grid-column: 1;
  justify-self: start;
}

.menu-toggle {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--ink);
  background: none;
  border: 2px solid var(--line);
  border-radius: 10px;
}

.menu-toggle:hover {
  border-color: var(--accent);
}

/* The bar is the positioned parent, so the panel hangs just under it. */
.menu-panel {
  position: absolute;
  top: calc(100% + 6px);
  left: 12px;
  z-index: 20;
  width: min(330px, calc(100vw - 24px));
  max-height: calc(100vh - var(--brand-h) - 24px);
  max-height: calc(100svh - var(--brand-h) - 24px);
  padding: 8px;
  overflow-y: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.45);
}

.menu-group + .menu-group {
  margin-top: 4px;
}

.menu-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  min-height: 48px;
  padding: 10px 12px;
  font-size: 1.05rem;
  font-weight: 800;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.menu-head:hover {
  background: var(--bg);
}

.menu-head .chev {
  transition: transform 0.2s ease;
}

.menu-head[aria-expanded='true'] .chev {
  transform: rotate(180deg);
}

.menu-sub {
  padding: 2px 4px 8px;
}

.menu-link {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 48px;
  padding: 10px 12px;
  font-weight: 600;
  color: var(--ink);
  text-decoration: none;
  border-radius: 8px;
}

.menu-link:hover {
  color: var(--accent);
  background: var(--bg);
}

.setting {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  min-height: 56px;
  padding: 8px 12px;
  text-align: left;
  color: var(--ink);
  background: none;
  border: 0;
  border-radius: 8px;
}

.setting:hover {
  background: var(--bg);
}

.setting-text {
  display: flex;
  flex: 1;
  flex-direction: column;
}

.setting-label {
  font-weight: 700;
}

.setting-hint {
  font-size: 0.82rem;
  color: var(--muted);
}

.switch-state {
  min-width: 2em;
  font-size: 0.9rem;
  font-weight: 700;
  text-align: right;
  color: var(--muted);
}

.switch-track {
  position: relative;
  flex: none;
  width: 46px;
  height: 26px;
  background: var(--line);
  border: 2px solid var(--line);
  border-radius: 999px;
  transition: background 0.2s ease, border-color 0.2s ease;
}

.switch-track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 18px;
  height: 18px;
  background: var(--ink);
  border-radius: 50%;
  transition: transform 0.2s ease;
}

.setting[aria-checked='true'] .switch-track {
  background: var(--accent);
  border-color: var(--accent);
}

.setting[aria-checked='true'] .switch-track::after {
  background: var(--on-accent);
  transform: translateX(20px);
}

/* Extra rows at the bottom of the menu (the dashboard's View site and Sign out). */
.menu-extra {
  margin-top: 4px;
  padding-top: 4px;
  border-top: 1px solid var(--line);
}

button.menu-link {
  width: 100%;
  text-align: left;
  background: none;
  border: 0;
}

/* Words that drop down into place instead of lifting up. */
.reveal-down {
  transform: translateY(-28px);
}

/* Photo section under the video. The photo is 130% of the section's height and slides
   through it with --pan (see Statement.jsx), so it has its own parallax. The headline sits
   at the top and the stacked words at the bottom, which keeps the faces clear in the middle. */
.statement {
  position: relative;
  color: var(--on-media);
  display: flex;
  min-height: 780px;
  min-height: max(780px, 100svh);
  padding: 56px 20px 48px;
  overflow: hidden;
  background: var(--bg);
}

.statement-img {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 130%;
  object-fit: cover;
  object-position: 20% 50%;
  transform: translate3d(0, calc(var(--pan, 0.5) * -23.1%), 0);
  will-change: transform;
}

/* Darkens the top and bottom where the text sits, leaves the middle (the faces) clear. */
.statement::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(
    to bottom,
    rgba(10, 6, 18, 0.78) 0%,
    rgba(10, 6, 18, 0.35) 28%,
    rgba(10, 6, 18, 0) 45%,
    rgba(10, 6, 18, 0) 55%,
    rgba(10, 6, 18, 0.55) 72%,
    rgba(10, 6, 18, 0.9) 100%
  );
}

.statement-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 32px;
  width: 100%;
  max-width: 1100px;
  margin: 0 auto;
}

.statement h2 {
  max-width: 18ch;
  margin: 0 0 14px;
  font-size: clamp(1.5rem, 5.2vw, 2.6rem);
  font-weight: 900;
  line-height: 1.08;
  letter-spacing: 0.01em;
  font-variation-settings: 'wdth' 85;
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.6);
}

.statement p {
  max-width: 44ch;
  margin: 0;
  font-size: clamp(1rem, 2.6vw, 1.2rem);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.7);
}

.statement-words {
  margin: 0;
  padding: 0;
  list-style: none;
}

.statement-words li {
  font-size: clamp(2.7rem, 13vw, 6.8rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-shadow: 0 4px 24px rgba(0, 0, 0, 0.55);
}

.statement-words .statement-place {
  color: var(--accent-media);
}

/* Centred call to action over the photo: a see-through box with a light outline.
   Fixed light colours, so it reads the same in dark and light mode. */
.statement-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  padding: 0 20px;
  pointer-events: none;
}

.statement-cta-link {
  display: block;
  max-width: min(86vw, 440px);
  padding: 18px 36px;
  font-size: clamp(1.1rem, 4.6vw, 1.4rem);
  font-weight: 800;
  line-height: 1.15;
  text-align: center;
  color: var(--on-media);
  text-decoration: none;
  background: rgba(10, 6, 18, 0.28);
  border: 2px solid rgba(246, 239, 255, 0.85);
  border-radius: 14px;
  -webkit-backdrop-filter: blur(3px);
  backdrop-filter: blur(3px);
  pointer-events: auto;
  transition: background 0.2s ease, color 0.2s ease, border-color 0.2s ease;
}

.statement-cta-link:hover {
  color: #0a0612;
  background: var(--accent-media);
  border-color: var(--accent-media);
}

@media (min-width: 900px) {
  /* Taller section and slightly smaller words on wide screens, so the centred button always
     has a free band to sit in between the paragraph above and the words below. */
  .statement {
    min-height: max(840px, 92svh);
  }

  .statement-words li {
    font-size: clamp(3.4rem, 5.4vw, 4.8rem);
  }

  /* On wide screens the words sit on the left, so shade the left side as well. */
  .statement::after {
    background: linear-gradient(90deg, rgba(10, 6, 18, 0.75) 0%, rgba(10, 6, 18, 0.4) 40%, rgba(10, 6, 18, 0) 70%),
      linear-gradient(
        to bottom,
        rgba(10, 6, 18, 0.6) 0%,
        rgba(10, 6, 18, 0) 30%,
        rgba(10, 6, 18, 0) 60%,
        rgba(10, 6, 18, 0.7) 100%
      );
  }
}

@media (max-width: 760px) {
  .info-grid {
    grid-template-columns: 1fr;
    gap: 36px;
  }
}

@media (max-width: 520px) {
  .hero .book-now {
    padding: 16px 32px;
  }
}

/* Motion off: the Motion setting (which starts from the visitor's system setting). */
html[data-motion='off'] .hero .book-now,
html[data-motion='off'] .hero-tagline span {
  animation: none;
}

html[data-motion='off'] .reveal,
html[data-motion='off'] .reveal-down {
  opacity: 1;
  transform: none;
  transition: none;
}

html[data-motion='off'] .chev,
html[data-motion='off'] .switch-track,
html[data-motion='off'] .switch-track::after {
  transition: none;
}

/* ---------- Buttons ---------- */
.btn {
  display: inline-block;
  padding: 13px 24px;
  border: 2px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--ink);
  font-weight: 700;
  text-align: center;
  text-decoration: none;
}

.btn:not(:disabled):hover {
  border-color: var(--accent);
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.btn-primary:not(:disabled):hover {
  filter: brightness(1.08);
}

.book-now {
  padding: 18px 64px;
  border-radius: 999px;
  font-size: 1.35rem;
  font-weight: 800;
  letter-spacing: 0.01em;
}

/* ---------- Booking ---------- */
.book {
  max-width: 640px;
  margin: 0 auto;
  padding: calc(24px + env(safe-area-inset-top, 0px)) 20px 72px;
}

.back {
  display: inline-block;
  margin-bottom: 8px;
  color: var(--muted);
  text-decoration: none;
  padding: 6px 0;
}

.back:hover {
  color: var(--ink);
}

.book-title {
  margin: 0 0 20px;
  font-size: clamp(2rem, 7vw, 2.8rem);
  font-weight: 900;
  line-height: 1.05;
  font-variation-settings: 'wdth' 85;
}

.steps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.steps button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: none;
  border: 2px solid var(--line);
  border-radius: 999px;
  color: var(--muted);
  font-weight: 600;
  font-size: 0.92rem;
}

.steps button[aria-current='step'] {
  border-color: var(--accent);
  color: var(--ink);
}

.steps button.done {
  color: var(--ink);
}

.steps button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.steps .n {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--line);
  font-size: 0.8rem;
}

.steps [aria-current='step'] .n {
  background: var(--accent);
  color: var(--on-accent);
}

.panel {
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
  padding: 22px;
}

.panel h2 {
  margin: 0 0 16px;
  font-size: 1.4rem;
  font-weight: 800;
}

.opt {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  width: 100%;
  margin-bottom: 10px;
  padding: 14px;
  text-align: left;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.opt:hover {
  border-color: var(--accent);
}

.opt[aria-pressed='true'] {
  border-color: var(--accent);
  box-shadow: inset 4px 0 0 var(--accent);
}

.opt .name {
  font-weight: 700;
}

.opt .meta {
  color: var(--muted);
  font-size: 0.9rem;
}

.opt .leader {
  flex: 1;
  min-width: 16px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.opt .price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.opt .note {
  flex-basis: 100%;
  margin-top: 2px;
  font-size: 0.88rem;
  font-weight: 400;
  color: var(--muted);
}

.days {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 2px 2px 12px;
  overflow-x: auto;
}

.day {
  flex: none;
  width: 72px;
  padding: 10px 6px;
  text-align: center;
  line-height: 1.2;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.day .dow {
  display: block;
  font-size: 0.85rem;
  color: var(--muted);
}

.day .dom {
  display: block;
  font-size: 1.4rem;
  font-weight: 800;
}

.day .tag {
  display: block;
  min-height: 1em;
  font-size: 0.75rem;
  color: var(--muted);
}

.day[aria-pressed='true'] {
  border-color: var(--accent);
}

.day:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(98px, 1fr));
  gap: 8px;
  margin: 12px 0 4px;
}

.time {
  padding: 10px 6px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.time:hover:not(:disabled) {
  border-color: var(--accent);
}

/* Times that are taken or blocked stay visible, greyed out and struck through. */
.time:disabled {
  color: var(--muted);
  text-decoration: line-through;
  opacity: 0.45;
  cursor: not-allowed;
}

.times-note {
  margin: 8px 0 0;
  font-size: 0.85rem;
  color: var(--muted);
}

.time[aria-pressed='true'] {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.empty {
  padding: 18px;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

.summary {
  margin: 0 0 20px;
  padding: 14px 16px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.summary div + div {
  margin-top: 10px;
}

.summary dt {
  font-size: 0.85rem;
  color: var(--muted);
}

.summary dd {
  margin: 0;
  font-weight: 600;
}

.field {
  margin-bottom: 14px;
}

.field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}

.field input,
.field textarea {
  width: 100%;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.field input:focus,
.field textarea:focus {
  border-color: var(--accent);
}

.field input[aria-invalid='true'] {
  border-color: var(--danger);
}

.field .consent {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  margin: 12px 0 0;
  font-size: 0.9rem;
  font-weight: 400;
  color: var(--muted);
  line-height: 1.4;
}

.field .consent input {
  flex: none;
  width: 24px;
  height: 24px;
  margin: 0;
  padding: 0;
  accent-color: var(--accent);
}

.hint {
  font-weight: 400;
  font-size: 0.85rem;
  color: var(--muted);
}

.err {
  min-height: 1.3em;
  margin: 4px 0 0;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--danger);
}

.notice {
  margin: 0 0 16px;
  padding: 12px 14px;
  font-weight: 600;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.muted {
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 20px;
}

.done {
  padding-top: 24px;
}

.done p {
  margin: 0 0 8px;
}

.code {
  display: inline-block;
  margin: 4px 0 16px !important;
  padding: 6px 14px;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.done .btn {
  margin-top: 16px;
}

/* Big headline on the booking success screen. */
.done-headline {
  margin: 0 0 28px;
  font-size: clamp(2.6rem, 11vw, 4.6rem);
  font-weight: 900;
  line-height: 0.95;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-wrap: balance;
}

.done-headline span {
  display: block;
}

.done-headline .done-line-2 {
  color: var(--accent);
}

.book-title.done-booked {
  margin: 0 0 12px;
  font-size: clamp(1.5rem, 5.5vw, 2rem);
}

/* The success screen is wider than the booking steps, so the headline can be big. */
.book.book-done {
  max-width: 960px;
}

.book-done .done p {
  max-width: 60ch;
}

@media (max-width: 520px) {
  .book-now {
    padding: 16px 48px;
  }
  .panel {
    padding: 16px;
  }
}

html[data-motion='off'] {
  scroll-behavior: auto;
}

/* The "0/500" under the notes box. Quiet until the person is close to the limit. */
.counter {
  margin: 4px 0 0;
  text-align: right;
  font-size: 0.85rem;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}

.counter-near {
  color: var(--danger);
  font-weight: 600;
}

/* ---------- Logo coin spin (the logo in the home page's top bar) ----------
   Stands still for 2.5 s, then turns around its upright middle line like a coin spinning on a table: two full
   turns over 3 s, a little quicker at first and slowing down, then it is standing straight again. Repeats forever.
   Nothing about the letters changes. Only the whole logo is turned.
   To change it: the 5.5s (whole cycle = standing still + spinning) and the 45.45% (the share of the cycle spent
   standing still: 2.5 / 5.5) below. The spin lasts the rest, 3 s. 720deg is two turns; 360deg is one. */
.brand .logo {
  perspective: 700px; /* gives the turn some depth: the near edge looks bigger as it comes round */
}

.logo-coin {
  display: block;
  position: relative;
  height: 100%;
  transform-style: preserve-3d;
  animation: logo-coin 5.5s infinite;
}

.logo-face {
  display: block;
  height: 100%;
  -webkit-backface-visibility: hidden;
  backface-visibility: hidden;
}

/* The back face sits on top of the front one, turned around, so it shows when the coin is turned. */
.logo-face-back {
  position: absolute;
  inset: 0;
  transform: rotateY(180deg);
}

@keyframes logo-coin {
  0%,
  45.45% {
    transform: rotateY(0deg);
    animation-timing-function: cubic-bezier(0.3, 0.45, 0.3, 1); /* gentle start, slow settle */
  }
  100% {
    transform: rotateY(720deg);
  }
}

/* Motion off in the menu (which starts from the visitor's system setting): the logo just stays still. */
html[data-motion='off'] .logo-coin {
  animation: none;
}

/* The logo checkerboard behind the booking success screen. */
.book-done {
  position: relative;
}

.logo-checker {
  position: fixed;
  inset: 0;
  z-index: 0;
  pointer-events: none;
  opacity: 0.1;
}

.logo-checker path {
  fill: var(--accent);
}

.book-done .done {
  position: relative;
  z-index: 1;
}

/* "How would you like to pay?" on the booking form. */
.pay-choice {
  margin: 0 0 16px;
  padding: 0;
  border: 0;
}

.pay-choice legend {
  margin-bottom: 8px;
  padding: 0;
  font-weight: 600;
}

.pay-option {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 8px;
  padding: 12px 14px;
  min-height: 52px;
  cursor: pointer;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
}

.pay-option:has(input:checked) {
  border-color: var(--accent);
}

.pay-option input {
  flex: none;
  width: 22px;
  height: 22px;
  margin: 2px 0 0;
  accent-color: var(--accent);
}

.pay-option strong,
.pay-option .hint {
  display: block;
}
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"d58417bba48d2008ab59bc2b82ba593644c864cbc1e5f09b884d6b470f730d71\", \"new\": 0}, {\"path\": \"backend/app/core/errors.py\", \"base\": \"bfb7e074316962b28d07e5570edeaaa2973c7f84d0625924879007ed53acbd41\", \"new\": 1}, {\"path\": \"backend/app/database/bookings.py\", \"base\": \"fbb069007bbbbbb3e9ad674eb3ba4657f4eb3bd03eb6ff81bbc0dfed397088b9\", \"new\": 2}, {\"path\": \"backend/app/database/keys.py\", \"base\": \"d4241ecfb4c1fa704942ec68754fea1bd7667da1fd1de6d8bedd4d3757aba66e\", \"new\": 3}, {\"path\": \"backend/app/domain/models.py\", \"base\": \"2f136759a801fb0f1d5e3a2f16e606c97b027eabdd8366fcdc6dcb4ccfc4e708\", \"new\": 4}, {\"path\": \"backend/app/emailing/templates.py\", \"base\": \"5b3eb351ef2368d8e513bae6356726d1b063de9d26efaab919441059cbfdf42d\", \"new\": 5}, {\"path\": \"backend/app/handler.py\", \"base\": \"91782bdfa9027961033d38cdc13fdd26b7ac2c1546d1e8266a5c9acccdc8b5c7\", \"new\": 6}, {\"path\": \"backend/app/payments/__init__.py\", \"base\": null, \"new\": 7}, {\"path\": \"backend/app/payments/stripe.py\", \"base\": null, \"new\": 8}, {\"path\": \"backend/app/payments/webhook.py\", \"base\": null, \"new\": 9}, {\"path\": \"backend/app/routes/public.py\", \"base\": \"91b68cca617e1ce8ff99f8868b1a2a51e78cd2fd905a49c22018cb55d3b73f30\", \"new\": 10}, {\"path\": \"backend/app/schemas/requests.py\", \"base\": \"40f64f1006d81096af0db1b7f7fa80cf14e82e597ad8b0302fd1a13c956e24e4\", \"new\": 11}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"7cac20dffc8a9e65b893a363f2c451935eb5ee6fa0aa0cb44285fb4b861242b7\", \"new\": 12}, {\"path\": \"backend/app/services/payments.py\", \"base\": null, \"new\": 13}, {\"path\": \"backend/app/services/reminders.py\", \"base\": \"b78554c336811015deedf34a9c5e51b66223b635643b77429424ea6a8069efe6\", \"new\": 14}, {\"path\": \"backend/app/texting/templates.py\", \"base\": \"71a18c42845a00f8080e1bcf30ea7a0d261665a4b5bade3aaf2e9c57def3b190\", \"new\": 15}, {\"path\": \"backend/tests/conftest.py\", \"base\": \"2f1ac8d9f12b64a4b491a50ac393526b145fe9b4e1453d45fa9fa897afcced22\", \"new\": 16}, {\"path\": \"backend/tests/fixtures/stripe.py\", \"base\": null, \"new\": 17}, {\"path\": \"backend/tests/test_payments.py\", \"base\": null, \"new\": 18}, {\"path\": \"backend/tests/test_reminders.py\", \"base\": \"c712cd277fc09ad71c8c9b23e94df9cbc649acd85e8bf86d0136f0b0972a361c\", \"new\": 19}, {\"path\": \"backend/tests/test_settings.py\", \"base\": \"0e652e1244b436548f2fec2059a23430dd08b1afc2385b48cebf04216d4696eb\", \"new\": 20}, {\"path\": \"backend/tests/test_structure.py\", \"base\": \"2a02bf695933ad561d044118c04b54fcd43a52601a5df0646a81af9b42d1e798\", \"new\": 21}, {\"path\": \"frontend/src/admin/Schedule.jsx\", \"base\": \"8a91e96104e327737fdfeecc0dbdeb9494c77075ac698f719b5183f577b41973\", \"new\": 22}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"300b9476f5d1cabb1dacdc70c26c1be1797289cc2fdd1e16ff75aa3ebd493c96\", \"new\": 23}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"9afdade95cb2d4e8eb2eae33ea02d83d315bb5f8785550a30ce9c69310912d91\", \"new\": 24}, {\"path\": \"frontend/src/admin/notify.js\", \"base\": \"98f6f1a553d9348a306ea1752dc0845c6db49fa235d04bf0564ed15a11400344\", \"new\": 25}, {\"path\": \"frontend/src/admin/notify.test.js\", \"base\": \"3c69a36ee350a350b6ae59ce3793d75648d2377bfce94760f034562282db52da\", \"new\": 26}, {\"path\": \"frontend/src/lib/errors.js\", \"base\": \"45419955d71ab4e9ee5c71d3a5374cb3585a3c4b5d09e9d8a893b1671a827ced\", \"new\": 27}, {\"path\": \"frontend/src/lib/mockApi.js\", \"base\": \"ff8c8f35dffde8ed7db6023eecf3cb901bb3c8c94e5cde607c982376d66a3f82\", \"new\": 28}, {\"path\": \"frontend/src/lib/paymentReturn.js\", \"base\": null, \"new\": 29}, {\"path\": \"frontend/src/lib/paymentReturn.test.js\", \"base\": null, \"new\": 30}, {\"path\": \"frontend/src/lib/realApi.js\", \"base\": \"c78c76a065fadc3eeec389737698a650a1ddd378385aa3f37a19591feb091548\", \"new\": 31}, {\"path\": \"frontend/src/lib/realApi.test.js\", \"base\": \"8f2b4d59061693d25a2ae873013ed9fb2e275484d6214c1286161258817ec6da\", \"new\": 32}, {\"path\": \"frontend/src/lib/shopSettings.js\", \"base\": \"674b83c583a3b7254e84935bc1b15391cd4d4a80628c55a040d806e92e824951\", \"new\": 33}, {\"path\": \"frontend/src/lib/shopSettings.test.js\", \"base\": \"84feaaf37a20a44c938dff2fef7df89c24269adbdc5eb2e46457d1c479017bbe\", \"new\": 34}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"4b4cdfd97b86e8c2c767a55520d7a1934cc364dc10f73e84854629cd7814b7e3\", \"new\": 35}, {\"path\": \"frontend/src/styles.css\", \"base\": \"1ffc9d1a9905ec9d31bdf048ba5983f77ac356a9554cd4a9b780b28240f7a673\", \"new\": 36}]")

def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()

plan, problems = [], []
for m in MANIFEST:
    path = Path(m["path"])
    new = (stage / str(m["new"])).read_bytes() if m["new"] is not None else None
    current = path.read_bytes() if path.exists() else None
    if current == new:
        continue  # already in its final state
    if current is not None and m["base"] is not None and sha(current) != m["base"]:
        problems.append(str(path))  # edited since this script was built
    elif current is not None and m["base"] is None:
        problems.append(str(path) + " (already exists with different content)")
    elif current is None and m["base"] is not None and new is not None:
        problems.append(str(path) + " (missing)")
    plan.append((path, new))

if problems and not force:
    print("Stopped. These files are not the versions this script was built for, so NOTHING was changed:")
    for p in problems: print("  -", p)
    print("Tell me what differs (or run with FORCE=1 to overwrite them anyway).")
    sys.exit(1)

if not plan:
    print("Already up to date. Nothing to change.")
    sys.exit(0)
for path, new in plan:
    if new is None:
        if path.exists(): path.unlink()
        print("  removed", path)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(new)
        print("  wrote  ", path)
print(f"Done. {len(plan)} file(s) changed.")
PY
echo
echo "Then: git add -A && git commit, push. Pay-online stays hidden until the two Stripe secrets are in SSM (see backend/README.md > Paying online)."
