#!/usr/bin/env bash
# Vicbless: Sales log page in the dashboard, and a tidier After hours label on the booking summary
# Run from the REPO ROOT:  bash vicbless-sales-log.sh
#
# Adds a Sales log tab to Vic's dashboard: a quick form (service, listed or custom price, paid online or at the shop,
# client's name), a spreadsheet of every client with search, filters and sorting, the numbers for what is shown,
# and a download for Excel. Backend: GET/POST /api/admin/sales and DELETE /api/admin/sales/{id}.
# Also gives the After hours label on the booking summary its own line.
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

## Sales log

Vic keeps a hand-made log of the clients he serves (Sales log tab of his dashboard): which service, the listed price or a custom one, whether they paid online or at the shop, the client's name, an optional note and the day (today unless he changes it). It is separate from online bookings and does not change the schedule.

- `GET /api/admin/sales` lists the whole log, newest first. `POST /api/admin/sales` adds a line. `DELETE /api/admin/sales/{id}` removes one (for a mistake). All need Vic's sign-in.
- A listed price is read from his settings on the server (After Hours Cuts included), never trusted from the screen. A one-off service (typed name) needs a typed price. A sale can't be dated in the future or more than a year back.
- Lines are stored as `SALE#<day>#<id>` in the same table, with no expiry, so the log is a permanent record (bookings disappear after 90 days). Search, filters, sorting, the numbers and the Excel download all happen in the dashboard from the list this returns.

## After Hours Cuts

Late appointments after the shop closes, sold as one service (`after-hours`, "After Hours Cuts", $70 to start). It is separate from the services Vic lists: it can only be booked at the after-hours times, and those times can only be booked with it (the API refuses any other pairing, for customers and when Vic moves a booking).

- The late times start at the day's closing time and run back to back, each as long as that day's appointment length. Thursday and Friday start with 2 each. Vic changes the price, the description and the number per weekday (0 to 6) in Menu > Settings > Shop settings > After Hours Cuts. Closed days never have any.
- Blocking a whole day off also blocks its late times, and Vic can block just the late times.
- The Stripe payment page shows the date, the time and the service note under the service name, for every service.
- Settings are stored in the same settings item (`afterHours`: price, note, slots per weekday). Nothing needs migrating: a settings item saved before this existed simply starts from the defaults.

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
"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 5 minute unit (a 45 minute booking holds nine)
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
    HOLD#<until, ISO UTC>#<booking id>    an unpaid online booking whose time is held until <until> (a sweep finds the
                                          old ones; "HOLD#" sorts after every date, so a day's range never includes it)
    SALE#<day>#<sale id>                  one line of Vic's sales log. Like HOLD# it sorts after every date, and it never
                                          expires (the log is his record, unlike bookings that disappear after 90 days)
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


def sale_sk(day: date, sale_id: str) -> str:
    return f"SALE#{day.isoformat()}#{sale_id}"


def block_sk(day: date, start: int, block_id: str) -> str:
    return f"{day.isoformat()}#BLOCK#{shop.hhmm(start)}#{block_id}"


def minutes_of(hhmm: str) -> int:
    """'1235' -> 755 minutes after midnight (the reverse of shop.hhmm)."""
    return int(hhmm[:2]) * 60 + int(hhmm[2:])
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
"""Vic's sales log in the database: add a line, list them all, remove one."""

from __future__ import annotations

from datetime import date

from ..core.errors import NotFound
from ..domain.sales import Sale, parse_sale_id
from . import keys, table
from .keys import PK
from .schedule import query_range


def sale_from(item: dict) -> Sale:
    return Sale(
        id=item["id"],
        day=date.fromisoformat(item["date"]),
        service_id=item.get("serviceId", ""),
        service_name=item.get("serviceName", ""),
        amount_cents=int(item["amountCents"]),
        custom_price=bool(item.get("customPrice", False)),
        payment=item.get("payment", "shop"),
        client_name=item.get("clientName", ""),
        note=item.get("note", ""),
        created_at=item.get("createdAt", ""),
    )


def add(sale: Sale) -> Sale:
    table.table().put_item(
        Item={
            "pk": PK,
            "sk": keys.sale_sk(sale.day, sale.id),
            "kind": "sale",
            "id": sale.id,
            "date": sale.day.isoformat(),
            "serviceId": sale.service_id,
            "serviceName": sale.service_name,
            "amountCents": sale.amount_cents,
            "customPrice": sale.custom_price,
            "payment": sale.payment,
            "clientName": sale.client_name,
            "note": sale.note,
            "createdAt": sale.created_at,
        },
        ConditionExpression="attribute_not_exists(pk)",
    )
    return sale


def list_all() -> list[Sale]:
    """Every line of the log, newest first (by day, then by when it was logged)."""
    sales = [sale_from(item) for item in query_range("SALE#", "SALE#~")]
    sales.sort(key=lambda s: (s.day, s.created_at), reverse=True)
    return sales


def remove(sale_id: str) -> Sale:
    day = parse_sale_id(sale_id)
    if day is None:
        raise NotFound("That sale was not found. It may already be removed.")
    key = {"pk": PK, "sk": keys.sale_sk(day, sale_id)}
    gone = table.table().delete_item(Key=key, ReturnValues="ALL_OLD").get("Attributes")
    if not gone:
        raise NotFound("That sale was not found. It may already be removed.")
    return sale_from(gone)
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Vic's sales log: one line per client he served, kept by hand in the dashboard (separate from online bookings).

Pure data and rules, nothing here touches AWS.
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass
from datetime import date

PAYMENTS = ("shop", "online")  # how the client paid: at the shop, or online
MAX_SALE_CENTS = 999_999  # $9,999.99, a typo guard more than a business limit
ID_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})\.sale\.[0-9a-f]{8}$")


def new_sale_id(day: date) -> str:
    """'2026-10-22.sale.9f3a1c2b'. The date is inside it, so removing a line is a direct lookup."""
    return f"{day.isoformat()}.sale.{secrets.token_hex(4)}"


def parse_sale_id(value: str) -> date | None:
    """The date inside a sale id, or None if the id is not one we could have made."""
    m = ID_PATTERN.match(value or "")
    if not m:
        return None
    try:
        return date.fromisoformat(m.group(1))
    except ValueError:
        return None


@dataclass(frozen=True)
class Sale:
    id: str
    day: date
    service_id: str  # "" for a one-off service Vic typed in
    service_name: str
    amount_cents: int
    custom_price: bool  # True when Vic typed the price instead of using the service's listed one
    payment: str  # "shop" or "online"
    client_name: str
    note: str
    created_at: str  # when it was logged (ISO, UTC)

    def admin_view(self) -> dict:
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "serviceId": self.service_id,
            "serviceName": self.service_name,
            "amountCents": self.amount_cents,
            "customPrice": self.custom_price,
            "payment": self.payment,
            "clientName": self.client_name,
            "note": self.note,
            "createdAt": self.created_at,
        }
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""Vic's routes (mounted under /api/admin).

Two routers on purpose:
  login_router  open to everyone, because it is how Vic gets a token in the first place
  router        every route on it requires a valid session. The check is attached to the router, so a
                new admin route can't be added here and accidentally left open.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse

from ..domain import shop
from ..schemas.requests import BlockIn, LoginIn, MoveIn, SaleIn, SettingsIn, date_from_query
from ..services import auth, blocks, bookings, notifications
from ..services import sales as sales_service
from ..services import schedule as schedule_service
from ..services import settings as settings_service
from .deps import require_admin, source_address

login_router = APIRouter()
router = APIRouter(dependencies=[Depends(require_admin)])


@login_router.post("/login")
def login(body: LoginIn, request: Request) -> dict:
    """Password in, session token out (valid 12 hours)."""
    return auth.login(body.password, source_address(request))


@router.get("/schedule")
def schedule(date: str = Query()) -> dict:
    """One day for the dashboard: bookings with contact details, and blocked-off times."""
    return schedule_service.day_for_admin(date_from_query(date))


@router.delete("/bookings/{booking_id}")
def cancel_booking(booking_id: str) -> dict:
    """Cancels a booking, frees its time, and emails the customer if they left an email."""
    booking = bookings.cancel_booking(booking_id)
    notifications.booking_cancelled(booking)
    return {"cancelled": True}


@router.patch("/bookings/{booking_id}")
def move_booking(booking_id: str, body: MoveIn) -> dict:
    """Moves a booking to another open time (any day up to a year ahead), and emails the customer if they left an email.

    The answer is the booking in its new place. It has a NEW id, because the id contains the day and time.
    """
    before, after = bookings.move_booking(booking_id, body, shop.now_local())
    notifications.booking_moved(before, after)
    return after.admin_view()


@router.get("/settings")
def get_settings() -> dict:
    """Vic's settings as he last saved them (or the shop's defaults), read fresh from the database."""
    settings_service.reset_cache()
    return settings_service.to_view(settings_service.current())


@router.put("/settings")
def put_settings(body: SettingsIn) -> dict:
    """Saves the services and appointment lengths. Takes effect for new bookings at once; existing ones keep their times."""
    return settings_service.to_view(settings_service.save(body))


@router.post("/blocks")
def add_block(body: BlockIn) -> JSONResponse:
    """Blocks off part of a day, or the whole day (customers then see "Closed")."""
    block = blocks.add_block(body, shop.now_local())
    return JSONResponse(status_code=201, content=block.admin_view())


@router.delete("/blocks/{block_id}")
def remove_block(block_id: str) -> dict:
    """Opens blocked-off time back up."""
    blocks.remove_block(block_id)
    return {"removed": True}


@router.get("/sales")
def list_sales() -> dict:
    """Vic's whole sales log, newest first. The dashboard filters, sorts and adds it up."""
    return {"sales": [s.admin_view() for s in sales_service.list_sales()]}


@router.post("/sales")
def add_sale(body: SaleIn) -> JSONResponse:
    """Logs a sale Vic entered by hand."""
    sale = sales_service.add_sale(body, shop.now_local())
    return JSONResponse(status_code=201, content=sale.admin_view())


@router.delete("/sales/{sale_id}")
def remove_sale(sale_id: str) -> dict:
    """Removes a line of the log (for a mistake)."""
    sales_service.remove_sale(sale_id)
    return {"removed": True}
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
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
MSG_AFTER_SLOTS = f"Pick 0 to {shop.MAX_AFTER_SLOTS} after-hours appointments for every day of the week."
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


SALE_NAME_MAX = 60
SALE_NOTE_MAX = 120
MSG_SALE_CLIENT = f"Enter the client's name, up to {SALE_NAME_MAX} characters."
MSG_SALE_SERVICE = "Pick a service, or type the name of a one-off service."
MSG_SALE_AMOUNT = "Enter the price as dollars, from $0 to $9,999.99."
MSG_SALE_NOTE = f"A note can be up to {SALE_NOTE_MAX} characters."


class SaleIn(BaseModel):
    """Vic logging a sale by hand (POST /api/admin/sales)."""

    model_config = ConfigDict(extra="ignore")

    serviceId: str | None = None  # one of his services (or After Hours Cuts); left out for a one-off service
    serviceName: str | None = None  # the name of a one-off service
    priceMode: Literal["standard", "custom"] = "standard"  # the service's listed price, or one Vic typed
    amountCents: StrictInt | None = None  # needed for a custom price
    payment: Literal["shop", "online"] = "shop"
    clientName: str
    note: str | None = None
    dateKey: str | None = None  # the day it happened; left out = today

    @field_validator("serviceId")
    @classmethod
    def _service_id(cls, v: str | None) -> str | None:
        if v in (None, ""):
            return None
        if not SERVICE_ID_PATTERN.match(v):
            raise ValueError(MSG_SALE_SERVICE)
        return v

    @field_validator("serviceName")
    @classmethod
    def _service_name(cls, v: str | None) -> str:
        v = one_line(v or "")
        if len(v) > SERVICE_NAME_MAX:
            raise ValueError(MSG_SALE_SERVICE)
        return v

    @field_validator("amountCents")
    @classmethod
    def _amount(cls, v: int | None) -> int | None:
        if v is not None and not 0 <= v <= 999_999:
            raise ValueError(MSG_SALE_AMOUNT)
        return v

    @field_validator("clientName")
    @classmethod
    def _client(cls, v: str) -> str:
        v = one_line(v)
        if not 1 <= len(v) <= SALE_NAME_MAX:
            raise ValueError(MSG_SALE_CLIENT)
        return v

    @field_validator("note")
    @classmethod
    def _note(cls, v: str | None) -> str:
        v = one_line(v or "")
        if len(v) > SALE_NOTE_MAX:
            raise ValueError(MSG_SALE_NOTE)
        return v

    @field_validator("dateKey")
    @classmethod
    def _date(cls, v: str | None) -> str | None:
        if v in (None, ""):
            return None
        parse_date_key(v)
        return v


class AfterHoursIn(BaseModel):
    """Vic's After Hours Cuts settings: its price and description, and how many late appointments each weekday has."""

    model_config = ConfigDict(extra="ignore")

    price: StrictInt
    note: str | None = None
    slots: dict[str, StrictInt]  # {"mon": 0, ... "thu": 2, ...}

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

    @field_validator("slots")
    @classmethod
    def _slots(cls, v: dict[str, int]) -> dict[str, int]:
        if set(v) != set(shop.WEEKDAY_KEYS) or any(not 0 <= n <= shop.MAX_AFTER_SLOTS for n in v.values()):
            raise ValueError(MSG_AFTER_SLOTS)
        return v


class SettingsIn(BaseModel):
    """Vic saving his settings (PUT /api/admin/settings): the whole list of services, and an appointment length per day."""

    model_config = ConfigDict(extra="ignore")

    services: list[ServiceIn]
    slotMinutes: dict[str, StrictInt]  # {"mon": 45, "tue": 45, ...} every weekday, in minutes
    afterHours: AfterHoursIn | None = None  # After Hours Cuts; left out = keep what is saved
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
cat > "$STAGE/6" <<'VICBLESS_EOF'
"""Vic's sales log in action: log a sale, list them, remove one."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from ..core.errors import ValidationFailed
from ..core.logs import log
from ..database import sales as sales_db
from ..domain import shop
from ..domain.sales import Sale, new_sale_id
from ..schemas.requests import MSG_SALE_AMOUNT, MSG_SALE_SERVICE, SaleIn, parse_date_key
from . import settings as settings_service

MAX_DAYS_BACK = 366  # a sale can be logged for any day in the last year


def add_sale(data: SaleIn, now: datetime) -> Sale:
    """Turns what Vic picked into a line of the log. The listed price is read from his settings here, never trusted
    from the screen, and a sale can't be dated in the future."""
    today = shop.today(now)
    day = parse_date_key(data.dateKey) if data.dateKey else today
    if day > today:
        raise ValidationFailed("A sale can't be dated in the future.", field="dateKey")
    if day < today - timedelta(days=MAX_DAYS_BACK):
        raise ValidationFailed("A sale can be logged for any day in the last year.", field="dateKey")

    service = settings_service.current().service(data.serviceId) if data.serviceId else None
    if data.serviceId and service is None:  # Vic may have removed it since the screen loaded
        raise ValidationFailed(MSG_SALE_SERVICE, field="serviceId")
    name = service.name if service else data.serviceName
    if not name:
        raise ValidationFailed(MSG_SALE_SERVICE, field="serviceName")

    custom = data.priceMode == "custom"
    if custom:
        if data.amountCents is None:
            raise ValidationFailed(MSG_SALE_AMOUNT, field="amountCents")
        amount = data.amountCents
    else:
        if service is None:
            raise ValidationFailed("A one-off service has no listed price. Type the price.", field="amountCents")
        amount = service.price * 100

    sale = sales_db.add(
        Sale(
            id=new_sale_id(day),
            day=day,
            service_id=service.id if service else "",
            service_name=name,
            amount_cents=amount,
            custom_price=custom,
            payment=data.payment,
            client_name=data.clientName,
            note=data.note or "",
            created_at=now.astimezone(timezone.utc).isoformat(timespec="seconds"),
        )
    )
    log("sale_logged", saleId=sale.id, amountCents=amount, payment=sale.payment, custom=custom)
    return sale


def list_sales() -> list[Sale]:
    return sales_db.list_all()


def remove_sale(sale_id: str) -> Sale:
    sale = sales_db.remove(sale_id)
    log("sale_removed", saleId=sale.id)
    return sale
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
"""Vic's sales log: lines he adds by hand in the dashboard, listed back for his spreadsheet page."""

import pytest

from app.domain.sales import new_sale_id, parse_sale_id
from tests.helpers.constants import MONDAY, NOW, TUESDAY
from datetime import date

TODAY = MONDAY  # the tests pretend it is Monday 12 Oct 2026


def sale_body(**over) -> dict:
    body = {"serviceId": "mens-cut", "priceMode": "standard", "payment": "shop", "clientName": "Marcus Jones"}
    body.update(over)
    return body


def add(client, auth, **over):
    return client.post("/api/admin/sales", headers=auth, json=sale_body(**over))


def log_of(client, auth) -> list[dict]:
    r = client.get("/api/admin/sales", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()["sales"]


def test_the_log_starts_empty(client, auth):
    assert log_of(client, auth) == []


def test_a_standard_sale_uses_the_listed_price(client, auth):
    r = add(client, auth)
    assert r.status_code == 201, r.text
    [row] = log_of(client, auth)
    assert row["clientName"] == "Marcus Jones" and row["serviceName"] == "Men's haircut" and row["serviceId"] == "mens-cut"
    assert row["amountCents"] == 5500 and row["customPrice"] is False and row["payment"] == "shop"
    assert row["dateKey"] == TODAY and row["id"] == r.json()["id"] and row["createdAt"].startswith("2026-10-12")


def test_after_hours_cuts_can_be_logged_at_its_price(client, auth):
    add(client, auth, serviceId="after-hours", payment="online")
    [row] = log_of(client, auth)
    assert row["serviceName"] == "After Hours Cuts" and row["amountCents"] == 7000 and row["payment"] == "online"


def test_a_custom_price_is_kept_as_typed(client, auth):
    add(client, auth, priceMode="custom", amountCents=6250)
    [row] = log_of(client, auth)
    assert row["amountCents"] == 6250 and row["customPrice"] is True and row["serviceName"] == "Men's haircut"


def test_a_one_off_service_needs_a_typed_price(client, auth):
    assert add(client, auth, serviceId=None, serviceName="Line up only").status_code == 422  # no listed price
    r = add(client, auth, serviceId=None, serviceName="Line up only", priceMode="custom", amountCents=1500)
    assert r.status_code == 201
    [row] = log_of(client, auth)
    assert row["serviceId"] == "" and row["serviceName"] == "Line up only" and row["amountCents"] == 1500


def test_the_screens_own_price_and_name_are_not_trusted(client, auth):
    add(client, auth, serviceName="Something else", amountCents=1)  # a standard sale ignores both
    [row] = log_of(client, auth)
    assert row["serviceName"] == "Men's haircut" and row["amountCents"] == 5500


@pytest.mark.parametrize(
    "bad",
    [
        {"serviceId": "nope"},  # not one of his services
        {"serviceId": None, "serviceName": ""},  # no service at all
        {"priceMode": "custom"},  # no price typed
        {"priceMode": "custom", "amountCents": -1},
        {"priceMode": "custom", "amountCents": 1_000_000},
        {"clientName": ""},
        {"clientName": "x" * 61},
        {"payment": "cash"},
        {"note": "x" * 121},
        {"dateKey": "2026-10-13"},  # tomorrow
        {"dateKey": "2025-10-01"},  # over a year back
        {"dateKey": "not-a-date"},
    ],
)
def test_bad_entries_are_refused(client, auth, bad):
    assert add(client, auth, **bad).status_code == 422
    assert log_of(client, auth) == []


def test_a_sale_can_be_dated_earlier(client, auth):
    add(client, auth, dateKey="2026-10-09", note="walk-in")
    [row] = log_of(client, auth)
    assert row["dateKey"] == "2026-10-09" and row["note"] == "walk-in"


def test_the_log_lists_newest_day_first(client, auth):
    add(client, auth, clientName="Older", dateKey="2026-10-01")
    add(client, auth, clientName="Newest", dateKey=TODAY)
    add(client, auth, clientName="Middle", dateKey="2026-10-08")
    assert [r["clientName"] for r in log_of(client, auth)] == ["Newest", "Middle", "Older"]


def test_a_sale_is_removed_by_its_id(client, auth):
    first = add(client, auth, clientName="Keep").json()
    gone = add(client, auth, clientName="Remove").json()
    r = client.delete(f"/api/admin/sales/{gone['id']}", headers=auth)
    assert r.status_code == 200
    assert [x["id"] for x in log_of(client, auth)] == [first["id"]]
    assert client.delete(f"/api/admin/sales/{gone['id']}", headers=auth).status_code == 404  # already gone
    assert client.delete("/api/admin/sales/not-an-id", headers=auth).status_code == 404


def test_the_log_does_not_disturb_the_schedule(client, auth):
    add(client, auth)
    day = client.get(f"/api/admin/schedule?date={TODAY}", headers=auth).json()
    assert day["items"] == [] and day["blocks"] == []
    assert client.get(f"/api/availability?from={TODAY}&to={TODAY}").json()[TODAY]["busy"] == []


def test_the_log_needs_sign_in(client, admin_setup):
    assert client.get("/api/admin/sales").status_code == 401
    assert client.post("/api/admin/sales", json=sale_body()).status_code == 401
    assert client.delete("/api/admin/sales/2026-10-12.sale.abcdef12").status_code == 401


def test_sale_ids_carry_their_day():
    sid = new_sale_id(date(2026, 10, 12))
    assert parse_sale_id(sid) == date(2026, 10, 12)
    assert parse_sale_id("2026-13-45.sale.abcdef12") is None
    assert parse_sale_id("2026-10-12.sale.XYZ") is None
    assert parse_sale_id("") is None


def test_the_log_never_expires(client, auth):
    from tests.helpers.aws import raw_table

    add(client, auth)
    items = raw_table().scan()["Items"]
    sales = [i for i in items if str(i.get("sk", "")).startswith("SALE#")]
    assert len(sales) == 1 and "expiresAt" not in sales[0]
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
import { useEffect, useState } from 'react'
import './admin.css'
import SiteMenu from '../components/SiteMenu.jsx'
import { copyrightLine } from '../lib/format.js'
import Greeting from './Greeting.jsx'
import Schedule from './Schedule.jsx'
import SalesPage from './SalesPage.jsx'
import SettingsPanel from './SettingsPanel.jsx'
import SignIn from './SignIn.jsx'
import LoopingLogo from './LoopingLogo.jsx'
import { pickGreeting } from './greetings.js'
import { API_MODE } from '../lib/mode.js'
import { SIGNED_OUT_EVENT, isSignedIn, signOut } from './adminApi.js'

const LAST_GREETING_KEY = 'vicbless.admin.lastGreeting'

function readLastGreeting() {
  try {
    return localStorage.getItem(LAST_GREETING_KEY) || ''
  } catch {
    return ''
  }
}

export default function Admin() {
  const [signedIn, setSignedIn] = useState(isSignedIn)
  const [view, setView] = useState('schedule') // 'schedule' | 'sales' (the two tabs) | 'settings' (Menu > Settings > Shop settings)

  // One greeting per visit: the sign-in screen and the dashboard show the same one, and the next
  // visit gets a different one.
  const [greeting] = useState(() => pickGreeting({ last: readLastGreeting() }))
  useEffect(() => {
    try {
      localStorage.setItem(LAST_GREETING_KEY, greeting)
    } catch {
      /* storage blocked: the next visit may repeat it, which is harmless */
    }
  }, [greeting])

  // The session ran out (or the API refused it): back to the sign-in screen instead of a dashboard that cannot load.
  useEffect(() => {
    const out = () => setSignedIn(false)
    window.addEventListener(SIGNED_OUT_EVENT, out)
    return () => window.removeEventListener(SIGNED_OUT_EVENT, out)
  }, [])

  // Keep the page out of search results, and give the tab its own title while it is open.
  useEffect(() => {
    const previousTitle = document.title
    document.title = "Vic's dashboard"
    const meta = document.createElement('meta')
    meta.name = 'robots'
    meta.content = 'noindex, nofollow'
    document.head.appendChild(meta)
    return () => {
      document.title = previousTitle
      meta.remove()
    }
  }, [])

  if (!signedIn) return <SignIn greeting={greeting} onSignedIn={() => setSignedIn(true)} />

  return (
    <main className={view === 'sales' ? 'admin admin-wide' : 'admin'}>
      <header className="admin-bar">
        <SiteMenu
          settingsExtra={({ close }) => (
            <button
              type="button"
              className="menu-link"
              onClick={() => {
                setView('settings')
                close()
                window.scrollTo?.({ top: 0 })
              }}
            >
              Shop settings
            </button>
          )}
        >
          <a className="menu-link" href="#/">
            View site
          </a>
          <button
            type="button"
            className="menu-link"
            onClick={() => {
              signOut()
              setSignedIn(false)
            }}
          >
            Sign out
          </button>
        </SiteMenu>
        <LoopingLogo variant="bar" />
        <span aria-hidden="true" />
      </header>

      <Greeting message={greeting} />

      {API_MODE === 'mock' && (
        <p className="admin-preview-note">
          Preview data. Bookings made on the site in this browser show up here, along with sample ones marked "sample". Cancelling and blocking time work too, and are saved in this browser only.
        </p>
      )}

      {view !== 'settings' && (
        <nav className="admin-tabs" aria-label="Dashboard pages">
          {[
            ['schedule', 'Schedule'],
            ['sales', 'Sales log'],
          ].map(([id, label]) => (
            <button key={id} type="button" aria-current={view === id ? 'page' : undefined} onClick={() => setView(id)}>
              {label}
            </button>
          ))}
        </nav>
      )}

      {view === 'settings' ? <SettingsPanel onClose={() => setView('schedule')} /> : view === 'sales' ? <SalesPage /> : <Schedule />}

      <footer className="admin-foot">{copyrightLine()}</footer>
    </main>
  )
}
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { fromKey, keyOf } from '../lib/availability.js'
import {
  NOTE_MAX,
  OTHER,
  PAYMENT_WORDS,
  RANGES,
  blankEntry,
  checkEntry,
  filterSales,
  money,
  saleServices,
  salesMetrics,
  sortSales,
  toCsv,
} from '../lib/sales.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { addSale, getSales, removeSale } from './adminApi.js'

const PAGE = 100 // rows drawn at a time, so a long log stays quick
const COLUMNS = [
  { key: 'date', label: 'Date' },
  { key: 'client', label: 'Client' },
  { key: 'service', label: 'Service' },
  { key: 'amount', label: 'Price', numeric: true },
  { key: 'payment', label: 'Paid' },
]
const SORTS = [
  { id: 'date-desc', label: 'Newest first', key: 'date', dir: 'desc' },
  { id: 'date-asc', label: 'Oldest first', key: 'date', dir: 'asc' },
  { id: 'amount-desc', label: 'Highest sales', key: 'amount', dir: 'desc' },
  { id: 'amount-asc', label: 'Lowest sales', key: 'amount', dir: 'asc' },
  { id: 'client-asc', label: 'Client A to Z', key: 'client', dir: 'asc' },
]

const dayWords = (dateKey) => fromKey(dateKey).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })

// Vic's sales log (the "Sales log" tab of his dashboard): a quick form to log a client, a spreadsheet of every client
// with search, filters and sorting, and the numbers for whatever the spreadsheet is showing.
export default function SalesPage() {
  const shop = useShopSettings()
  const uid = useId()
  const today = keyOf(new Date())
  const services = useMemo(() => saleServices(shop), [shop])

  const [rows, setRows] = useState([])
  const [status, setStatus] = useState('loading') // loading | ready | error
  const [attempt, setAttempt] = useState(0)

  const [form, setForm] = useState(() => blankEntry(shop, today))
  const [errors, setErrors] = useState({})
  const [saving, setSaving] = useState(false)
  const [flash, setFlash] = useState('')
  const [failure, setFailure] = useState('')

  const [query, setQuery] = useState('')
  const [serviceFilter, setServiceFilter] = useState('all')
  const [payment, setPayment] = useState('all')
  const [range, setRange] = useState('all')
  const [sortId, setSortId] = useState('date-desc')
  const [shown, setShown] = useState(PAGE)
  const [confirmId, setConfirmId] = useState(null)

  useEffect(() => {
    let alive = true
    setStatus('loading')
    getSales()
      .then((list) => {
        if (!alive) return
        setRows(list)
        setStatus('ready')
      })
      .catch(() => alive && setStatus('error'))
    return () => {
      alive = false
    }
  }, [attempt])

  useEffect(() => {
    if (!flash) return undefined
    const timer = setTimeout(() => setFlash(''), 6000)
    return () => clearTimeout(timer)
  }, [flash])

  // Back to the first page of rows whenever what is shown changes.
  useEffect(() => setShown(PAGE), [query, serviceFilter, payment, range, sortId])

  const sort = SORTS.find((s) => s.id === sortId) || SORTS[0]
  const filtered = useMemo(() => filterSales(rows, { query, service: serviceFilter, payment, range }, today), [rows, query, serviceFilter, payment, range, today])
  const visible = useMemo(() => sortSales(filtered, sort.key, sort.dir), [filtered, sort])
  const metrics = useMemo(() => salesMetrics(filtered), [filtered])
  const serviceNames = useMemo(() => [...new Set(rows.map((r) => r.serviceName))].sort((a, b) => a.localeCompare(b)), [rows])
  const filtering = query.trim() !== '' || serviceFilter !== 'all' || payment !== 'all' || range !== 'all'

  const picked = services.find((s) => s.id === form.serviceId) || null
  const isOther = form.serviceId === OTHER
  const custom = isOther || form.priceMode === 'custom'
  const edit = (change) => {
    setForm((f) => ({ ...f, ...change }))
    setFlash('')
    setFailure('')
  }

  async function submit(e) {
    e.preventDefault()
    if (saving) return
    const result = checkEntry(form, shop, today)
    setErrors(result.ok ? {} : result.errors)
    if (!result.ok) return
    setSaving(true)
    setFailure('')
    try {
      const row = await addSale(result.body)
      setRows((list) => [row, ...list])
      setFlash(`Added ${row.clientName}, ${row.serviceName}, ${money(row.amountCents)}.`)
      // ready for the next client: the name, note and typed price clear; the service, payment and day stay
      setForm((f) => ({ ...f, clientName: '', note: '', custom: '', otherName: isOther ? '' : f.otherName }))
    } catch (ex) {
      setFailure(ex && ex.friendly ? ex.message : 'Could not add that. Nothing was saved. Try again.')
    } finally {
      setSaving(false)
    }
  }

  async function remove(row) {
    try {
      await removeSale(row.id)
      setRows((list) => list.filter((r) => r.id !== row.id))
      setFlash(`Removed ${row.clientName}, ${money(row.amountCents)}.`)
    } catch {
      setFailure('Could not remove that. Nothing was changed. Try again.')
    }
    setConfirmId(null)
  }

  function download() {
    const blob = new Blob([toCsv(visible)], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `vicbless-sales-${today}.csv`
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
  }

  function clearFilters() {
    setQuery('')
    setServiceFilter('all')
    setPayment('all')
    setRange('all')
  }

  // Tapping a column heading sorts by it; tapping it again flips the order.
  function sortBy(key) {
    const sameColumn = sort.key === key
    const next = SORTS.find((s) => s.key === key && s.dir === (sameColumn && sort.dir === 'desc' ? 'asc' : 'desc'))
    if (next) setSortId(next.id)
    else setSortId('date-desc')
  }
  const sortable = new Set(SORTS.map((s) => s.key))

  return (
    <section className="sales" aria-label="Sales log">
      <form className="sales-add" onSubmit={submit} noValidate aria-label="Log a sale">
        <h2>Log a client</h2>

        <div className="field">
          <label htmlFor={`${uid}-service`}>Which service</label>
          <select id={`${uid}-service`} value={form.serviceId} onChange={(e) => edit({ serviceId: e.target.value })} aria-invalid={!!errors.service}>
            {services.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
            <option value={OTHER}>Other (type it)</option>
          </select>
          {isOther && (
            <input
              className="sales-other"
              aria-label="Name of the service"
              placeholder="What was it? Like Line up only"
              maxLength={60}
              value={form.otherName}
              onChange={(e) => edit({ otherName: e.target.value })}
            />
          )}
          {errors.service && <p className="err">{errors.service}</p>}
        </div>

        <fieldset className="sales-choice">
          <legend>Price</legend>
          <div className="sales-pills">
            <label className={`sales-pill${!custom ? ' is-on' : ''}${isOther ? ' is-off' : ''}`}>
              <input type="radio" name={`${uid}-price`} checked={!custom} disabled={isOther} onChange={() => edit({ priceMode: 'standard' })} />
              <span>{picked && !isOther ? `Listed price ${money(picked.price * 100)}` : 'Listed price'}</span>
            </label>
            <label className={`sales-pill${custom ? ' is-on' : ''}`}>
              <input type="radio" name={`${uid}-price`} checked={custom} onChange={() => edit({ priceMode: 'custom' })} />
              <span>Custom price</span>
            </label>
          </div>
          {custom && (
            <div className="field sales-custom">
              <label htmlFor={`${uid}-custom`}>Price ($)</label>
              <input id={`${uid}-custom`} inputMode="decimal" placeholder="62.50" value={form.custom} onChange={(e) => edit({ custom: e.target.value })} aria-invalid={!!errors.price} />
            </div>
          )}
          {errors.price && <p className="err">{errors.price}</p>}
        </fieldset>

        <fieldset className="sales-choice">
          <legend>How they paid</legend>
          <div className="sales-pills">
            {['shop', 'online'].map((value) => (
              <label key={value} className={`sales-pill${form.payment === value ? ' is-on' : ''}`}>
                <input type="radio" name={`${uid}-pay`} checked={form.payment === value} onChange={() => edit({ payment: value })} />
                <span>{value === 'shop' ? 'At the shop' : 'Online'}</span>
              </label>
            ))}
          </div>
        </fieldset>

        <div className="field">
          <label htmlFor={`${uid}-client`}>Client's name</label>
          <input id={`${uid}-client`} autoComplete="off" maxLength={60} value={form.clientName} onChange={(e) => edit({ clientName: e.target.value })} aria-invalid={!!errors.client} />
          {errors.client && <p className="err">{errors.client}</p>}
        </div>

        <div className="sales-two">
          <div className="field">
            <label htmlFor={`${uid}-date`}>Day</label>
            <input id={`${uid}-date`} type="date" max={today} value={form.dateKey} onChange={(e) => edit({ dateKey: e.target.value })} aria-invalid={!!errors.date} />
            {errors.date && <p className="err">{errors.date}</p>}
          </div>
          <div className="field">
            <label htmlFor={`${uid}-note`}>
              Note <span className="hint">(optional)</span>
            </label>
            <input id={`${uid}-note`} maxLength={NOTE_MAX} value={form.note} onChange={(e) => edit({ note: e.target.value })} />
          </div>
        </div>

        {failure && (
          <p className="err" role="alert">
            {failure}
          </p>
        )}
        <div role="status" aria-live="polite">
          {flash && <p className="admin-flash">{flash}</p>}
        </div>
        <button type="submit" className="btn btn-primary sales-submit" disabled={saving}>
          {saving ? 'Adding…' : 'Add to log'}
        </button>
      </form>

      {status === 'loading' && (
        <p role="status" className="admin-status">
          Loading the sales log…
        </p>
      )}
      {status === 'error' && (
        <div>
          <p className="notice" role="alert">
            Could not load the sales log.
          </p>
          <button type="button" className="btn" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      )}

      {status === 'ready' && (
        <>
          <div className="sales-head">
            <h2>Numbers</h2>
            <p className="admin-meta">
              {filtering ? `For the ${metrics.count} of ${rows.length} sales shown below` : `For all ${rows.length} sales`}
            </p>
          </div>
          <Metrics m={metrics} />

          <div className="sales-head">
            <h2>Clients</h2>
            <button type="button" className="admin-box-btn" onClick={download} disabled={visible.length === 0}>
              Download for Excel
            </button>
          </div>

          <div className="sales-filters" role="search" aria-label="Search and filter the sales log">
            <input type="search" className="sales-search" aria-label="Search clients" placeholder="Search a client, service or note" value={query} onChange={(e) => setQuery(e.target.value)} />
            <div className="sales-filter-row">
              <select aria-label="Filter by service" value={serviceFilter} onChange={(e) => setServiceFilter(e.target.value)}>
                <option value="all">All services</option>
                {serviceNames.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
              <select aria-label="Filter by how they paid" value={payment} onChange={(e) => setPayment(e.target.value)}>
                <option value="all">Any payment</option>
                <option value="shop">Paid at the shop</option>
                <option value="online">Paid online</option>
              </select>
              <select aria-label="Filter by dates" value={range} onChange={(e) => setRange(e.target.value)}>
                {RANGES.map((r) => (
                  <option key={r.id} value={r.id}>
                    {r.label}
                  </option>
                ))}
              </select>
              <select aria-label="Sort the list" value={sortId} onChange={(e) => setSortId(e.target.value)}>
                {SORTS.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label}
                  </option>
                ))}
              </select>
            </div>
            {filtering && (
              <button type="button" className="link-btn" onClick={clearFilters}>
                Clear search and filters
              </button>
            )}
          </div>

          {rows.length === 0 ? (
            <p className="empty">Nothing logged yet. Add your first client above.</p>
          ) : visible.length === 0 ? (
            <p className="empty">No sales match. Clear the search or filters to see them all.</p>
          ) : (
            <>
              <div className="sales-sheet" tabIndex={0} role="region" aria-label="Sales spreadsheet">
                <table>
                  <thead>
                    <tr>
                      {COLUMNS.map((c) => (
                        <th key={c.key} scope="col" className={c.numeric ? 'num' : ''} aria-sort={sort.key === c.key ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                          {sortable.has(c.key) ? (
                            <button type="button" onClick={() => sortBy(c.key)}>
                              {c.label}
                              <span aria-hidden="true">{sort.key === c.key ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : ''}</span>
                            </button>
                          ) : (
                            c.label
                          )}
                        </th>
                      ))}
                      <th scope="col">
                        <span className="sr-only">Remove</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {visible.slice(0, shown).map((r) => (
                      <tr key={r.id}>
                        <td className="nowrap">{dayWords(r.dateKey)}</td>
                        <td>
                          <span className="sales-client">{r.clientName}</span>
                          {r.note && <span className="sales-note">{r.note}</span>}
                        </td>
                        <td>{r.serviceName}</td>
                        <td className="num nowrap">
                          {money(r.amountCents)}
                          {r.customPrice && <span className="sales-custom-tag">custom</span>}
                        </td>
                        <td>
                          <span className={`sales-paid sales-paid-${r.payment}`}>{PAYMENT_WORDS[r.payment]}</span>
                        </td>
                        <td className="sales-actions">
                          {confirmId === r.id ? (
                            <span className="sales-confirm">
                              <button type="button" className="admin-box-btn admin-box-danger" onClick={() => remove(r)}>
                                Yes, remove
                              </button>
                              <button type="button" className="admin-box-btn" onClick={() => setConfirmId(null)}>
                                Keep
                              </button>
                            </span>
                          ) : (
                            <button type="button" className="admin-box-btn" onClick={() => setConfirmId(r.id)} aria-label={`Remove ${r.clientName}, ${money(r.amountCents)}`}>
                              Remove
                            </button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr>
                      <td colSpan={3}>
                        {visible.length} {visible.length === 1 ? 'sale' : 'sales'}
                      </td>
                      <td className="num nowrap">{money(metrics.totalCents)}</td>
                      <td colSpan={2} />
                    </tr>
                  </tfoot>
                </table>
              </div>
              <p className="sales-swipe">Swipe the table sideways to see every column.</p>
              {visible.length > shown && (
                <button type="button" className="btn sales-more" onClick={() => setShown((n) => n + PAGE)}>
                  Show more ({visible.length - shown} left)
                </button>
              )}
            </>
          )}
        </>
      )}
    </section>
  )
}

function Metrics({ m }) {
  const best = m.byService[0]
  const topClient = m.topClients[0]
  const cards = [
    { label: 'Total sales', value: money(m.totalCents), big: true },
    { label: 'Clients logged', value: String(m.count), hint: m.count ? `${m.clientCount} different, ${m.repeatClients} came back` : '' },
    { label: 'Average sale', value: m.count ? money(m.averageCents) : '$0' },
    { label: 'Highest sale', value: m.highest ? money(m.highest.amountCents) : '$0', hint: m.highest ? `${m.highest.clientName}, ${m.highest.serviceName}` : '' },
    { label: 'Paid at the shop', value: money(m.shop.cents), hint: `${m.shop.count} ${m.shop.count === 1 ? 'client' : 'clients'}` },
    { label: 'Paid online', value: money(m.online.cents), hint: `${m.online.count} ${m.online.count === 1 ? 'client' : 'clients'}` },
    { label: 'Top service', value: best ? best.name : 'None yet', hint: best ? `${money(best.cents)}, ${best.count} ${best.count === 1 ? 'sale' : 'sales'}` : '', text: true },
    { label: 'Top client', value: topClient ? topClient.name : 'None yet', hint: topClient ? `${money(topClient.cents)}, ${topClient.count} ${topClient.count === 1 ? 'visit' : 'visits'}` : '', text: true },
    {
      label: 'Best day',
      value: m.bestDay ? dayWords(m.bestDay.name) : 'None yet',
      hint: m.bestDay ? `${money(m.bestDay.cents)}, ${m.bestDay.count} ${m.bestDay.count === 1 ? 'client' : 'clients'}` : '',
      text: true,
    },
  ]
  return (
    <>
      <dl className="sales-metrics">
        {cards.map((c) => (
          <div key={c.label} className={`sales-metric${c.big ? ' is-big' : ''}`}>
            <dt>{c.label}</dt>
            <dd className={c.text ? 'is-text' : ''}>{c.value}</dd>
            {c.hint && <dd className="sales-hint">{c.hint}</dd>}
          </div>
        ))}
      </dl>
      {m.byService.length > 0 && (
        <div className="sales-bars" role="group" aria-label="Sales by service">
          {m.byService.map((s) => (
            <div key={s.name} className="sales-bar-row">
              <span className="sales-bar-name">{s.name}</span>
              <span className="sales-bar-track" aria-hidden="true">
                <span style={{ width: `${Math.max(4, Math.round((s.cents / m.byService[0].cents) * 100))}%` }} />
              </span>
              <span className="sales-bar-num">
                {money(s.cents)} <span className="sales-hint">({s.count})</span>
              </span>
            </div>
          ))}
        </div>
      )}
    </>
  )
}
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
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

/* After Hours Cuts on Vic's dashboard: purple outline and an "After hours" label, like on the booking page. */
.admin-card-after {
  border-color: var(--accent);
  box-shadow: 0 0 0 1px var(--accent), 0 0 16px -8px var(--accent);
}

.admin-meta .after-badge {
  display: block;
  width: fit-content;
  margin-top: 8px;
}

.admin-after-divider {
  list-style: none;
  margin: 18px 0 6px;
  padding: 4px 0;
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--accent);
  border-bottom: 2px solid var(--accent);
}

.admin-move-late {
  display: block;
  font-size: 0.6rem;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--accent);
}

.admin-after-group {
  border-color: var(--accent);
}

/* ---- the dashboard's two pages: Schedule and Sales log ------------------------------------------------------- */

.admin-wide {
  max-width: 980px;
}

.admin-tabs {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  margin: 8px 0 20px;
}

.admin-tabs button {
  min-height: 44px;
  font-weight: 800;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.admin-tabs button[aria-current='page'] {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

/* ---- Sales log ------------------------------------------------------------------------------------------------- */

.sales h2 {
  margin: 0;
  font-size: 1.3rem;
  font-weight: 800;
}

.sales-add {
  margin-bottom: 28px;
  padding: 16px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-add h2 {
  margin-bottom: 14px;
}

.sales-add select,
.sales-filters select,
.sales-search,
.sales-other {
  width: 100%;
  min-height: 46px;
  padding: 10px 12px;
  color: var(--ink);
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-other {
  margin-top: 8px;
}

.sales-add select:focus,
.sales-filters select:focus,
.sales-search:focus {
  border-color: var(--accent);
}

.sales-choice {
  margin: 0 0 14px;
  padding: 0;
  border: 0;
}

.sales-choice legend {
  margin-bottom: 4px;
  padding: 0;
  font-weight: 600;
}

.sales-pills {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.sales-pill {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 46px;
  padding: 8px 10px;
  font-weight: 700;
  text-align: center;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}

.sales-pill input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.sales-pill.is-on {
  color: var(--on-accent);
  background: var(--accent);
  border-color: var(--accent);
}

.sales-pill.is-off {
  opacity: 0.4;
  cursor: not-allowed;
}

.sales-pill:focus-within {
  outline: 3px solid var(--accent);
  outline-offset: 2px;
}

.sales-custom {
  margin: 10px 0 0;
}

.sales-two {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.sales-submit {
  width: 100%;
  margin-top: 6px;
}

.sales-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: space-between;
  gap: 4px 12px;
  margin: 28px 0 12px;
}

.sales-head .admin-meta {
  margin: 0;
}

.sales-metrics {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  margin: 0;
}

.sales-metric {
  min-width: 0;
  padding: 12px 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-metric.is-big {
  grid-column: 1 / -1;
  border-color: var(--accent);
}

.sales-metric dt {
  font-size: 0.8rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--muted);
}

.sales-metric dd {
  margin: 4px 0 0;
  font-size: 1.6rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
}

.sales-metric.is-big dd {
  font-size: 2.2rem;
  color: var(--accent);
}

.sales-metric dd.is-text {
  font-size: 1.05rem;
  line-height: 1.25;
}

.sales-metric dd.sales-hint,
.sales-hint {
  margin-top: 2px;
  font-size: 0.8rem;
  font-weight: 400;
  color: var(--muted);
}

.sales-bars {
  display: grid;
  gap: 8px;
  margin-top: 14px;
}

.sales-bar-row {
  display: grid;
  grid-template-columns: minmax(90px, 1.1fr) 1.4fr auto;
  align-items: center;
  gap: 10px;
  font-size: 0.9rem;
}

.sales-bar-name {
  overflow-wrap: anywhere;
}

.sales-bar-track {
  height: 10px;
  background: var(--line);
  border-radius: 999px;
  overflow: hidden;
}

.sales-bar-track span {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: 999px;
}

.sales-bar-num {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.sales-filters {
  display: grid;
  gap: 8px;
  margin-bottom: 12px;
}

.sales-filter-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.sales-sheet {
  max-height: 70vh;
  overflow: auto;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-sheet table {
  width: 100%;
  min-width: 600px;
  border-collapse: collapse;
  font-size: 0.92rem;
}

.sales-sheet th,
.sales-sheet td {
  padding: 10px 12px;
  text-align: left;
  vertical-align: top;
  border-bottom: 1px solid var(--line);
}

.sales-sheet thead th {
  position: sticky;
  top: 0;
  z-index: 1;
  font-size: 0.78rem;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--muted);
  background: var(--bg);
  border-bottom: 2px solid var(--accent);
}

.sales-sheet thead button {
  padding: 0;
  font: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  color: inherit;
  background: none;
  border: 0;
  cursor: pointer;
}

.sales-sheet th[aria-sort='ascending'] button,
.sales-sheet th[aria-sort='descending'] button {
  color: var(--accent);
}

.sales-sheet tbody tr:nth-child(even) {
  background: color-mix(in srgb, var(--line) 28%, transparent);
}

.sales-sheet .num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

.sales-sheet .nowrap {
  white-space: nowrap;
}

.sales-sheet tfoot td {
  position: sticky;
  bottom: 0;
  font-weight: 800;
  background: var(--bg);
  border-top: 2px solid var(--accent);
  border-bottom: 0;
}

.sales-client {
  display: block;
  font-weight: 700;
}

.sales-note {
  display: block;
  margin-top: 2px;
  font-size: 0.8rem;
  color: var(--muted);
}

.sales-custom-tag {
  display: block;
  font-size: 0.65rem;
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}

.sales-paid {
  display: inline-block;
  padding: 2px 10px;
  font-size: 0.78rem;
  font-weight: 700;
  white-space: nowrap;
  border: 1px solid currentColor;
  border-radius: 999px;
}

.sales-paid-online {
  color: var(--accent);
}

.sales-paid-shop {
  color: var(--muted);
}

.sales-actions {
  white-space: nowrap;
}

.sales-confirm {
  display: inline-flex;
  gap: 6px;
}

.sales-more {
  display: block;
  width: 100%;
  margin-top: 12px;
}

@media (min-width: 720px) {
  .sales-metrics {
    grid-template-columns: repeat(3, 1fr);
  }

  .sales-metric.is-big {
    grid-column: auto;
  }

  .sales-filters {
    grid-template-columns: 1fr;
  }

  .sales-filter-row {
    grid-template-columns: repeat(4, 1fr);
  }
}

.sales-actions .admin-box-btn {
  min-height: 34px;
  padding: 4px 10px;
}

.sales-swipe {
  margin: 6px 0 0;
  font-size: 0.8rem;
  color: var(--muted);
}

@media (max-width: 719px) {
  .sales-sheet table {
    min-width: 520px;
    font-size: 0.85rem;
  }

  .sales-sheet th,
  .sales-sheet td {
    padding: 8px;
  }
}

@media (min-width: 720px) {
  .sales-swipe {
    display: none;
  }
}
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
// Vic's dashboard data layer. The admin screens import from HERE and never know which layer answers.
// real -> realAdminApi.js (the backend, production builds); mock -> mockAdminApi.js (npm run dev and tests).
// See ../lib/mode.js for how the choice is made.

import { API_MODE } from '../lib/mode.js'
import * as mock from './mockAdminApi.js'
import * as real from './realAdminApi.js'

const layer = API_MODE === 'real' ? real : mock

export const isSignedIn = () => layer.isSignedIn()
export const signIn = (password) => layer.signIn(password)
export const signOut = () => layer.signOut()
export const getDay = (dateKey) => layer.getDay(dateKey)
export const cancelBooking = (item) => layer.cancelBooking(item)
export const moveBooking = (item, to) => layer.moveBooking(item, to)
export const addBlock = (block) => layer.addBlock(block)
export const getAdminSettings = () => layer.getAdminSettings()
export const saveSettings = (body) => layer.saveSettings(body)
export const getSales = () => layer.getSales()
export const addSale = (body) => layer.addSale(body)
export const removeSale = (id) => layer.removeSale(id)
export const removeBlock = (id) => layer.removeBlock(id)
export { SIGNED_OUT_EVENT } from './realAdminApi.js'
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
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

import { getBusy } from '../lib/mockApi.js'
import { fromKey, keyOf, slotStarts } from '../lib/availability.js'
import { afterService, fromApi, isAfterStart, toApi } from '../lib/shopSettings.js'
import {
  blockedStartsFor,
  hoursNow,
  overlaps,
  readBlocks,
  readBookings,
  readCancelledSamples,
  readSales,
  readShopSettings,
  slotMinutesOn,
  writeSales,
  writeBlocks,
  writeBookings,
  writeCancelledSamples,
  writeShopSettings,
} from '../lib/mockStore.js'
import { findConflicts } from './blocks.js'
import { saleServices } from '../lib/sales.js'

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
  const settings = readShopSettings()
  const service = isAfterStart(fromKey(dateKey), start) ? afterService(settings) : settings.services[h % settings.services.length]
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
  const grid = slotStarts(fromKey(dateKey), hoursNow(), slot)
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
  if (!slotStarts(fromKey(dateKey), hoursNow(), slot).includes(start)) {
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
    afterHours: body.afterHours,
  })
  if (!parsed) throw new Error('Those settings are not valid.')
  const saved = toApi(parsed)
  writeShopSettings(saved)
  return saved
}

// The sales log. Kept in this browser, newest first, with the same rules as the real API.
export async function getSales() {
  await delay(150)
  return readSales()
}

export async function addSale(body) {
  await delay(200)
  const settings = readShopSettings()
  const today = keyOf(new Date())
  const service = body.serviceId ? saleServices(settings).find((s) => s.id === body.serviceId) : null
  if (body.serviceId && !service) throw new Error('Pick a service, or type the name of a one-off service.')
  const custom = body.priceMode === 'custom'
  const dateKey = body.dateKey || today
  const row = {
    id: `${dateKey}.sale.${Math.random().toString(16).slice(2, 10).padEnd(8, '0')}`,
    dateKey,
    serviceId: service ? service.id : '',
    serviceName: service ? service.name : body.serviceName,
    amountCents: custom ? body.amountCents : service.price * 100,
    customPrice: custom,
    payment: body.payment === 'online' ? 'online' : 'shop',
    clientName: body.clientName,
    note: body.note || '',
    createdAt: new Date().toISOString(),
  }
  writeSales([row, ...readSales()])
  return row
}

export async function removeSale(id) {
  await delay(150)
  writeSales(readSales().filter((s) => s.id !== id))
}
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
// The real admin data layer: the same functions as mockAdminApi.js, backed by the API.
//
//   signIn(password)          POST   /api/admin/login            -> a 12 hour token, kept in this browser
//   getDay(dateKey)           GET    /api/admin/schedule?date=
//   cancelBooking(item)       DELETE /api/admin/bookings/{id}    (the customer is emailed if they left an email)
//   moveBooking(item, to)     PATCH  /api/admin/bookings/{id}    (the booking comes back with a NEW id)
//   addBlock(block)           POST   /api/admin/blocks
//   removeBlock(id)           DELETE /api/admin/blocks/{id}
//   getSales()                GET    /api/admin/sales            -> the whole sales log, newest first
//   addSale(body)             POST   /api/admin/sales            -> the new line
//   removeSale(id)            DELETE /api/admin/sales/{id}
//   getAdminSettings()        GET    /api/admin/settings
//   saveSettings(body)        PUT    /api/admin/settings       (the saved settings come back)
//
// Errors thrown to the screens: an ApiError whose `.code` is 'CONFLICT' when the time is taken or
// overlaps something, 'INVALID' when it is not a time Vic works, and the API's own word otherwise.
// If the session has run out (the API says 401 on a signed-in call), the token is dropped and the
// dashboard is told to show the sign-in screen again.

import { ApiError } from '../lib/errors.js'
import { request } from '../lib/http.js'

const SESSION_KEY = 'vicbless.admin.token'
let memoryToken = null // the token also lives here, so signing in works even when storage is blocked
export const SIGNED_OUT_EVENT = 'vicbless:signed-out'

// The older screens branch on these two words, so they are kept.
const SCREEN_CODES = { conflict: 'CONFLICT', slot_taken: 'CONFLICT', slot_unavailable: 'CONFLICT', invalid_slot: 'INVALID' }

function readSession() {
  try {
    const saved = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null')
    if (saved && typeof saved.token === 'string' && typeof saved.expiresAt === 'number' && saved.expiresAt > Date.now()) return saved
  } catch {
    /* unreadable or blocked: treated as signed out */
  }
  return null
}

export function isSignedIn() {
  return readSession() !== null
}

export function signOut() {
  try {
    localStorage.removeItem(SESSION_KEY)
  } catch {
    /* nothing to clear */
  }
}

export async function signIn(password) {
  if (!String(password ?? '').trim()) throw new Error('Enter your password.')
  const { token, expiresIn } = await request('POST', '/admin/login', { body: { password } })
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify({ token, expiresAt: Date.now() + expiresIn * 1000 }))
  } catch {
    /* storage blocked: the session just will not survive a reload */
  }
  memoryToken = { token, expiresAt: Date.now() + expiresIn * 1000 }
}

function currentToken() {
  const saved = readSession() || (memoryToken && memoryToken.expiresAt > Date.now() ? memoryToken : null)
  return saved ? saved.token : ''
}

// Every signed-in call goes through here.
async function call(method, path, body) {
  const token = currentToken()
  if (!token) {
    signedOut()
    throw new ApiError({ status: 401, code: 'unauthorized', message: 'Please sign in to continue.' })
  }
  try {
    return await request(method, path, { body, token })
  } catch (err) {
    if (err instanceof ApiError) {
      if (err.status === 401) signedOut()
      err.code = SCREEN_CODES[err.apiCode] || err.apiCode
    }
    throw err
  }
}

function signedOut() {
  signOut()
  memoryToken = null
  if (typeof window !== 'undefined') window.dispatchEvent(new Event(SIGNED_OUT_EVENT))
}

export function getDay(dateKey) {
  return call('GET', `/admin/schedule?date=${encodeURIComponent(dateKey)}`)
}

export async function cancelBooking(item) {
  await call('DELETE', `/admin/bookings/${encodeURIComponent(item.id)}`)
}

export async function moveBooking(item, { dateKey, start }) {
  return call('PATCH', `/admin/bookings/${encodeURIComponent(item.id)}`, { dateKey, start })
}

export function addBlock({ dateKey, start, end, note = '', whole = false }) {
  return call('POST', '/admin/blocks', { dateKey, start, end, note, whole })
}

export async function removeBlock(id) {
  await call('DELETE', `/admin/blocks/${encodeURIComponent(id)}`)
}

export function getAdminSettings() {
  return call('GET', '/admin/settings')
}

export function saveSettings(body) {
  return call('PUT', '/admin/settings', body)
}

export async function getSales() {
  const answer = await call('GET', '/admin/sales')
  return Array.isArray(answer && answer.sales) ? answer.sales : []
}

export function addSale(body) {
  return call('POST', '/admin/sales', body)
}

export async function removeSale(id) {
  await call('DELETE', `/admin/sales/${encodeURIComponent(id)}`)
}
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
// The real admin data layer against a pretend fetch: the token, the URLs, and what happens when it expires.
// Runs in plain Node (no jsdom needed): a tiny in-memory localStorage and a window that can dispatch events stand in.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { addBlock, addSale, cancelBooking, getDay, getSales, removeSale, isSignedIn, moveBooking, removeBlock, SIGNED_OUT_EVENT, signIn, signOut } from './realAdminApi.js'

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const errorBody = (code, message) => ({ error: { code, message } })
let calls

// An in-memory stand-in for the browser's localStorage, and a window that can send and hear events.
function installBrowserStubs() {
  const data = new Map()
  vi.stubGlobal('localStorage', {
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
    removeItem: (k) => data.delete(k),
    clear: () => data.clear(),
  })
  vi.stubGlobal('window', new EventTarget())
}
const stub = (...answers) => {
  const queue = [...answers]
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    calls.push({ url, init })
    return queue.length > 1 ? queue.shift() : queue[0]
  }))
}

beforeEach(() => {
  installBrowserStubs()
  calls = []
  localStorage.clear()
  signOut()
})
afterEach(() => vi.unstubAllGlobals())

async function signedIn() {
  stub(json(200, { token: 'tok123', expiresIn: 43200 }))
  await signIn('hunter2')
  calls = []
}

describe('signing in', () => {
  it('posts the password, keeps the token, and sends it on later calls', async () => {
    stub(json(200, { token: 'tok123', expiresIn: 43200 }))
    expect(isSignedIn()).toBe(false)
    await signIn('hunter2')
    expect(calls[0].url).toBe('/api/admin/login')
    expect(JSON.parse(calls[0].init.body)).toEqual({ password: 'hunter2' })
    expect(isSignedIn()).toBe(true)

    calls = []
    stub(json(200, { dateKey: '2026-10-13', items: [], blocks: [] }))
    await getDay('2026-10-13')
    expect(calls[0].url).toBe('/api/admin/schedule?date=2026-10-13')
    expect(calls[0].init.headers.Authorization).toBe('Bearer tok123')
  })

  it('rejects an empty password without calling the API', async () => {
    stub(json(200, {}))
    await expect(signIn('   ')).rejects.toThrow('Enter your password.')
    expect(calls).toHaveLength(0)
  })

  it("shows the API's message for a wrong password, and does not fire the signed-out event", async () => {
    const out = vi.fn()
    window.addEventListener(SIGNED_OUT_EVENT, out)
    stub(json(401, errorBody('unauthorized', "That password isn't right. Check it and try again.")))
    await expect(signIn('nope')).rejects.toThrow("That password isn't right")
    expect(out).not.toHaveBeenCalled()
    expect(isSignedIn()).toBe(false)
    window.removeEventListener(SIGNED_OUT_EVENT, out)
  })

  it('treats an expired saved token as signed out', () => {
    localStorage.setItem('vicbless.admin.token', JSON.stringify({ token: 'old', expiresAt: Date.now() - 1000 }))
    expect(isSignedIn()).toBe(false)
  })

  it('ignores the old mock session marker', () => {
    localStorage.setItem('vicbless.admin.session', 'preview')
    expect(isSignedIn()).toBe(false)
  })
})

describe('signed-in calls', () => {
  it('uses the right method and URL for each action, encoding ids', async () => {
    await signedIn()
    stub(json(200, { cancelled: true }))
    await cancelBooking({ id: '2026-10-13.0660.9f3a1c2b' })
    expect([calls[0].init.method, calls[0].url]).toEqual(['DELETE', '/api/admin/bookings/2026-10-13.0660.9f3a1c2b'])

    calls = []
    stub(json(200, { id: '2026-10-14.0700.aaaaaaaa', code: 'ABC23' }))
    const moved = await moveBooking({ id: '2026-10-13.0660.9f3a1c2b' }, { dateKey: '2026-10-14', start: 700 })
    expect([calls[0].init.method, calls[0].url]).toEqual(['PATCH', '/api/admin/bookings/2026-10-13.0660.9f3a1c2b'])
    expect(JSON.parse(calls[0].init.body)).toEqual({ dateKey: '2026-10-14', start: 700 })
    expect(moved.id).toBe('2026-10-14.0700.aaaaaaaa') // the NEW id

    calls = []
    stub(json(201, { id: 'b1', dateKey: '2026-10-13', start: 600, end: 700, note: 'Lunch', whole: false }))
    await addBlock({ dateKey: '2026-10-13', start: 600, end: 700, note: 'Lunch' })
    expect([calls[0].init.method, calls[0].url]).toEqual(['POST', '/api/admin/blocks'])

    calls = []
    stub(json(200, { removed: true }))
    await removeBlock('b/1')
    expect([calls[0].init.method, calls[0].url]).toEqual(['DELETE', '/api/admin/blocks/b%2F1'])
  })

  it("gives the screens their 'CONFLICT' and 'INVALID' words", async () => {
    await signedIn()
    stub(json(409, errorBody('conflict', 'That overlaps a booking or time you already blocked off.')))
    expect(await addBlock({ dateKey: '2026-10-13', start: 600, end: 700 }).catch((e) => e)).toMatchObject({ code: 'CONFLICT', apiCode: 'conflict' })
    stub(json(409, errorBody('slot_taken', 'Sorry, that time was just taken. Please pick another.')))
    expect(await moveBooking({ id: 'x' }, { dateKey: '2026-10-13', start: 600 }).catch((e) => e)).toMatchObject({ code: 'CONFLICT' })
    stub(json(422, errorBody('invalid_slot', 'That isn’t a time Vic takes bookings for.')))
    expect(await moveBooking({ id: 'x' }, { dateKey: '2026-10-13', start: 601 }).catch((e) => e)).toMatchObject({ code: 'INVALID' })
  })

  it('drops the session and announces it when the API says 401', async () => {
    await signedIn()
    const out = vi.fn()
    window.addEventListener(SIGNED_OUT_EVENT, out)
    stub(json(401, errorBody('unauthorized', 'Please sign in to continue.')))
    await expect(getDay('2026-10-13')).rejects.toMatchObject({ status: 401 })
    expect(out).toHaveBeenCalledTimes(1)
    expect(isSignedIn()).toBe(false)
    window.removeEventListener(SIGNED_OUT_EVENT, out)
  })

  it('does not even call the API when there is no session', async () => {
    stub(json(200, {}))
    await expect(getDay('2026-10-13')).rejects.toMatchObject({ status: 401 })
    expect(calls).toHaveLength(0)
  })
})

describe('the sales log', () => {
  it('reads the whole log', async () => {
    await signedIn()
    stub(json(200, { sales: [{ id: '2026-10-22.sale.abcdef12' }] }))
    expect(await getSales()).toEqual([{ id: '2026-10-22.sale.abcdef12' }])
    expect(calls[0].url).toBe('/api/admin/sales')
    expect(calls[0].init.headers.Authorization).toBe('Bearer tok123')
  })

  it('treats an odd answer as an empty log', async () => {
    await signedIn()
    stub(json(200, {}))
    expect(await getSales()).toEqual([])
  })

  it('adds a sale and gives back the new line', async () => {
    await signedIn()
    stub(json(201, { id: '2026-10-22.sale.abcdef12', clientName: 'Marcus' }))
    const body = { serviceId: 'mens-cut', priceMode: 'standard', payment: 'shop', clientName: 'Marcus' }
    expect(await addSale(body)).toMatchObject({ clientName: 'Marcus' })
    expect(calls[0].url).toBe('/api/admin/sales')
    expect(calls[0].init.method).toBe('POST')
    expect(JSON.parse(calls[0].init.body)).toEqual(body)
  })

  it('shows the API\'s own words when it refuses a sale', async () => {
    await signedIn()
    stub(json(422, errorBody('validation_error', "Enter the client's name, up to 60 characters.")))
    await expect(addSale({})).rejects.toMatchObject({ message: "Enter the client's name, up to 60 characters." })
  })

  it('removes a sale by its id', async () => {
    await signedIn()
    stub(json(200, { removed: true }))
    await removeSale('2026-10-22.sale.abcdef12')
    expect(calls[0].url).toBe('/api/admin/sales/2026-10-22.sale.abcdef12')
    expect(calls[0].init.method).toBe('DELETE')
  })
})
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
// MOCK storage shared by the customer-facing mock (lib/api.js) and the admin mock.
// It exists so that cancelling or blocking time in the dashboard changes what customers see.
// It goes away when the real backend exists.

import { fromKey, slotStarts } from './availability.js'
import { DEFAULT_SHOP_SETTINGS, fromApi, hoursFor, slotFor } from './shopSettings.js'

const KEYS = {
  bookings: 'vicbless.bookings', // bookings made through the site
  blocks: 'vicbless.blocks', // time Vic blocked off
  cancelledSamples: 'vicbless.cancelledSamples', // sample bookings Vic cancelled in the dashboard
  sales: 'vicbless.sales', // the sales log Vic keeps by hand
  shopSettings: 'vicbless.shopSettings', // services, prices and appointment lengths Vic saved (API shape)
}

function read(key) {
  try {
    const list = JSON.parse(localStorage.getItem(key) || '[]')
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

function write(key, list) {
  try {
    localStorage.setItem(key, JSON.stringify(list))
  } catch {
    /* storage blocked: the change just will not survive a reload */
  }
}

export const readBookings = () => read(KEYS.bookings)
export const writeBookings = (list) => write(KEYS.bookings, list)
export const readBlocks = () => read(KEYS.blocks)
export const writeBlocks = (list) => write(KEYS.blocks, list)
export const readSales = () => read(KEYS.sales)
export const writeSales = (list) => write(KEYS.sales, list)
export const readCancelledSamples = () => read(KEYS.cancelledSamples)
export const writeCancelledSamples = (list) => write(KEYS.cancelledSamples, list)

// The shop settings Vic saved in this browser (the services and the appointment lengths), or the starting ones.
export function readShopSettings() {
  try {
    return fromApi(JSON.parse(localStorage.getItem(KEYS.shopSettings) || 'null')) || DEFAULT_SHOP_SETTINGS
  } catch {
    return DEFAULT_SHOP_SETTINGS
  }
}

// `body` is the API shape ({ services, slotMinutes: { mon: 45 ... } }).
export function writeShopSettings(body) {
  try {
    localStorage.setItem(KEYS.shopSettings, JSON.stringify(body))
  } catch {
    /* storage blocked: the change just will not survive a reload */
  }
}

// How long an appointment is on `dateKey` right now.
export const slotMinutesOn = (dateKey) => slotFor(readShopSettings(), fromKey(dateKey))

// The opening windows right now, late appointments included (they depend on the saved settings).
export const hoursNow = () => hoursFor(readShopSettings())

// True when the times [aStart, aEnd) and [bStart, bEnd) share any minute.
export const overlaps = (aStart, aEnd, bStart, bEnd) => aStart < bEnd && bStart < aEnd

// The appointment starts on `dateKey` that touch blocked-off time.
export function blockedStartsFor(dateKey) {
  const blocks = readBlocks().filter((b) => b.dateKey === dateKey)
  const out = new Set()
  if (blocks.length === 0) return out
  const slot = slotMinutesOn(dateKey)
  for (const s of slotStarts(fromKey(dateKey), hoursNow(), slot)) {
    if (blocks.some((b) => overlaps(s, s + slot, b.start, b.end))) out.add(s)
  }
  return out
}

// True when Vic has taken the whole day off. Customers see such a day as Closed, not Full.
export function isDayOff(dateKey) {
  return readBlocks().some((b) => b.dateKey === dateKey && b.whole)
}
VICBLESS_EOF
cat > "$STAGE/16" <<'VICBLESS_EOF'
// Vic's sales log: the pure rules behind the "Sales log" page of his dashboard. No browser or network access here.
//
// A row of the log (what the API sends):
//   { id, dateKey, serviceId, serviceName, amountCents, customPrice, payment: 'shop' | 'online', clientName, note, createdAt }
// serviceId is '' for a one-off service Vic typed in.

import { AFTER_HOURS } from '../config.js'

export const OTHER = 'other' // the "Other (type it)" choice in the service list
export const NAME_MAX = 60
export const NOTE_MAX = 120
export const MAX_CENTS = 999999 // $9,999.99, the most the API accepts
export const PAYMENT_WORDS = { shop: 'At the shop', online: 'Online' }

// "$55", "$62.50", "$1,204". Cents only show when there are some.
export function money(cents) {
  const whole = cents % 100 === 0
  return `$${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: 2 })}`
}

// What Vic typed in a price box ("62.5", "$62.50", "62") -> cents, or null when it is not a price.
export function parseDollars(text) {
  const m = /^\$?\s*(\d{1,4})(?:\.(\d{1,2}))?$/.exec(String(text ?? '').trim())
  if (!m) return null
  const cents = Number(m[1]) * 100 + Number((m[2] || '').padEnd(2, '0') || 0)
  return cents <= MAX_CENTS ? cents : null
}

// The services he can pick: his own list, then After Hours Cuts (always, even on a week with no late times).
export function saleServices(settings) {
  return [
    ...settings.services.map((s) => ({ id: s.id, name: s.name, price: s.price })),
    { id: AFTER_HOURS.id, name: AFTER_HOURS.name, price: settings.afterHours.price },
  ]
}

export const blankEntry = (settings, todayKey) => ({
  serviceId: settings.services[0] ? settings.services[0].id : OTHER,
  otherName: '',
  priceMode: 'standard',
  custom: '',
  payment: 'shop',
  clientName: '',
  note: '',
  dateKey: todayKey,
})

// Checks the quick form the way the API will. { ok: true, body } or { ok: false, errors: { service?, price?, client?, note?, date? } }
export function checkEntry(form, settings, todayKey) {
  const errors = {}
  const services = saleServices(settings)
  const isOther = form.serviceId === OTHER
  const service = isOther ? null : services.find((s) => s.id === form.serviceId) || null
  const otherName = form.otherName.trim().replace(/\s+/g, ' ')

  if (isOther ? otherName.length < 1 || otherName.length > 60 : !service) errors.service = 'Pick a service, or type the name of a one-off one.'

  // A one-off service has no listed price, so its price is always typed.
  const custom = isOther || form.priceMode === 'custom'
  let amountCents
  if (custom) {
    amountCents = parseDollars(form.custom)
    if (amountCents === null) errors.price = 'Enter the price in dollars, like 55 or 62.50.'
  }

  const clientName = form.clientName.trim().replace(/\s+/g, ' ')
  if (clientName.length < 1 || clientName.length > NAME_MAX) errors.client = "Enter the client's name."
  if (form.note.length > NOTE_MAX) errors.note = `Up to ${NOTE_MAX} characters.`
  if (!/^\d{4}-\d{2}-\d{2}$/.test(form.dateKey)) errors.date = 'Pick the day.'
  else if (form.dateKey > todayKey) errors.date = "A sale can't be dated in the future."

  if (Object.keys(errors).length) return { ok: false, errors }
  return {
    ok: true,
    body: {
      ...(service ? { serviceId: service.id } : { serviceName: otherName }),
      priceMode: custom ? 'custom' : 'standard',
      ...(custom ? { amountCents } : {}),
      payment: form.payment === 'online' ? 'online' : 'shop',
      clientName,
      note: form.note.trim(),
      dateKey: form.dateKey,
    },
  }
}

// ---- the spreadsheet: filter, sort, add up --------------------------------------------------------------------

const pad = (n) => String(n).padStart(2, '0')
const keyOf = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
const dateOf = (key) => {
  const [y, m, d] = key.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export const RANGES = [
  { id: 'all', label: 'All time' },
  { id: 'today', label: 'Today' },
  { id: 'week', label: 'Last 7 days' },
  { id: 'month', label: 'This month' },
  { id: '30', label: 'Last 30 days' },
]

// The first and last day (YYYY-MM-DD) of a date range, counting today. 'all' has no limits.
export function rangeBounds(range, todayKey) {
  const today = dateOf(todayKey)
  const daysBack = (n) => keyOf(new Date(today.getFullYear(), today.getMonth(), today.getDate() - n))
  if (range === 'today') return { from: todayKey, to: todayKey }
  if (range === 'week') return { from: daysBack(6), to: todayKey }
  if (range === '30') return { from: daysBack(29), to: todayKey }
  if (range === 'month') return { from: `${todayKey.slice(0, 8)}01`, to: todayKey }
  return { from: '', to: '' }
}

// Rows that match the search words, the service, how they paid and the dates. `service` is a service name or 'all'.
export function filterSales(rows, { query = '', service = 'all', payment = 'all', range = 'all' } = {}, todayKey) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const { from, to } = rangeBounds(range, todayKey)
  return rows.filter((r) => {
    if (service !== 'all' && r.serviceName !== service) return false
    if (payment !== 'all' && r.payment !== payment) return false
    if (from && r.dateKey < from) return false
    if (to && r.dateKey > to) return false
    if (!words.length) return true
    const text = `${r.clientName} ${r.serviceName} ${r.note} ${r.dateKey} ${money(r.amountCents)} ${PAYMENT_WORDS[r.payment]}`.toLowerCase()
    return words.every((w) => text.includes(w))
  })
}

const byText = (a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' })

// Sorted copy. key: 'date' | 'client' | 'service' | 'amount' | 'payment'; dir: 'asc' | 'desc'. Ties fall back to newest first.
export function sortSales(rows, key = 'date', dir = 'desc') {
  const sign = dir === 'asc' ? 1 : -1
  const newest = (a, b) => (b.dateKey === a.dateKey ? byText(b.createdAt || '', a.createdAt || '') : byText(b.dateKey, a.dateKey))
  const compare = {
    date: (a, b) => byText(a.dateKey, b.dateKey) || byText(a.createdAt || '', b.createdAt || ''),
    client: (a, b) => byText(a.clientName, b.clientName),
    service: (a, b) => byText(a.serviceName, b.serviceName),
    amount: (a, b) => a.amountCents - b.amountCents,
    payment: (a, b) => byText(a.payment, b.payment),
  }[key]
  return [...rows].sort((a, b) => (compare ? sign * compare(a, b) : 0) || newest(a, b))
}

// Everything the numbers at the top of the page show, for the rows given (the page passes the filtered ones).
export function salesMetrics(rows) {
  const total = rows.reduce((sum, r) => sum + r.amountCents, 0)
  const group = (keyOf2, labelOf) => {
    const map = new Map()
    for (const r of rows) {
      const k = keyOf2(r)
      const g = map.get(k) || { name: labelOf(r), count: 0, cents: 0 }
      g.count += 1
      g.cents += r.amountCents
      map.set(k, g)
    }
    return [...map.values()].sort((a, b) => b.cents - a.cents || b.count - a.count || byText(a.name, b.name))
  }
  const part = (payment) => {
    const mine = rows.filter((r) => r.payment === payment)
    return { count: mine.length, cents: mine.reduce((sum, r) => sum + r.amountCents, 0) }
  }
  const highest = rows.reduce((best, r) => (!best || r.amountCents > best.amountCents ? r : best), null)
  const clients = group((r) => r.clientName.toLowerCase(), (r) => r.clientName)
  const days = group((r) => r.dateKey, (r) => r.dateKey)
  return {
    count: rows.length,
    totalCents: total,
    averageCents: rows.length ? Math.round(total / rows.length) : 0,
    highest: highest && { amountCents: highest.amountCents, clientName: highest.clientName, serviceName: highest.serviceName, dateKey: highest.dateKey },
    shop: part('shop'),
    online: part('online'),
    customCount: rows.filter((r) => r.customPrice).length,
    byService: group((r) => r.serviceName, (r) => r.serviceName),
    topClients: clients.slice(0, 5),
    clientCount: clients.length,
    repeatClients: clients.filter((c) => c.count > 1).length,
    bestDay: days[0] || null,
  }
}

// The rows as a CSV file Vic can open in Excel or Google Sheets. A cell that starts with = + - @ is made safe so a
// spreadsheet never runs it as a formula.
export function toCsv(rows) {
  const cell = (value) => {
    let text = String(value ?? '')
    if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`
    return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
  }
  const header = ['Date', 'Client', 'Service', 'Price', 'Payment', 'Custom price', 'Note']
  const lines = rows.map((r) =>
    [r.dateKey, r.clientName, r.serviceName, (r.amountCents / 100).toFixed(2), PAYMENT_WORDS[r.payment], r.customPrice ? 'Yes' : 'No', r.note].map(cell).join(','),
  )
  return [header.join(','), ...lines].join('\r\n') + '\r\n'
}
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { DEFAULT_SHOP_SETTINGS } from './shopSettings.js'
import {
  OTHER,
  blankEntry,
  checkEntry,
  filterSales,
  money,
  parseDollars,
  rangeBounds,
  saleServices,
  salesMetrics,
  sortSales,
  toCsv,
} from './sales.js'

const TODAY = '2026-10-22' // a Thursday
const row = (over) => ({
  id: 'x',
  dateKey: TODAY,
  serviceId: 'mens-cut',
  serviceName: "Men's haircut",
  amountCents: 5500,
  customPrice: false,
  payment: 'shop',
  clientName: 'Marcus Jones',
  note: '',
  createdAt: '2026-10-22T15:00:00+00:00',
  ...over,
})
const LOG = [
  row({ id: 'a', clientName: 'Marcus Jones', dateKey: '2026-10-22', amountCents: 5500 }),
  row({ id: 'b', clientName: 'Dre Williams', dateKey: '2026-10-21', serviceName: 'After Hours Cuts', serviceId: 'after-hours', amountCents: 7000, payment: 'online' }),
  row({ id: 'c', clientName: 'marcus jones', dateKey: '2026-10-15', amountCents: 6250, customPrice: true, note: 'beard too' }),
  row({ id: 'd', clientName: 'Kid Cam', dateKey: '2026-09-30', serviceName: 'Kids cut', amountCents: 4000, payment: 'online' }),
]

describe('money and prices', () => {
  it('shows cents only when there are some', () => {
    expect(money(5500)).toBe('$55')
    expect(money(6250)).toBe('$62.50')
    expect(money(120400)).toBe('$1,204')
    expect(money(0)).toBe('$0')
  })

  it('reads what Vic types', () => {
    expect(parseDollars('55')).toBe(5500)
    expect(parseDollars('$62.5')).toBe(6250)
    expect(parseDollars(' 62.50 ')).toBe(6250)
    expect(parseDollars('0')).toBe(0)
    expect(parseDollars('9999.99')).toBe(999999)
    for (const bad of ['', 'abc', '-5', '10000', '5.555', '1,000', null]) expect(parseDollars(bad)).toBeNull()
  })
})

describe('the quick form', () => {
  const settings = DEFAULT_SHOP_SETTINGS
  const form = (over) => ({ ...blankEntry(settings, TODAY), clientName: 'Marcus Jones', ...over })

  it('offers his services, then After Hours Cuts', () => {
    const list = saleServices(settings)
    expect(list.slice(0, 5).map((s) => s.id)).toEqual(['mens-cut', 'mens-design', 'mens-beard-eyebrow', 'buzz-beard', 'kids-design'])
    expect(list.at(-1)).toMatchObject({ id: 'after-hours', name: 'After Hours Cuts', price: 70 })
  })

  it('starts on the first service, listed price, paid at the shop, today', () => {
    expect(blankEntry(settings, TODAY)).toMatchObject({ serviceId: 'mens-cut', priceMode: 'standard', payment: 'shop', dateKey: TODAY, clientName: '' })
  })

  it('makes the body for a listed-price sale', () => {
    expect(checkEntry(form(), settings, TODAY)).toEqual({
      ok: true,
      body: { serviceId: 'mens-cut', priceMode: 'standard', payment: 'shop', clientName: 'Marcus Jones', note: '', dateKey: TODAY },
    })
  })

  it('makes the body for a custom price paid online', () => {
    const r = checkEntry(form({ priceMode: 'custom', custom: '62.5', payment: 'online', note: ' beard too ' }), settings, TODAY)
    expect(r.body).toMatchObject({ priceMode: 'custom', amountCents: 6250, payment: 'online', note: 'beard too' })
  })

  it('a one-off service always needs a typed price', () => {
    expect(checkEntry(form({ serviceId: OTHER, otherName: 'Line up' }), settings, TODAY).errors.price).toBeTruthy()
    const r = checkEntry(form({ serviceId: OTHER, otherName: ' Line   up ', custom: '15' }), settings, TODAY)
    expect(r.body).toMatchObject({ serviceName: 'Line up', priceMode: 'custom', amountCents: 1500 })
    expect(r.body.serviceId).toBeUndefined()
    expect(checkEntry(form({ serviceId: OTHER, otherName: '', custom: '15' }), settings, TODAY).errors.service).toBeTruthy()
  })

  it('says what is wrong', () => {
    const r = checkEntry(form({ clientName: '  ', priceMode: 'custom', custom: 'abc', dateKey: '2026-10-23', note: 'x'.repeat(121) }), settings, TODAY)
    expect(r.ok).toBe(false)
    expect(Object.keys(r.errors).sort()).toEqual(['client', 'date', 'note', 'price'])
    expect(checkEntry(form({ serviceId: 'gone' }), settings, TODAY).errors.service).toBeTruthy()
  })
})

describe('date ranges', () => {
  it('counts today', () => {
    expect(rangeBounds('today', TODAY)).toEqual({ from: TODAY, to: TODAY })
    expect(rangeBounds('week', TODAY)).toEqual({ from: '2026-10-16', to: TODAY })
    expect(rangeBounds('30', TODAY)).toEqual({ from: '2026-09-23', to: TODAY })
    expect(rangeBounds('month', TODAY)).toEqual({ from: '2026-10-01', to: TODAY })
    expect(rangeBounds('all', TODAY)).toEqual({ from: '', to: '' })
  })
})

describe('filtering', () => {
  const ids = (rows) => rows.map((r) => r.id)

  it('finds by client, service, note, price and day, ignoring case', () => {
    expect(ids(filterSales(LOG, { query: 'MARCUS' }, TODAY))).toEqual(['a', 'c'])
    expect(ids(filterSales(LOG, { query: 'after hours' }, TODAY))).toEqual(['b'])
    expect(ids(filterSales(LOG, { query: 'beard' }, TODAY))).toEqual(['c'])
    expect(ids(filterSales(LOG, { query: '$62.50' }, TODAY))).toEqual(['c'])
    expect(ids(filterSales(LOG, { query: 'online' }, TODAY))).toEqual(['b', 'd'])
    expect(ids(filterSales(LOG, { query: 'marcus beard' }, TODAY))).toEqual(['c']) // every word must match
  })

  it('filters by service, how they paid and dates, together', () => {
    expect(ids(filterSales(LOG, { service: "Men's haircut" }, TODAY))).toEqual(['a', 'c'])
    expect(ids(filterSales(LOG, { payment: 'online' }, TODAY))).toEqual(['b', 'd'])
    expect(ids(filterSales(LOG, { range: 'week' }, TODAY))).toEqual(['a', 'b']) // the 16th to today, so the 15th is out
    expect(ids(filterSales(LOG, { range: 'today' }, TODAY))).toEqual(['a'])
    expect(ids(filterSales(LOG, { payment: 'online', range: 'week' }, TODAY))).toEqual(['b'])
    expect(filterSales(LOG, {}, TODAY)).toHaveLength(4)
  })
})

describe('sorting', () => {
  const names = (rows) => rows.map((r) => r.clientName)

  it('puts the highest sales first, ties newest first', () => {
    expect(names(sortSales(LOG, 'amount', 'desc'))).toEqual(['Dre Williams', 'marcus jones', 'Marcus Jones', 'Kid Cam'])
    expect(names(sortSales(LOG, 'amount', 'asc'))[0]).toBe('Kid Cam')
  })

  it('sorts by date, client and service, and never changes the list it was given', () => {
    const copy = [...LOG]
    expect(names(sortSales(LOG, 'date', 'desc'))).toEqual(['Marcus Jones', 'Dre Williams', 'marcus jones', 'Kid Cam'])
    expect(names(sortSales(LOG, 'date', 'asc'))[0]).toBe('Kid Cam')
    expect(names(sortSales(LOG, 'client', 'asc'))[0]).toBe('Dre Williams')
    expect(sortSales(LOG, 'service', 'asc')[0].serviceName).toBe('After Hours Cuts')
    expect(LOG).toEqual(copy)
  })
})

describe('the numbers', () => {
  const m = salesMetrics(LOG)

  it('adds up the sales', () => {
    expect(m.count).toBe(4)
    expect(m.totalCents).toBe(5500 + 7000 + 6250 + 4000)
    expect(m.averageCents).toBe(Math.round(22750 / 4))
    expect(m.highest).toMatchObject({ amountCents: 7000, clientName: 'Dre Williams', serviceName: 'After Hours Cuts' })
    expect(m.customCount).toBe(1)
  })

  it('splits shop and online', () => {
    expect(m.shop).toEqual({ count: 2, cents: 11750 })
    expect(m.online).toEqual({ count: 2, cents: 11000 })
  })

  it('ranks services, clients (one person however the name is cased) and days', () => {
    expect(m.byService[0]).toEqual({ name: "Men's haircut", count: 2, cents: 11750 })
    expect(m.topClients[0]).toEqual({ name: 'Marcus Jones', count: 2, cents: 11750 })
    expect(m.clientCount).toBe(3)
    expect(m.repeatClients).toBe(1)
    expect(m.bestDay).toEqual({ name: '2026-10-21', count: 1, cents: 7000 })
  })

  it('copes with an empty log', () => {
    expect(salesMetrics([])).toMatchObject({ count: 0, totalCents: 0, averageCents: 0, highest: null, bestDay: null, byService: [], clientCount: 0 })
  })
})

describe('the download', () => {
  it('writes a header and one line per sale', () => {
    const csv = toCsv([LOG[2], LOG[0]])
    expect(csv.split('\r\n')).toEqual([
      'Date,Client,Service,Price,Payment,Custom price,Note',
      "2026-10-15,marcus jones,Men's haircut,62.50,At the shop,Yes,beard too",
      "2026-10-22,Marcus Jones,Men's haircut,55.00,At the shop,No,",
      '',
    ])
  })

  it('quotes commas and quotes, and defuses formulas', () => {
    const csv = toCsv([row({ clientName: 'Jones, "JJ"', note: '=SUM(A1)' })])
    expect(csv).toContain('"Jones, ""JJ"""')
    expect(csv).toContain("'=SUM(A1)")
  })
})
VICBLESS_EOF
cat > "$STAGE/18" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import LogoCheckerboard from '../components/LogoCheckerboard.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, LIMITS, SMS_CONSENT, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'
import { clearPending, loadPending, readReturn, savePending, tabStorage } from '../lib/paymentReturn.js'
import { AFTER_HOURS_ID, afterCount, afterDays, bookableServices, hoursFor, isAfterStart, slotFor } from '../lib/shopSettings.js'
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
  const SERVICES = bookableServices(shop) // Vic's services, then After Hours Cuts
  const hours = useMemo(() => hoursFor(shop), [shop]) // opening hours with the late appointments added

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
  const [preselected] = useState(() => (resumed ? resumed.request.serviceId : serviceIdFromHash(window.location.hash, SERVICES)))
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
  const isAfter = !!service && service.afterHours === true // After Hours Cuts books only the late times, the others only regular ones
  const kindOf = (d, start) => isAfterStart(d, start) === isAfter

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
        hours,
        busy: busy[k] || [],
        now,
        slotMinutes: slotFor(shop, d),
      }).filter((start) => isAfterStart(d, start) === isAfter)
    }
    return out
  }, [busy, service, days, shop, hours, isAfter])

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

  function chooseService(id, keepDay = false) {
    if (id !== serviceId) {
      setTime(null)
      // late times are on different days than regular ones, so the first day with openings is picked again
      if (!keepDay && (id === AFTER_HOURS_ID) !== (serviceId === AFTER_HOURS_ID)) setDateKey(null)
    }
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
      ? startsForDay({ date: selectedDay, minutes: slotFor(shop, selectedDay), hours, slotMinutes: slotFor(shop, selectedDay) }).filter((m) => kindOf(selectedDay, m))
      : []
  const lateService = SERVICES.find((s) => s.afterHours) || null
  // On a day that has late times, someone looking at the regular times is told, with a way to see them.
  const lateHint = !isAfter && lateService && selectedDay && afterCount(shop, selectedDay) > 0

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
              className={s.afterHours ? 'opt opt-after' : 'opt'}
              aria-pressed={serviceId === s.id}
              onClick={() => chooseService(s.id)}
            >
              <span className="name">{s.name}</span>
              {s.afterHours && <span className="after-badge">After hours</span>}
              <span className="leader" />
              <span className="price">{priceLabel(s)}</span>
              {s.note && <span className="note">{s.note}</span>}
              {s.afterHours && <span className="note">After closing on {afterDays(shop).join(' and ')}.</span>}
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
                  const closed = !hours[d.getDay()] || !!availability[k]?.dayOff // shop closed that weekday, or Vic took the day off
                  const free = (slotsByDay[k] || []).length
                  const none = isAfter && !closed && afterCount(shop, d) === 0 // no late times that weekday
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
                      <span className="tag">{closed ? 'Closed' : none ? 'None' : free ? '' : 'Full'}</span>
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
                          className={isAfter ? 'time time-after' : 'time'}
                          aria-pressed={time === m}
                          disabled={!open}
                          onClick={() => {
                            setTime(m)
                            setNotice('')
                          }}
                        >
                          {fmtTime(m)}
                          {isAfter && <span className="time-tag">After hours</span>}
                          {!open && <span className="sr-only"> (unavailable)</span>}
                        </button>
                      )
                    })}
                  </div>
                  {daySlots.length < dayStarts.length && <p className="times-note">Greyed-out times are not available.</p>}
                  {isAfter && (
                    <p className="times-note">
                      After hours cuts are ${service.price}, any service included. Just need a regular cut?{' '}
                      <button type="button" className="link-btn" onClick={() => chooseService(SERVICES.find((s) => !s.afterHours).id)}>
                        Pick a regular service
                      </button>
                    </p>
                  )}
                </>
              )}
              {lateHint && (
                <div className="late-hint">
                  <span className="after-badge">After hours</span>
                  <p>
                    Need a later time? {lateService.name} are after closing, {priceLabel(lateService)}, any service included.
                  </p>
                  <button type="button" className="btn" onClick={() => chooseService(lateService.id, true)}>
                    See late times
                  </button>
                </div>
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
                <span>
                  {service.name} ({slotFor(shop, fromKey(dateKey))} min), {priceLabel(service)}
                </span>
                {isAfter && <span className="after-badge after-badge-below">After hours</span>}
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
cat > "$STAGE/19" <<'VICBLESS_EOF'
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

/* After Hours Cuts: always outlined in purple with an "After hours" label, so it never looks like a regular time. */
.after-badge {
  display: inline-block;
  padding: 2px 9px;
  font-size: 0.68rem;
  font-weight: 800;
  line-height: 1.4;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--accent);
  border: 1.5px solid var(--accent);
  border-radius: 999px;
  white-space: nowrap;
}

/* Under a line of text (the booking summary, a dashboard card), on its own line with room above it. */
.after-badge-below {
  display: block;
  width: fit-content;
  margin-top: 8px;
}

.opt-after {
  border-color: var(--accent);
  box-shadow: 0 0 0 1px var(--accent), 0 0 18px -6px var(--accent);
}

.opt-after .after-badge {
  align-self: center;
}

.time-after {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 3px;
  border-color: var(--accent);
  box-shadow: 0 0 0 1px var(--accent), 0 0 14px -6px var(--accent);
}

.time-tag {
  font-size: 0.6rem;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--accent);
}

.time-after[aria-pressed='true'] .time-tag {
  color: inherit;
}

.time-after:disabled {
  box-shadow: none;
}

.late-hint {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 12px;
  margin-top: 16px;
  padding: 12px 14px;
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.late-hint p {
  flex: 1 1 200px;
  margin: 0;
  font-size: 0.92rem;
}

.link-btn {
  padding: 0;
  font: inherit;
  color: var(--accent);
  text-decoration: underline;
  background: none;
  border: 0;
  cursor: pointer;
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
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"dccf4f95af32e3ed7ec4448d9b244584d9716ac0350a14e149a58166e0bff9fc\", \"new\": 0}, {\"path\": \"backend/app/database/keys.py\", \"base\": \"eae4c1725caf40aeb172f76b9f729177ad8bde7b1351edf445c10b7c7b9288dd\", \"new\": 1}, {\"path\": \"backend/app/database/sales.py\", \"base\": null, \"new\": 2}, {\"path\": \"backend/app/domain/sales.py\", \"base\": null, \"new\": 3}, {\"path\": \"backend/app/routes/admin.py\", \"base\": \"e556781a64f74654dcef2e34eb4ef7e7ba3c3df793d8bf52a98be5ae40e46aa0\", \"new\": 4}, {\"path\": \"backend/app/schemas/requests.py\", \"base\": \"b92270838e3e1554aa85c636003d719d6b23558f51daa6715f5cbe1dfbdb931f\", \"new\": 5}, {\"path\": \"backend/app/services/sales.py\", \"base\": null, \"new\": 6}, {\"path\": \"backend/tests/test_sales.py\", \"base\": null, \"new\": 7}, {\"path\": \"frontend/src/admin/Admin.jsx\", \"base\": \"5fa9c386ef2faeeffd140ad6cb27aeea9f723b042810c183a239cddf4cb679ac\", \"new\": 8}, {\"path\": \"frontend/src/admin/SalesPage.jsx\", \"base\": null, \"new\": 9}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"7eaf86398929dc52bd6cf698d2438291db7a2ee52fea5ce13aab803485f3026c\", \"new\": 10}, {\"path\": \"frontend/src/admin/adminApi.js\", \"base\": \"3d92946a20b1a9c9d9ed22c916f1f2aa99720565bf7e9ccf370532bcb92c9051\", \"new\": 11}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"447ff817a703844f96309dc1ddee8912a82871fb6af1aa16bdd9d2dbc286d736\", \"new\": 12}, {\"path\": \"frontend/src/admin/realAdminApi.js\", \"base\": \"4903750f35fb8ffbfd569939d250261d45d59771300e813d7b5dd0b332605890\", \"new\": 13}, {\"path\": \"frontend/src/admin/realAdminApi.test.js\", \"base\": \"198dbfca1989b9d6e1e005fb185008730bcdae20bddd3f9f21f88a0bf8782463\", \"new\": 14}, {\"path\": \"frontend/src/lib/mockStore.js\", \"base\": \"adc2faab0aac454342d312653d03aa555190bf3e1d5ebbea3e5918b94da021e4\", \"new\": 15}, {\"path\": \"frontend/src/lib/sales.js\", \"base\": null, \"new\": 16}, {\"path\": \"frontend/src/lib/sales.test.js\", \"base\": null, \"new\": 17}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"29c1d75dcbb01b4fa887139c99c2f325051ed765966415fd239c7fcebc5cc7d8\", \"new\": 18}, {\"path\": \"frontend/src/styles.css\", \"base\": \"3d797972f08e72b9d93d53ba3b6d64a70ffbc26c2793cf93ae262f913b7dae73\", \"new\": 19}]")

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
echo "Next: deploy the backend and the site, then open the dashboard and tap Sales log."
