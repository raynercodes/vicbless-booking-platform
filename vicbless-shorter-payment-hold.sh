#!/usr/bin/env bash
# Shorter payment hold (10 minutes)
# Run from the REPO ROOT:  bash vicbless-shorter-payment-hold.sh
#
# Holds a time for 10 minutes (not 30) while a customer pays online. Stripe cannot make a payment page expire
# in under 30 minutes, so the hold ends on our side: the page is closed and the time freed the moment anyone looks at the
# times or books, and on the 15 minute sweep.
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
before then). The booking is made at once and its time is **held for 10 minutes** (`payment = pending`, `HOLD_MINUTES` in `services/payments.py`) while they pay on
Stripe's page. Nobody is told about it yet. Stripe's signed message to `/api/stripe/webhook` then either confirms it
(`paid`: Vic and the customer are told, and Vic sees "Paid online" on the card) or says the page ran out (the time is freed).
Stripe will not let a payment page live under 30 minutes, so when the hold ends WE close the page on Stripe's side and free
the time, the moment anyone looks at the times or books (and on the 15 minute sweep as a backstop). Stripe is asked first, so
a payment that did go through is confirmed instead of lost. A booking Vic cancels after it was paid is **refunded in full first**; if the refund fails nothing
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
    payments_service.release_expired_quietly(shop.now_local())  # a time whose payment ran out is free from that minute on
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
    payments_service.release_expired_quietly(now)  # someone else's payment may have just run out, which frees this time

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
cat > "$STAGE/2" <<'VICBLESS_EOF'
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

# How long a customer's time is held while they pay. Short on purpose: a customer who wanders off must not keep a
# time from someone who would book it. Stripe will not make a payment page expire in under 30 minutes, so when the hold
# ends WE close the page (release below) instead of waiting for Stripe's own expiry.
HOLD_MINUTES = 10
STRIPE_MIN_PAGE_MINUTES = 31  # the shortest life Stripe allows for a payment page is 30 minutes


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
        expires = datetime.now(timezone.utc) + timedelta(minutes=STRIPE_MIN_PAGE_MINUTES)  # Stripe checks the real clock
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
    """Gives back the time of every unpaid booking whose hold has ended. Returns how many.

    Runs on the 15 minute schedule, and also whenever anyone looks at the times or books one, so a time is free again
    the minute its hold ends, not up to 15 minutes later. Each is closed on Stripe's side first, and if Stripe says it was
    paid after all, it is confirmed instead of released.
    """
    freed = 0
    for booking_id, until in bookings_db.holds_ending_before(iso_utc(now)):
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


def release_expired_quietly(now: datetime) -> None:
    """release_expired for callers that must never fail because of it (the booking page's time grid)."""
    try:
        release_expired(now)
    except Exception as exc:  # noqa: BLE001
        log("hold_sweep_error", reason=type(exc).__name__)
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
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
    later = NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1)
    assert payments_service.release_expired(later) == 1
    assert busy(client) == [] and holds() == [] and the_session(stripe)["status"] == "expired"


def test_the_sweep_leaves_a_hold_that_has_not_ended(client, stripe):
    online(client)
    assert payments_service.release_expired(NOW + timedelta(minutes=payments_service.HOLD_MINUTES - 1)) == 0
    assert busy(client) == [720]


def test_the_hold_is_short_and_stripes_page_is_closed_by_us_when_it_ends(client, stripe):
    assert payments_service.HOLD_MINUTES == 10
    online(client)
    expires_at = int(stripe.calls[0][2]["expires_at"])
    assert expires_at - time.time() >= 30 * 60  # Stripe will not take a payment page that lives less than 30 minutes
    payments_service.release_expired(NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1))
    assert the_session(stripe)["status"] == "expired"  # ...so we closed it ourselves, well before then


def test_looking_at_the_times_frees_a_hold_that_ran_out(client, stripe, monkeypatch):
    online(client)
    assert busy(client) == [720]  # held while they pay
    monkeypatch.setattr("app.domain.shop.now_local", lambda: NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1))
    assert busy(client) == [] and holds() == [] and the_session(stripe)["status"] == "expired"


def test_booking_a_time_whose_hold_just_ran_out_works(client, stripe, monkeypatch):
    online(client)
    later = NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1)
    monkeypatch.setattr("app.domain.shop.now_local", lambda: later)
    r = book(client, name="Someone Else", phone="(555) 010-7777")
    assert r.status_code == 201 and r.json()["payment"] == "shop"


def test_a_customer_who_paid_just_as_the_hold_ended_keeps_the_time(client, auth, stripe, monkeypatch):
    online(client)
    stripe.pay("cs_test_1")  # paid, and the message has not arrived yet
    monkeypatch.setattr("app.domain.shop.now_local", lambda: NOW + timedelta(minutes=payments_service.HOLD_MINUTES + 1))
    assert busy(client) == [720]  # still theirs
    assert schedule_of(client, auth)["items"][0]["payment"] == "paid"


def test_the_time_grid_still_loads_if_the_sweep_fails(client, stripe, monkeypatch):
    def broken(*a, **k):
        raise RuntimeError("boom")

    monkeypatch.setattr("app.database.bookings.holds_ending_before", broken)
    assert busy(client) == []


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
cat > "$STAGE/4" <<'VICBLESS_EOF'
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
      ? "Your payment wasn't completed. Your time is only held for 10 minutes, so pay now or choose to pay at the shop."
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
                      Secure card payment with Stripe. Your time is held for 10 minutes while you pay.
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
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"ea69b75d90bf11a506d3f8a29e68d1f732464a52d3941332a6cf1bec874b1481\", \"new\": 0}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"a517f89559563045eecbb30254bf575a76b0e583ac711e3cfe44c9279bb6968b\", \"new\": 1}, {\"path\": \"backend/app/services/payments.py\", \"base\": \"336eaa57a80ccfd3e215166f7342aa102c971f83a98242b24013fea557fd89a4\", \"new\": 2}, {\"path\": \"backend/tests/test_payments.py\", \"base\": \"9fb450db7926efc5ecaf1266e46ec8574502713f93de4457ce7800344d061119\", \"new\": 3}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"fcc19ec559cc37a25b1ae0a6d3e3fce7643f6b8768ff4937f78d64baa9ee0198\", \"new\": 4}]")

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
echo "Then: git add -A && git commit, push. Needs the Stripe installer applied first."
