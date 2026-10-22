#!/usr/bin/env bash
# Sales log: Edit button, separate sales database, line graph
# Run from the REPO ROOT:  bash vicbless-sales-edit-chart.sh
#
# Adds an Edit button to the Sales log, moves sales into their own DynamoDB table (SalesTable), and adds an on-brand line graph under the numbers with week/month/3 months/year filters.
# After deploying the backend, if you logged sales before this, run: python scripts/migrate_sales_table.py --env prod --apply
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

- `GET /api/admin/sales` lists the whole log, newest first. `POST /api/admin/sales` adds a line. `PUT /api/admin/sales/{id}` changes one (the Edit button; the body is the same as for adding). `DELETE /api/admin/sales/{id}` removes one (for a mistake). All need Vic's sign-in.
- A listed price is read from his settings on the server (After Hours Cuts included), never trusted from the screen. A one-off service (typed name) needs a typed price. A sale can't be dated in the future or more than a year back.
- **Its own table.** Sales live in `vicbless-sales-<env>` (`SalesTable` in `infra/template.yaml`, env `SALES_TABLE_NAME`), not in the bookings table. Partition `SALES#vic`, sort key `<day>#<id>`, no expiry, so the log is a permanent record (bookings disappear after 90 days). The table is retained when the stack is deleted, and in prod it has deletion protection and point-in-time recovery.
- Editing a sale on the same day rewrites the line under the same id. Moving it to another day changes its sort key, so the old line is deleted and a new one written in one transaction, and the answer carries the new id. A line that no longer exists answers 404.
- **Moving old sales.** If sales were logged before the new table existed they are still in the bookings table as `SALE#...` items. After deploying, run `python scripts/migrate_sales_table.py --env dev` (or `prod`) to see what would move, then add `--apply` to move them. It is safe to run twice.
- Search, filters, sorting, the numbers, the line graph and the Excel download all happen in the dashboard from the list this returns.

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
"""Settings and secrets.

Plain settings come from environment variables set by the SAM template. Secrets and owner settings
live in SSM Parameter Store under /vicbless/<environment>/ and are cached briefly in memory.
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass

from . import aws
from .logs import log

# How long a secret stays cached in memory. Reading from AWS on every request would be slow and cost money;
# five minutes means a changed secret takes effect within five minutes without a redeploy.
PARAM_TTL_SECONDS = 300


@dataclass(frozen=True)
class Settings:
    """Plain (non-secret) settings, set as environment variables by the SAM template."""

    environment: str
    table_name: str
    sales_table_name: str  # Vic's sales log lives in its own table, apart from the bookings
    cors_origins: tuple[str, ...]
    email_provider: str
    sms_provider: str

    @property
    def ssm_prefix(self) -> str:
        return f"/vicbless/{self.environment}"


def get_settings() -> Settings:
    """Reads the settings fresh each time (cheap), so tests can change environment variables freely."""
    origins = tuple(o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip())
    return Settings(
        environment=os.environ.get("ENVIRONMENT", "dev"),
        table_name=os.environ.get("TABLE_NAME", "vicbless-dev"),
        sales_table_name=os.environ.get("SALES_TABLE_NAME", "vicbless-sales-dev"),
        cors_origins=origins,
        email_provider=os.environ.get("EMAIL_PROVIDER", "resend").strip().lower(),
        sms_provider=os.environ.get("SMS_PROVIDER", "textbelt").strip().lower(),
    )


class ParamStore:
    """Reads SSM parameters with a short cache. A missing parameter returns None and is cached too."""

    def __init__(self, ttl: int = PARAM_TTL_SECONDS):
        self.ttl = ttl
        self._cache: dict[str, tuple[float, str | None]] = {}
        self._lock = threading.Lock()

    def get(self, name: str) -> str | None:
        full = f"{get_settings().ssm_prefix}/{name}"
        now = time.monotonic()
        with self._lock:
            hit = self._cache.get(full)
            if hit and now - hit[0] < self.ttl:
                return hit[1]
        value: str | None
        try:
            value = aws.ssm_client().get_parameter(Name=full, WithDecryption=True)["Parameter"]["Value"]
        except Exception as exc:  # missing parameter, no permission, or AWS hiccup
            code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")
            if code != "ParameterNotFound":
                # a real failure (permissions, AWS hiccup) is not cached as "missing" for five minutes
                log("param_error", name=name, code=code or type(exc).__name__)
                raise
            log("param_missing", name=name)  # the name only, never the value. Shows up once per five minutes at most
            value = None
        with self._lock:
            self._cache[full] = (now, value)
        return value

    def reset(self) -> None:
        with self._lock:
            self._cache.clear()


params = ParamStore()


_reset_hooks: list = []


def on_reset(hook) -> None:
    """Lets another module (for example the settings cache) be cleared together with the rest by reset_caches()."""
    _reset_hooks.append(hook)


def reset_caches() -> None:
    """Forget cached clients, parameters and anything registered with on_reset. Tests call this between cases."""
    aws.reset_clients()
    params.reset()
    for hook in _reset_hooks:
        hook()
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 5 minute unit (a 45 minute booking holds nine)
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
    HOLD#<until, ISO UTC>#<booking id>    an unpaid online booking whose time is held until <until> (a sweep finds the
                                          old ones; "HOLD#" sorts after every date, so a day's range never includes it)
    SETTINGS                              Vic's settings (services, prices, appointment lengths). It has no date in front,
                                          so it never shows up in a day's range and never expires.
Failed-login counters live under their own partition key (LOCK#...).

Vic's sales log is NOT in this table. It has its own table (the SalesTable of the template), where the partition key is
SALES_PK and the sort key is "<day>#<sale id>". It never expires, unlike bookings that disappear after 90 days.
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


SALES_PK = f"SALES#{shop.STAFF_ID}"  # the one partition of the sales table


def sale_sk(day: date, sale_id: str) -> str:
    """The sort key of one line of the sales log, in the sales table. It sorts by day."""
    return f"{day.isoformat()}#{sale_id}"


def block_sk(day: date, start: int, block_id: str) -> str:
    return f"{day.isoformat()}#BLOCK#{shop.hhmm(start)}#{block_id}"


def minutes_of(hhmm: str) -> int:
    """'1235' -> 755 minutes after midnight (the reverse of shop.hhmm)."""
    return int(hhmm[:2]) * 60 + int(hhmm[2:])
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Vic's sales log in its own table (apart from the bookings): add a line, list them all, change one, remove one."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import NotFound
from ..domain.sales import Sale, parse_sale_id
from . import keys, table
from .keys import SALES_PK

NOT_FOUND = "That sale was not found. It may already be removed."


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


def item_for(sale: Sale) -> dict:
    return {
        "pk": SALES_PK,
        "sk": keys.sale_sk(sale.day, sale.id),
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
    }


def add(sale: Sale) -> Sale:
    table.sales_table().put_item(Item=item_for(sale), ConditionExpression="attribute_not_exists(pk)")
    return sale


def get(sale_id: str) -> Sale | None:
    day = parse_sale_id(sale_id)
    if day is None:
        return None
    item = table.sales_table().get_item(Key={"pk": SALES_PK, "sk": keys.sale_sk(day, sale_id)}, ConsistentRead=True).get("Item")
    return sale_from(item) if item else None


def list_all() -> list[Sale]:
    """Every line of the log, newest first (by day, then by when it was logged). Follows DynamoDB's paging."""
    kwargs: dict = {"KeyConditionExpression": "pk = :pk", "ExpressionAttributeValues": {":pk": SALES_PK}, "ConsistentRead": True}
    sales: list[Sale] = []
    while True:
        page = table.sales_table().query(**kwargs)
        sales.extend(sale_from(item) for item in page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    sales.sort(key=lambda s: (s.day, s.created_at), reverse=True)
    return sales


def replace(old: Sale, new: Sale) -> Sale:
    """Swaps a line for its edited version. The same day keeps the same item; a different day is a different sort key, so
    the old item is deleted and the new one written in ONE transaction (never both, never neither)."""
    try:
        if old.id == new.id:
            table.sales_table().put_item(Item=item_for(new), ConditionExpression="attribute_exists(pk)")
        else:
            name = table.sales_table_name()
            table.sales_table().meta.client.transact_write_items(
                TransactItems=[
                    {"Delete": {"TableName": name, "Key": {"pk": SALES_PK, "sk": keys.sale_sk(old.day, old.id)}, "ConditionExpression": "attribute_exists(pk)"}},
                    {"Put": {"TableName": name, "Item": item_for(new), "ConditionExpression": "attribute_not_exists(pk)"}},
                ]
            )
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") in ("ConditionalCheckFailedException", "TransactionCanceledException"):
            raise NotFound(NOT_FOUND) from None  # the line was removed a moment ago
        raise
    return new


def remove(sale_id: str) -> Sale:
    day = parse_sale_id(sale_id)
    if day is None:
        raise NotFound(NOT_FOUND)
    gone = table.sales_table().delete_item(Key={"pk": SALES_PK, "sk": keys.sale_sk(day, sale_id)}, ReturnValues="ALL_OLD").get("Attributes")
    if not gone:
        raise NotFound(NOT_FOUND)
    return sale_from(gone)
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""The one DynamoDB table, and its name."""

from __future__ import annotations

from ..core import aws, config


def table():
    """The table object. Looked up on each call so tests (and the Lambda) always use the current settings."""
    return aws.dynamodb_resource().Table(config.get_settings().table_name)


def client():
    """The low-level client, needed for transactions (the table object can't run them)."""
    return table().meta.client


def table_name() -> str:
    return config.get_settings().table_name


def sales_table():
    """The sales log's own table (kept apart from the bookings table, so the log is never touched by booking clean-up)."""
    return aws.dynamodb_resource().Table(config.get_settings().sales_table_name)


def sales_table_name() -> str:
    return config.get_settings().sales_table_name
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
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


@router.put("/sales/{sale_id}")
def edit_sale(sale_id: str, body: SaleIn) -> dict:
    """Changes a line of the log. The answer is the line as it is now (its id changes only if its day did)."""
    return sales_service.update_sale(sale_id, body, shop.now_local()).admin_view()


@router.delete("/sales/{sale_id}")
def remove_sale(sale_id: str) -> dict:
    """Removes a line of the log (for a mistake)."""
    sales_service.remove_sale(sale_id)
    return {"removed": True}
VICBLESS_EOF
cat > "$STAGE/6" <<'VICBLESS_EOF'
"""Vic's sales log in action: log a sale, list them, remove one."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..core.errors import NotFound, ValidationFailed
from ..core.logs import log
from ..database import sales as sales_db
from ..domain import shop
from ..domain.sales import Sale, new_sale_id, parse_sale_id
from ..schemas.requests import MSG_SALE_AMOUNT, MSG_SALE_SERVICE, SaleIn, parse_date_key
from . import settings as settings_service

MAX_DAYS_BACK = 366  # a sale can be logged for any day in the last year


def _build(data: SaleIn, now: datetime, *, sale_id: str | None, created_at: str, same_day: date | None = None) -> Sale:
    """Turns what Vic picked into a line of the log. The listed price is read from his settings here, never trusted
    from the screen, and a sale can't be dated in the future. `sale_id` is kept when a line is edited on its own day."""
    today = shop.today(now)
    day = parse_date_key(data.dateKey) if data.dateKey else (same_day or today)
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

    return Sale(
        id=sale_id if sale_id and parse_sale_id(sale_id) == day else new_sale_id(day),
        day=day,
        service_id=service.id if service else "",
        service_name=name,
        amount_cents=amount,
        custom_price=custom,
        payment=data.payment,
        client_name=data.clientName,
        note=data.note or "",
        created_at=created_at,
    )


def add_sale(data: SaleIn, now: datetime) -> Sale:
    sale = sales_db.add(_build(data, now, sale_id=None, created_at=now.astimezone(timezone.utc).isoformat(timespec="seconds")))
    log("sale_logged", saleId=sale.id, amountCents=sale.amount_cents, payment=sale.payment, custom=sale.custom_price)
    return sale


def update_sale(sale_id: str, data: SaleIn, now: datetime) -> Sale:
    """Vic edits a line: everything on it can change. It keeps its place in the log (and its id) unless the day changes,
    which gives it a new id because the id carries the day. The old line is gone either way."""
    old = sales_db.get(sale_id)
    if old is None:
        raise NotFound(sales_db.NOT_FOUND)
    new = _build(data, now, sale_id=old.id, created_at=old.created_at, same_day=old.day)
    sales_db.replace(old, new)  # raises NotFound if the line was removed a moment ago
    log("sale_edited", saleId=new.id, amountCents=new.amount_cents, payment=new.payment, custom=new.custom_price)
    return new


def list_sales() -> list[Sale]:
    return sales_db.list_all()


def remove_sale(sale_id: str) -> Sale:
    sale = sales_db.remove(sale_id)
    log("sale_removed", saleId=sale.id)
    return sale
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
#!/usr/bin/env python3
"""One-time move: copy sales-log lines that were saved in the bookings table into the new, separate sales table.

    AWS_PROFILE=vicbless python backend/scripts/migrate_sales_table.py --env dev            # shows what it WOULD do
    AWS_PROFILE=vicbless python backend/scripts/migrate_sales_table.py --env dev --apply    # does it

Why: the first version of the sales log kept its lines in the same table as the bookings (sort keys starting "SALE#").
The log now has its own table (the SalesTable of the template), so it is never mixed with bookings that expire after
90 days. Only needed for an environment where lines were logged BEFORE the sales table existed; with nothing to move it
says so and does nothing.

Order of a release: 1) deploy the backend (this creates the sales table), 2) run this with --apply for that environment.
Safe to run twice: each line is written to the new table first and removed from the old one only after that worked, and a
line already in the new table is left as it is.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from botocore.exceptions import ClientError  # noqa: E402

from app.database import keys, table  # noqa: E402
from app.database.keys import PK, SALES_PK  # noqa: E402


def old_lines() -> list[dict]:
    """Every sales line still in the bookings table. Follows DynamoDB paging."""
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk AND begins_with(sk, :p)",
        "ExpressionAttributeValues": {":pk": PK, ":p": "SALE#"},
        "ConsistentRead": True,
    }
    found: list[dict] = []
    while True:
        page = table.table().query(**kwargs)
        found.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return found
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def migrate(apply: bool) -> dict:
    report = {"moved": 0, "already_there": 0}
    for item in old_lines():
        new_item = {k: v for k, v in item.items() if k not in ("kind", "expiresAt")}
        new_item["pk"] = SALES_PK
        new_item["sk"] = item["sk"].removeprefix("SALE#")
        label = f"{item.get('date')} {item.get('clientName')} ${int(item.get('amountCents', 0)) / 100:.2f}"
        if not apply:
            print(f"would move {label}")
            report["moved"] += 1
            continue
        try:
            table.sales_table().put_item(Item=new_item, ConditionExpression="attribute_not_exists(pk)")
        except ClientError as err:
            if err.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            report["already_there"] += 1  # copied by an earlier run that stopped before the clean-up
        else:
            report["moved"] += 1
            print(f"moved {label}")
        table.table().delete_item(Key={"pk": PK, "sk": item["sk"]})
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--apply", action="store_true", help="really write (without this it only shows what it would do)")
    args = parser.parse_args()

    os.environ["ENVIRONMENT"] = args.env
    os.environ["TABLE_NAME"] = f"vicbless-{args.env}"
    os.environ["SALES_TABLE_NAME"] = f"vicbless-sales-{args.env}"
    os.environ.setdefault("AWS_DEFAULT_REGION", args.region)

    report = migrate(args.apply)
    verb = "Moved" if args.apply else "Would move"
    print(f"\n{verb} {report['moved']} line(s); already in the sales table {report['already_there']}.")
    if not report["moved"] and not report["already_there"]:
        print("Nothing to move.")
    if not args.apply and report["moved"]:
        print("Run again with --apply to move them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
"""A fake AWS for every test (moto), with the table built from the real template."""

import boto3
import pytest
from moto import mock_aws

from app.core import config
from tests.helpers.constants import ENVIRONMENT, TEST_SALES_TABLE, TEST_TABLE
from tests.helpers.template import sales_table_definition, table_definition


@pytest.fixture(autouse=True)
def aws(monkeypatch):
    """Runs around EVERY test (autouse): fake credentials, fake AWS, a fresh table, clean caches.

    The app keeps AWS clients and settings in memory between calls (that is what makes the Lambda fast).
    Without the reset below, a client built against one test's fake AWS would leak into the next test.
    """
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_DEFAULT_REGION": "us-east-1",
        "ENVIRONMENT": ENVIRONMENT,
        "TABLE_NAME": TEST_TABLE,
        "SALES_TABLE_NAME": TEST_SALES_TABLE,
        "EMAIL_PROVIDER": "resend",
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("CORS_ALLOWED_ORIGINS", raising=False)
    config.reset_caches()
    with mock_aws():
        boto3.client("dynamodb").create_table(**table_definition(TEST_TABLE))
        boto3.client("dynamodb").create_table(**sales_table_definition(TEST_SALES_TABLE))
        yield
    config.reset_caches()


@pytest.fixture
def atomic_transactions(monkeypatch):
    """Makes the fake DynamoDB run one transaction at a time, the way the real one behaves.

    A real DynamoDB transaction is atomic: when two people try to claim the same time at once, it checks
    and writes as ONE step, so exactly one of them wins. moto (the fake) does not guarantee that when several
    threads call it together, so a concurrency test against it can fail at random (it did: two "winners").
    This lock gives the fake the guarantee the real service already has. What is still being tested is the
    app's own part: that it asks for "only if this claim does not exist yet", so the database can decide.
    """
    import threading

    from app.database import table

    lock = threading.Lock()
    real = table.client()

    class OneAtATime:
        def __getattr__(self, name):
            return getattr(real, name)

        def transact_write_items(self, **kwargs):
            with lock:
                return real.transact_write_items(**kwargs)

    monkeypatch.setattr(table, "client", lambda: OneAtATime())
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
"""Small helpers for the fake AWS."""

import boto3

from app.core import config

from .constants import ENVIRONMENT


def put_param(name: str, value: str, *, secure: bool = True) -> None:
    """Stores a setting the way the deploy would: /vicbless/<env>/<name> in Parameter Store."""
    boto3.client("ssm").put_parameter(
        Name=f"/vicbless/{ENVIRONMENT}/{name}",
        Value=value,
        Type="SecureString" if secure else "String",
        Overwrite=True,
    )
    config.params.reset()  # the app caches settings for 5 minutes; forget so the new value is seen at once


def raw_table():
    """The table object, for tests that need to look at exactly what was stored."""
    return boto3.resource("dynamodb").Table("vicbless-test")


def raw_sales_table():
    """The sales log's own table, for tests that need to look at exactly what was stored."""
    return boto3.resource("dynamodb").Table("vicbless-sales-test")
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
"""Fixed values the tests share, so every test talks about the same "today", password and table."""

from datetime import datetime

from app.domain import shop

# The tests pretend it is Monday 12 Oct 2026, 10:00 am in the shop's timezone. A fixed "now" means a
# test about "tomorrow" or "14 days ahead" gives the same answer next year as it does today.
NOW = datetime(2026, 10, 12, 10, 0, tzinfo=shop.TIMEZONE)

TEST_TABLE = "vicbless-test"
TEST_SALES_TABLE = "vicbless-sales-test"
ENVIRONMENT = "dev"

# Dates relative to NOW that the tests use a lot.
MONDAY = "2026-10-12"  # today
TUESDAY = "2026-10-13"  # open 12:00 to 6:00 pm
WEDNESDAY = "2026-10-14"  # closed
SATURDAY = "2026-10-17"  # two windows with a lunch gap

# Sign-in secrets. The password hash is made with 1,000 rounds (not 600,000) so each test stays fast.
ADMIN_PASSWORD = "correct horse battery"
PEPPER = "test-pepper-value"
JWT_SECRET = "j" * 40
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
"""Reads infra/template.yaml so the tests can build their fake table from the REAL table definition.

If the table's keys or index ever change in the template, the tests change with it. They can't pass
against a table shape that isn't the one that gets deployed.
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]  # the repo root
TEMPLATE_PATH = ROOT / "infra" / "template.yaml"


class _CloudFormationLoader(yaml.SafeLoader):
    """YAML loader that tolerates CloudFormation's short tags (!Ref, !Sub, !If ...) by keeping them as plain data."""


def _keep_tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {suffix: loader.construct_sequence(node, deep=True)}
    return {suffix: loader.construct_mapping(node, deep=True)}


_CloudFormationLoader.add_multi_constructor("!", _keep_tag)


def load_template() -> dict:
    return yaml.load(TEMPLATE_PATH.read_text(), Loader=_CloudFormationLoader)


def table_definition(table_name: str) -> dict:
    """The arguments boto3's create_table needs, taken from the template's Table resource."""
    props = load_template()["Resources"]["Table"]["Properties"]
    return {
        "TableName": table_name,
        "BillingMode": props["BillingMode"],
        "AttributeDefinitions": props["AttributeDefinitions"],
        "KeySchema": props["KeySchema"],
        "GlobalSecondaryIndexes": props["GlobalSecondaryIndexes"],
    }


def sales_table_definition(table_name: str) -> dict:
    """The same, for the sales log's own table (the template's SalesTable resource)."""
    props = load_template()["Resources"]["SalesTable"]["Properties"]
    return {
        "TableName": table_name,
        "BillingMode": props["BillingMode"],
        "AttributeDefinitions": props["AttributeDefinitions"],
        "KeySchema": props["KeySchema"],
    }
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
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


def test_the_log_lives_in_its_own_table_and_never_expires(client, auth):
    from tests.helpers.aws import raw_sales_table, raw_table

    add(client, auth)
    sales = raw_sales_table().scan()["Items"]
    assert len(sales) == 1 and "expiresAt" not in sales[0] and sales[0]["pk"] == "SALES#vic"
    assert not [i for i in raw_table().scan()["Items"] if "sale" in str(i.get("sk", "")).lower()]  # nothing in the bookings table


# --- editing a line ----------------------------------------------------------------------------------------


def edit(client, auth, sale_id, **over):
    return client.put(f"/api/admin/sales/{sale_id}", headers=auth, json=sale_body(**over))


def test_a_line_can_be_edited_in_place(client, auth):
    first = add(client, auth, clientName="Typo Tim", note="old").json()
    r = edit(client, auth, first["id"], clientName="Tim Fixed", serviceId="mens-design", payment="online", note="new")
    assert r.status_code == 200, r.text
    [row] = log_of(client, auth)
    assert row["id"] == first["id"] and r.json() == row  # the same day keeps the same id
    assert row["clientName"] == "Tim Fixed" and row["serviceName"] == "Men's haircut with design" and row["amountCents"] == 6500
    assert row["payment"] == "online" and row["note"] == "new" and row["createdAt"] == first["createdAt"]


def test_an_edit_can_switch_to_a_custom_price_and_back(client, auth):
    sale = add(client, auth).json()
    edit(client, auth, sale["id"], priceMode="custom", amountCents=6250)
    assert (log_of(client, auth)[0]["amountCents"], log_of(client, auth)[0]["customPrice"]) == (6250, True)
    edit(client, auth, sale["id"])
    assert (log_of(client, auth)[0]["amountCents"], log_of(client, auth)[0]["customPrice"]) == (5500, False)


def test_an_edit_can_change_a_service_into_a_one_off(client, auth):
    sale = add(client, auth).json()
    edit(client, auth, sale["id"], serviceId=None, serviceName="Line up only", priceMode="custom", amountCents=1500)
    [row] = log_of(client, auth)
    assert row["serviceId"] == "" and row["serviceName"] == "Line up only" and row["amountCents"] == 1500


def test_changing_the_day_moves_the_line_and_gives_it_a_new_id(client, auth):
    sale = add(client, auth).json()
    r = edit(client, auth, sale["id"], dateKey="2026-10-09")
    assert r.status_code == 200, r.text
    [row] = log_of(client, auth)  # one line, not two
    assert row["dateKey"] == "2026-10-09" and row["id"] != sale["id"] and row["id"].startswith("2026-10-09.sale.")
    assert r.json()["id"] == row["id"] and row["createdAt"] == sale["createdAt"]
    assert edit(client, auth, sale["id"]).status_code == 404  # the old id is gone


def test_an_edit_that_leaves_the_day_out_keeps_the_lines_own_day(client, auth):
    sale = add(client, auth, dateKey="2026-10-09").json()
    r = edit(client, auth, sale["id"], clientName="Same Day")
    assert r.status_code == 200 and log_of(client, auth)[0]["dateKey"] == "2026-10-09" and r.json()["id"] == sale["id"]


def test_a_bad_edit_changes_nothing(client, auth):
    sale = add(client, auth).json()
    for bad in ({"clientName": ""}, {"dateKey": "2026-10-13"}, {"priceMode": "custom"}, {"serviceId": "nope"}):
        assert edit(client, auth, sale["id"], **bad).status_code == 422
    assert log_of(client, auth) == [sale]


def test_editing_a_missing_line_is_not_found(client, auth):
    assert edit(client, auth, "2026-10-12.sale.abcdef12").status_code == 404
    assert edit(client, auth, "not-an-id").status_code == 404


def test_editing_needs_sign_in(client, admin_setup):
    assert client.put("/api/admin/sales/2026-10-12.sale.abcdef12", json=sale_body()).status_code == 401


# --- the one-time move from the bookings table --------------------------------------------------------------


def old_line(day="2026-10-10", name="Old Olly"):
    return {
        "pk": "STAFF#vic", "sk": f"SALE#{day}#{day}.sale.0a0b0c0d", "kind": "sale", "id": f"{day}.sale.0a0b0c0d", "date": day,
        "serviceId": "mens-cut", "serviceName": "Men's haircut", "amountCents": 5500, "customPrice": False, "payment": "shop",
        "clientName": name, "note": "", "createdAt": f"{day}T15:00:00+00:00",
    }  # fmt: skip


def test_lines_saved_in_the_bookings_table_move_to_the_sales_table(client, auth):
    import runpy
    from pathlib import Path

    from tests.helpers.aws import raw_sales_table, raw_table

    script = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts" / "migrate_sales_table.py"))
    raw_table().put_item(Item=old_line())
    assert script["migrate"](False) == {"moved": 1, "already_there": 0}  # a dry run changes nothing
    assert len(raw_table().scan()["Items"]) == 1 and raw_sales_table().scan()["Items"] == []
    assert script["migrate"](True) == {"moved": 1, "already_there": 0}
    assert [i for i in raw_table().scan()["Items"] if i["sk"].startswith("SALE#")] == []
    [row] = log_of(client, auth)  # and the dashboard sees it
    assert row["clientName"] == "Old Olly" and row["dateKey"] == "2026-10-10" and row["amountCents"] == 5500
    assert script["migrate"](True) == {"moved": 0, "already_there": 0}  # nothing left, safe to run again


def test_a_move_that_stopped_halfway_finishes_cleanly(client, auth):
    import runpy
    from pathlib import Path

    from tests.helpers.aws import raw_sales_table, raw_table

    script = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts" / "migrate_sales_table.py"))
    line = old_line()
    raw_table().put_item(Item=line)
    copy = {k: v for k, v in line.items() if k not in ("kind",)} | {"pk": "SALES#vic", "sk": line["sk"].removeprefix("SALE#")}
    raw_sales_table().put_item(Item=copy)  # copied, but the old one was never removed
    assert script["migrate"](True) == {"moved": 0, "already_there": 1}
    assert len(log_of(client, auth)) == 1 and [i for i in raw_table().scan()["Items"] if i["sk"].startswith("SALE#")] == []
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
"""Checks on infra/template.yaml, the one template for both environments."""

import pytest

from tests.helpers.template import ROOT, TEMPLATE_PATH, load_template

TEMPLATE = TEMPLATE_PATH


@pytest.fixture(scope="module")
def t():
    return load_template()


def test_function_settings(t):
    fn = t["Resources"]["ApiFunction"]["Properties"]
    assert t["Globals"]["Function"]["MemorySize"] == 1024
    assert t["Globals"]["Function"]["Runtime"] == "python3.12"
    assert fn["Handler"] == "app.handler.lambda_handler"
    assert (TEMPLATE.parent / fn["CodeUri"]).resolve() == (ROOT / "backend")
    assert (ROOT / "backend" / "app" / "handler.py").exists()


def test_no_codedeploy_anywhere(t):
    text = TEMPLATE.read_text()
    for word in ("AutoPublishAlias", "DeploymentPreference", "CodeDeploy", "AWS::Lambda::Alias"):
        assert word not in text


def test_no_docs_route_and_only_api_paths(t):
    events = t["Resources"]["ApiFunction"]["Properties"]["Events"]
    paths = {e["Properties"]["Path"] for e in events.values() if e["Type"] == "HttpApi"}
    assert paths == {"/api", "/api/{proxy+}", "/api/admin/login"}


def test_reminders_run_on_a_schedule_and_text_provider_is_set(t):
    fn = t["Resources"]["ApiFunction"]["Properties"]
    schedules = [e for e in fn["Events"].values() if e["Type"] == "Schedule"]
    assert len(schedules) == 1 and schedules[0]["Properties"]["Schedule"] == "rate(15 minutes)"
    assert fn["Environment"]["Variables"]["SMS_PROVIDER"] == "textbelt"


def test_table(t):
    table = t["Resources"]["Table"]
    p = table["Properties"]
    assert table["DeletionPolicy"] == "Retain" and p["BillingMode"] == "PAY_PER_REQUEST"
    assert p["TimeToLiveSpecification"] == {"AttributeName": "expiresAt", "Enabled": True}
    assert [g["IndexName"] for g in p["GlobalSecondaryIndexes"]] == ["gsi1"]
    assert "IsProd" in str(p["PointInTimeRecoverySpecification"]) and "IsProd" in str(p["DeletionProtectionEnabled"])


def test_the_sales_log_has_its_own_table(t):
    res = t["Resources"]
    sales = res["SalesTable"]
    p = sales["Properties"]
    assert sales["DeletionPolicy"] == "Retain" and p["BillingMode"] == "PAY_PER_REQUEST"
    assert "vicbless-sales-" in str(p["TableName"]) and "TimeToLiveSpecification" not in p  # permanent, never expires
    assert "IsProd" in str(p["PointInTimeRecoverySpecification"]) and "IsProd" in str(p["DeletionProtectionEnabled"])
    assert [k["AttributeName"] for k in p["KeySchema"]] == ["pk", "sk"] and "GlobalSecondaryIndexes" not in p
    fn = res["ApiFunction"]["Properties"]
    assert fn["Environment"]["Variables"]["SALES_TABLE_NAME"] == {"Ref": "SalesTable"}
    assert any("SalesTable.Arn" in str(r) for r in fn["Policies"][0]["Statement"][0]["Resource"])
    assert "SalesTableName" in t["Outputs"]


def test_environments_and_params(t):
    assert t["Parameters"]["Environment"]["AllowedValues"] == ["dev", "prod"]
    assert set(t["Parameters"]) == {"Environment", "CorsAllowedOrigins"}  # the deploy workflow passes exactly these


def test_permissions_are_scoped(t):
    statements = t["Resources"]["ApiFunction"]["Properties"]["Policies"][0]["Statement"]
    actions = {a for s in statements for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}
    assert "dynamodb:Scan" not in actions and "ssm:GetParametersByPath" not in actions
    assert not any(a.endswith(":*") for a in actions)
    assert "dynamodb:Query" in actions and "ssm:GetParameter" in actions
    assert "Resource" in statements[1] and "*" not in str(statements[1]["Resource"]).replace("/vicbless/${Environment}/*", "")


def test_login_is_throttled_hard(t):
    rs = t["Resources"]["HttpApi"]["Properties"]["RouteSettings"]["POST /api/admin/login"]
    assert rs["ThrottlingRateLimit"] <= 5 and rs["ThrottlingBurstLimit"] <= 10


def test_outputs(t):
    assert {"ApiUrl", "ApiDomainName", "TableName", "FunctionName"} <= set(t["Outputs"])


def test_log_retention(t):
    lg = t["Resources"]["ApiLogGroup"]
    assert lg["Properties"]["RetentionInDays"] == 14 and lg["DeletionPolicy"] == "Retain"
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { money } from '../lib/sales.js'
import { PERIODS, axisLabel, buildSeries, niceScale } from '../lib/salesChart.js'

const HEIGHT = 230
const PAD = { top: 14, right: 16, bottom: 28, left: 46 }
const METRICS = [
  { id: 'sales', label: 'Sales' },
  { id: 'clients', label: 'Clients' },
]

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`

// The line graph under the numbers: sales (or number of clients) over a period Vic picks. One line, one axis. Hover or
// touch a point for the exact figure; arrow keys move along it; "Show as a table" lists the same numbers.
export default function SalesChart({ rows, today }) {
  const uid = useId()
  const [period, setPeriod] = useState('this-week')
  const [metric, setMetric] = useState('sales')
  const [active, setActive] = useState(null) // index of the point being looked at
  const [table, setTable] = useState(false)
  const [width, setWidth] = useState(640)
  const box = useRef(null)

  useEffect(() => {
    const el = box.current
    if (!el) return undefined
    const measure = () => setWidth(Math.max(260, Math.round(el.getBoundingClientRect().width)) || 640)
    measure()
    if (typeof ResizeObserver === 'undefined') return undefined
    const watcher = new ResizeObserver(measure)
    watcher.observe(el)
    return () => watcher.disconnect()
  }, [])

  const series = useMemo(() => buildSeries(rows, period, today, metric), [rows, period, today, metric])
  const points = series.buckets
  const value = (b) => (metric === 'clients' ? b.count : b.cents / 100)
  const past = points.filter((b) => !b.future)
  const top = Math.max(0, ...past.map(value))
  const scale = niceScale(top)
  const inner = { w: width - PAD.left - PAD.right, h: HEIGHT - PAD.top - PAD.bottom }
  const x = (i) => PAD.left + (points.length === 1 ? inner.w / 2 : (i / (points.length - 1)) * inner.w)
  const y = (v) => PAD.top + inner.h - (v / scale.max) * inner.h
  const xy = past.map((b, i) => [x(i), y(value(b))])
  const line = xy.map(([px, py], i) => `${i ? 'L' : 'M'}${px.toFixed(1)} ${py.toFixed(1)}`).join(' ')
  const area = xy.length > 1 ? `${line} L${xy[xy.length - 1][0].toFixed(1)} ${y(0)} L${xy[0][0].toFixed(1)} ${y(0)} Z` : ''
  const empty = past.every((b) => b.count === 0)

  // Which x labels fit: about one every 44px, always the first.
  const every = Math.max(1, Math.ceil(points.length / Math.max(2, Math.floor(inner.w / 44))))
  const labelled = (i) => i % every === 0

  const shown = (n) => (metric === 'clients' ? plural(n, 'client', 'clients') : money(n))
  const total = metric === 'clients' ? plural(series.count, 'client', 'clients') : money(series.totalCents)
  const label = PERIODS.find((p) => p.id === period).label
  const change = series.changePct
  const changeText =
    change === null
      ? series.beforeEmpty && (series.totalCents > 0 || series.count > 0)
        ? `Nothing to compare with ${series.compareLabel}`
        : ''
      : change === 0
        ? `Same as ${series.compareLabel}`
        : `${change > 0 ? '▲' : '▼'} ${Math.abs(change)}% vs ${series.compareLabel}`

  function nearest(event) {
    const rect = event.currentTarget.getBoundingClientRect()
    const px = event.clientX - rect.left
    const i = Math.round(((px - PAD.left) / inner.w) * (points.length - 1))
    setActive(Math.min(past.length - 1, Math.max(0, i)))
  }
  function keys(event) {
    const last = past.length - 1
    const move = { ArrowLeft: -1, ArrowRight: 1 }[event.key]
    if (move) {
      event.preventDefault()
      setActive((a) => Math.min(last, Math.max(0, (a === null ? last : a) + move)))
    } else if (event.key === 'Home') setActive(0)
    else if (event.key === 'End') setActive(last)
    else if (event.key === 'Escape') setActive(null)
  }

  const a = active !== null && active < past.length ? past[active] : null
  const tipLeft = a ? Math.min(Math.max(x(active), 80), width - 80) : 0

  return (
    <div className="sales-chart" role="group" aria-label="Sales over time">
      <div className="sales-chart-top">
        <h3>Over time</h3>
        <div className="sales-seg" role="radiogroup" aria-label="What to graph">
          {METRICS.map((m) => (
            <label key={m.id} className={`sales-seg-btn${metric === m.id ? ' is-on' : ''}`}>
              <input type="radio" name={`${uid}-metric`} checked={metric === m.id} onChange={() => setMetric(m.id)} />
              <span>{m.label}</span>
            </label>
          ))}
        </div>
      </div>

      <div className="sales-periods" role="radiogroup" aria-label="Time period">
        {PERIODS.map((p) => (
          <label key={p.id} className={`sales-period${period === p.id ? ' is-on' : ''}`}>
            <input
              type="radio"
              name={`${uid}-period`}
              checked={period === p.id}
              onChange={() => {
                setPeriod(p.id)
                setActive(null)
              }}
            />
            <span>{p.label}</span>
          </label>
        ))}
      </div>

      <p className="sales-chart-total" aria-live="polite">
        <strong>{total}</strong> <span>{label.toLowerCase()}</span>
        {changeText && <span className="sales-chart-change">{changeText}</span>}
      </p>

      {table ? (
        <div className="sales-chart-table">
          <table>
            <thead>
              <tr>
                <th scope="col">{series.range.unit === 'day' ? 'Day' : series.range.unit === 'week' ? 'Week' : 'Month'}</th>
                <th scope="col" className="num">
                  Sales
                </th>
                <th scope="col" className="num">
                  Clients
                </th>
              </tr>
            </thead>
            <tbody>
              {past.map((b) => (
                <tr key={b.key}>
                  <th scope="row">{b.long}</th>
                  <td className="num">{money(b.cents)}</td>
                  <td className="num">{b.count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="sales-plot" ref={box}>
          <svg
            width={width}
            height={HEIGHT}
            viewBox={`0 0 ${width} ${HEIGHT}`}
            role="img"
            tabIndex={0}
            aria-label={`${metric === 'clients' ? 'Clients' : 'Sales'}, ${label.toLowerCase()}: ${total}. Use the left and right arrow keys to read each point, or show the table.`}
            onPointerMove={nearest}
            onPointerDown={nearest}
            onPointerLeave={(e) => e.pointerType === 'mouse' && setActive(null)}
            onKeyDown={keys}
            onBlur={() => setActive(null)}
          >
            {scale.ticks.map((t) => (
              <g key={t}>
                <line x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} className="sc-grid" />
                <text x={PAD.left - 8} y={y(t) + 4} textAnchor="end" className="sc-axis">
                  {axisLabel(t, metric)}
                </text>
              </g>
            ))}
            {points.map((b, i) => labelled(i) && (
              <text key={b.key} x={x(i)} y={HEIGHT - 8} textAnchor={i === 0 ? 'start' : i === points.length - 1 ? 'end' : 'middle'} className="sc-axis">
                {b.tick}
              </text>
            ))}
            {area && <path d={area} className="sc-area" />}
            {xy.length > 1 && <path d={line} className="sc-line" />}
            {a && <line x1={x(active)} x2={x(active)} y1={PAD.top} y2={y(0)} className="sc-cross" />}
            {xy.length > 0 && !a && (
              <circle cx={xy[xy.length - 1][0]} cy={xy[xy.length - 1][1]} r={5} className="sc-dot" />
            )}
            {a && <circle cx={x(active)} cy={y(value(a))} r={5} className="sc-dot" />}
          </svg>
          {a && (
            <div className="sales-tip" style={{ left: tipLeft }} role="status">
              <span className="sales-tip-day">{a.long}</span>
              <span className="sales-tip-num">{shown(metric === 'clients' ? a.count : a.cents)}</span>
              <span className="sales-tip-sub">{metric === 'clients' ? money(a.cents) : plural(a.count, 'client', 'clients')}</span>
            </div>
          )}
          {empty && <p className="sales-chart-empty">No sales in this period yet.</p>}
        </div>
      )}

      <button type="button" className="link-btn sales-chart-toggle" onClick={() => setTable((t) => !t)} aria-pressed={table}>
        {table ? 'Show the graph' : 'Show as a table'}
      </button>
    </div>
  )
}
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { fromKey, keyOf } from '../lib/availability.js'
import {
  NOTE_MAX,
  OTHER,
  PAYMENT_WORDS,
  RANGES,
  blankEntry,
  checkEntry,
  entryFromRow,
  filterSales,
  money,
  saleServices,
  salesMetrics,
  sortSales,
  toCsv,
} from '../lib/sales.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import SalesChart from './SalesChart.jsx'
import { addSale, getSales, removeSale, updateSale } from './adminApi.js'

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
  const [editing, setEditing] = useState(null) // the line being changed in the form above, or null when adding
  const formRef = useRef(null)

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
      if (editing) {
        const row = await updateSale(editing.id, result.body)
        setRows((list) => list.map((r) => (r.id === editing.id ? row : r)))
        setFlash(`Saved the changes to ${row.clientName}, ${row.serviceName}, ${money(row.amountCents)}.`)
        setEditing(null)
        setForm(blankEntry(shop, today))
      } else {
        const row = await addSale(result.body)
        setRows((list) => [row, ...list])
        setFlash(`Added ${row.clientName}, ${row.serviceName}, ${money(row.amountCents)}.`)
        // ready for the next client: the name, note and typed price clear; the service, payment and day stay
        setForm((f) => ({ ...f, clientName: '', note: '', custom: '', otherName: isOther ? '' : f.otherName }))
      }
    } catch (ex) {
      setFailure(ex && ex.friendly ? ex.message : editing ? 'Could not save the changes. Nothing was changed. Try again.' : 'Could not add that. Nothing was saved. Try again.')
    } finally {
      setSaving(false)
    }
  }

  function startEdit(row) {
    setEditing(row)
    setForm(entryFromRow(row, shop))
    setErrors({})
    setFailure('')
    setFlash('')
    setConfirmId(null)
    if (formRef.current) {
      formRef.current.scrollIntoView({ behavior: 'smooth', block: 'start' })
      const first = formRef.current.querySelector('select')
      if (first) first.focus({ preventScroll: true })
    }
  }

  function cancelEdit() {
    setEditing(null)
    setForm(blankEntry(shop, today))
    setErrors({})
    setFailure('')
  }

  async function remove(row) {
    try {
      await removeSale(row.id)
      if (editing && editing.id === row.id) cancelEdit()
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
      <form ref={formRef} className={`sales-add${editing ? ' is-editing' : ''}`} onSubmit={submit} noValidate aria-label={editing ? 'Edit a sale' : 'Log a sale'}>
        <h2>{editing ? 'Edit this sale' : 'Log a client'}</h2>
        {editing && (
          <p className="sales-editing">
            Changing {editing.clientName}, {dayWords(editing.dateKey)}. Nothing changes until you save.
          </p>
        )}

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
        <div className="sales-submit-row">
          <button type="submit" className="btn btn-primary sales-submit" disabled={saving}>
            {saving ? (editing ? 'Saving…' : 'Adding…') : editing ? 'Save changes' : 'Add to log'}
          </button>
          {editing && (
            <button type="button" className="btn" onClick={cancelEdit} disabled={saving}>
              Cancel
            </button>
          )}
        </div>
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
          <SalesChart rows={rows} today={today} />

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
                        <span className="sr-only">Edit or remove</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {visible.slice(0, shown).map((r) => (
                      <tr key={r.id} className={editing && editing.id === r.id ? 'is-editing' : ''}>
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
                            <span className="sales-confirm">
                              <button type="button" className="admin-box-btn" onClick={() => startEdit(r)} aria-label={`Edit ${r.clientName}, ${money(r.amountCents)}`}>
                                Edit
                              </button>
                              <button type="button" className="admin-box-btn" onClick={() => setConfirmId(r.id)} aria-label={`Remove ${r.clientName}, ${money(r.amountCents)}`}>
                                Remove
                              </button>
                            </span>
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
cat > "$STAGE/16" <<'VICBLESS_EOF'
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

/* ---- editing a sale ---- */

.sales-add.is-editing {
  border-color: var(--accent);
}

.sales-editing {
  margin: -4px 0 12px;
  font-size: 0.9rem;
  color: var(--muted);
}

.sales-submit-row {
  display: flex;
  gap: 10px;
}

.sales-submit-row .sales-submit {
  flex: 1;
}

.sales-sheet tbody tr.is-editing td {
  background: color-mix(in srgb, var(--accent) 14%, transparent);
}

/* ---- the line graph ---- */

.sales-chart {
  margin-top: 18px;
  padding: 14px;
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.sales-chart-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 10px;
}

.sales-chart h3 {
  margin: 0;
  font-size: 1.1rem;
}

.sales-seg {
  display: inline-flex;
  border: 2px solid var(--line);
  border-radius: 8px;
  overflow: hidden;
}

.sales-seg-btn,
.sales-period {
  position: relative;
  border-radius: 999px;
  cursor: pointer;
}

.sales-seg-btn input,
.sales-period input {
  position: absolute;
  opacity: 0;
  inset: 0;
  margin: 0;
  cursor: pointer;
}

.sales-seg-btn span {
  display: block;
  padding: 6px 14px;
  min-height: 36px;
  font-weight: 700;
  font-size: 0.9rem;
  line-height: 24px;
  color: var(--muted);
}

.sales-seg-btn.is-on span {
  background: var(--accent);
  color: var(--on-accent);
}

.sales-seg-btn:focus-within {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
  border-radius: 8px;
}

.sales-period:focus-within {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.sales-periods {
  display: flex;
  gap: 8px;
  margin: 0 -14px 12px;
  padding: 2px 14px 6px;
  overflow-x: auto;
  scrollbar-width: thin;
}

.sales-period span {
  display: block;
  padding: 7px 12px;
  min-height: 40px;
  line-height: 26px;
  border: 2px solid var(--line);
  border-radius: 999px;
  font-size: 0.9rem;
  font-weight: 700;
  white-space: nowrap;
  color: var(--muted);
}

.sales-period.is-on span {
  border-color: var(--accent);
  color: var(--ink);
  background: color-mix(in srgb, var(--accent) 18%, transparent);
}

.sales-chart-total {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 10px;
  margin: 0 0 8px;
  color: var(--muted);
}

.sales-chart-total strong {
  font-size: 1.8rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
}

.sales-chart-change {
  font-size: 0.9rem;
  font-weight: 700;
  color: var(--ink);
}

.sales-plot {
  position: relative;
  width: 100%;
}

.sales-plot svg {
  display: block;
  max-width: 100%;
  touch-action: pan-y;
  border-radius: 6px;
}

.sales-plot svg:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.sc-grid {
  stroke: var(--line);
  stroke-width: 1;
}

.sc-axis {
  fill: var(--muted);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}

.sc-line {
  fill: none;
  stroke: var(--accent);
  stroke-width: 2;
  stroke-linejoin: round;
  stroke-linecap: round;
}

.sc-area {
  fill: var(--accent);
  fill-opacity: 0.1;
}

.sc-cross {
  stroke: var(--muted);
  stroke-width: 1;
}

.sc-dot {
  fill: var(--accent);
  stroke: var(--surface);
  stroke-width: 2;
}

.sales-tip {
  position: absolute;
  top: 6px;
  transform: translateX(-50%);
  display: grid;
  gap: 1px;
  min-width: 120px;
  padding: 8px 12px;
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
  pointer-events: none;
  font-size: 0.85rem;
  text-align: center;
  white-space: nowrap;
}

.sales-tip-day,
.sales-tip-sub {
  color: var(--muted);
}

.sales-tip-num {
  font-size: 1.15rem;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
}

.sales-chart-empty {
  position: absolute;
  left: 0;
  right: 0;
  top: 38%;
  margin: 0;
  text-align: center;
  color: var(--muted);
  pointer-events: none;
}

.sales-chart-toggle {
  margin-top: 8px;
}

.sales-chart-table {
  max-height: 260px;
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: 6px;
}

.sales-chart-table table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.9rem;
}

.sales-chart-table th,
.sales-chart-table td {
  padding: 7px 10px;
  text-align: left;
  border-bottom: 1px solid var(--line);
  font-weight: 400;
}

.sales-chart-table thead th {
  position: sticky;
  top: 0;
  background: var(--surface);
  font-weight: 700;
  color: var(--muted);
}

.sales-chart-table .num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
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
export const updateSale = (id, body) => layer.updateSale(id, body)
export const removeSale = (id) => layer.removeSale(id)
export const removeBlock = (id) => layer.removeBlock(id)
export { SIGNED_OUT_EVENT } from './realAdminApi.js'
VICBLESS_EOF
cat > "$STAGE/18" <<'VICBLESS_EOF'
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

function buildSale(body, previous) {
  const settings = readShopSettings()
  const today = keyOf(new Date())
  const service = body.serviceId ? saleServices(settings).find((s) => s.id === body.serviceId) : null
  if (body.serviceId && !service) throw new Error('Pick a service, or type the name of a one-off service.')
  const custom = body.priceMode === 'custom'
  const dateKey = body.dateKey || today
  const keepId = previous && previous.dateKey === dateKey
  return {
    id: keepId ? previous.id : `${dateKey}.sale.${Math.random().toString(16).slice(2, 10).padEnd(8, '0')}`,
    dateKey,
    serviceId: service ? service.id : '',
    serviceName: service ? service.name : body.serviceName,
    amountCents: custom ? body.amountCents : service.price * 100,
    customPrice: custom,
    payment: body.payment === 'online' ? 'online' : 'shop',
    clientName: body.clientName,
    note: body.note || '',
    createdAt: previous ? previous.createdAt : new Date().toISOString(),
  }
}

export async function addSale(body) {
  await delay(200)
  const row = buildSale(body)
  writeSales([row, ...readSales()])
  return row
}

// Changes one line. Same day: the line keeps its id. A different day: it gets a new id, like the real API.
export async function updateSale(id, body) {
  await delay(200)
  const list = readSales()
  const index = list.findIndex((s) => s.id === id)
  if (index < 0) throw new Error('That sale is not in the log any more.')
  const row = buildSale(body, list[index])
  list[index] = row
  writeSales(list)
  return row
}

export async function removeSale(id) {
  await delay(150)
  writeSales(readSales().filter((s) => s.id !== id))
}
VICBLESS_EOF
cat > "$STAGE/19" <<'VICBLESS_EOF'
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
//   updateSale(id, body)      PUT    /api/admin/sales/{id}       -> the changed line (its id changes if the day changed)
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

export function updateSale(id, body) {
  return call('PUT', `/admin/sales/${encodeURIComponent(id)}`, body)
}

export async function removeSale(id) {
  await call('DELETE', `/admin/sales/${encodeURIComponent(id)}`)
}
VICBLESS_EOF
cat > "$STAGE/20" <<'VICBLESS_EOF'
// The real admin data layer against a pretend fetch: the token, the URLs, and what happens when it expires.
// Runs in plain Node (no jsdom needed): a tiny in-memory localStorage and a window that can dispatch events stand in.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { addBlock, addSale, cancelBooking, getDay, getSales, removeSale, updateSale, isSignedIn, moveBooking, removeBlock, SIGNED_OUT_EVENT, signIn, signOut } from './realAdminApi.js'

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

  it('changes a sale with a PUT to its id', async () => {
    await signedIn()
    stub(json(200, { id: '2026-10-21.sale.11111111', clientName: 'Marcus' }))
    const body = { serviceId: 'mens-cut', priceMode: 'custom', amountCents: 6000, payment: 'online', clientName: 'Marcus', dateKey: '2026-10-21' }
    expect(await updateSale('2026-10-22.sale.abcdef12', body)).toMatchObject({ id: '2026-10-21.sale.11111111' })
    expect(calls[0].url).toBe('/api/admin/sales/2026-10-22.sale.abcdef12')
    expect(calls[0].init.method).toBe('PUT')
    expect(JSON.parse(calls[0].init.body)).toEqual(body)
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
cat > "$STAGE/21" <<'VICBLESS_EOF'
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

// "62.50", "55": cents as the text of a price box.
export const dollarsText = (cents) => (cents / 100).toFixed(cents % 100 === 0 ? 0 : 2)

// A line of the log as the form's fields, ready to edit. A service Vic has since removed (or a one-off) comes back as
// "Other" with its name; a price that is not the service's listed price today comes back as a custom price, so saving
// without touching the price never changes it.
export function entryFromRow(row, settings) {
  const service = row.serviceId ? saleServices(settings).find((s) => s.id === row.serviceId) : null
  const custom = !service || row.customPrice || row.amountCents !== service.price * 100
  return {
    serviceId: service ? service.id : OTHER,
    otherName: service ? '' : row.serviceName,
    priceMode: custom ? 'custom' : 'standard',
    custom: custom ? dollarsText(row.amountCents) : '',
    payment: row.payment === 'online' ? 'online' : 'shop',
    clientName: row.clientName,
    note: row.note || '',
    dateKey: row.dateKey,
  }
}

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
cat > "$STAGE/22" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { DEFAULT_SHOP_SETTINGS } from './shopSettings.js'
import {
  OTHER,
  blankEntry,
  checkEntry,
  dollarsText,
  entryFromRow,
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

describe('editing a line', () => {
  const settings = DEFAULT_SHOP_SETTINGS

  it('fills the form from a line at its listed price', () => {
    const f = entryFromRow(row(), settings)
    expect(f).toMatchObject({ serviceId: 'mens-cut', priceMode: 'standard', custom: '', payment: 'shop', clientName: 'Marcus Jones', dateKey: TODAY })
  })

  it('keeps a custom price as typed dollars', () => {
    expect(entryFromRow(row({ customPrice: true, amountCents: 6250 }), settings)).toMatchObject({ priceMode: 'custom', custom: '62.50' })
    expect(entryFromRow(row({ customPrice: true, amountCents: 6000 }), settings)).toMatchObject({ priceMode: 'custom', custom: '60' })
  })

  it('treats a price that no longer matches the listed one as custom, so saving never changes it', () => {
    const old = row({ amountCents: 4500 }) // listed at $45 back then
    const f = entryFromRow(old, settings)
    expect(f.priceMode).toBe('custom')
    const checked = checkEntry(f, settings, TODAY)
    expect(checked.ok && checked.body.amountCents).toBe(4500)
  })

  it('brings a one-off or removed service back as Other with its name', () => {
    const f = entryFromRow(row({ serviceId: '', serviceName: 'Line up only', amountCents: 2500, customPrice: true }), settings)
    expect(f).toMatchObject({ serviceId: OTHER, otherName: 'Line up only', priceMode: 'custom', custom: '25' })
    expect(entryFromRow(row({ serviceId: 'gone', serviceName: 'Old cut' }), settings).serviceId).toBe(OTHER)
  })

  it('turns an edited form back into a request the API accepts', () => {
    const f = { ...entryFromRow(row({ payment: 'online', note: 'beard too' }), settings), clientName: '  Marcus   J ' }
    const checked = checkEntry(f, settings, TODAY)
    expect(checked).toMatchObject({ ok: true, body: { serviceId: 'mens-cut', priceMode: 'standard', payment: 'online', clientName: 'Marcus J', note: 'beard too', dateKey: TODAY } })
  })

  it('writes dollars without needless cents', () => {
    expect(dollarsText(5500)).toBe('55')
    expect(dollarsText(6205)).toBe('62.05')
  })
})
VICBLESS_EOF
cat > "$STAGE/23" <<'VICBLESS_EOF'
// The numbers behind the sales line graph. Pure: no browser, no network.
//
// The graph shows one period at a time (this week, last month, past 3 months ...). A period is cut into buckets: one per
// day for a week or a month, one per week for the past 3 months, one per month for a year. Every bucket in the period gets
// a point, including days with no sales (they are zero, not missing), except buckets that have not happened yet.
// Weeks run Monday to Sunday.

export const PERIODS = [
  { id: 'this-week', label: 'This week' },
  { id: 'last-week', label: 'Last week' },
  { id: 'this-month', label: 'This month' },
  { id: 'last-month', label: 'Last month' },
  { id: '3-months', label: 'Past 3 months' },
  { id: 'this-year', label: 'This year' },
  { id: 'last-year', label: 'Last year' },
]

// ---- dates as YYYY-MM-DD keys (UTC arithmetic, so daylight saving never shifts a day) ----

const toDate = (key) => new Date(Date.UTC(Number(key.slice(0, 4)), Number(key.slice(5, 7)) - 1, Number(key.slice(8, 10))))
const toKey = (d) => d.toISOString().slice(0, 10)
export function addDays(key, n) {
  const d = toDate(key)
  d.setUTCDate(d.getUTCDate() + n)
  return toKey(d)
}
const weekStart = (key) => addDays(key, -((toDate(key).getUTCDay() + 6) % 7)) // the Monday on or before
const monthStart = (key) => `${key.slice(0, 8)}01`
const addMonths = (monthKey, n) => {
  const d = toDate(monthStart(monthKey))
  d.setUTCMonth(d.getUTCMonth() + n)
  return toKey(d)
}
const monthEnd = (key) => addDays(addMonths(key, 1), -1)
const min = (a, b) => (a < b ? a : b)

const SHORT_DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const SHORT_MONTH = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const LONG_MONTH = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const monthDay = (key) => `${SHORT_MONTH[Number(key.slice(5, 7)) - 1]} ${Number(key.slice(8, 10))}`
const dayWords = (key) => `${SHORT_DAY[toDate(key).getUTCDay()]}, ${monthDay(key)}`

// The first and last day of a period, and how it is cut up: { from, to, unit: 'day' | 'week' | 'month' }.
export function periodRange(id, today) {
  const year = Number(today.slice(0, 4))
  switch (id) {
    case 'this-week': {
      const from = weekStart(today)
      return { from, to: addDays(from, 6), unit: 'day' }
    }
    case 'last-week': {
      const from = addDays(weekStart(today), -7)
      return { from, to: addDays(from, 6), unit: 'day' }
    }
    case 'last-month': {
      const from = addMonths(today, -1)
      return { from, to: monthEnd(from), unit: 'day' }
    }
    case '3-months': {
      const from = addDays(weekStart(today), -12 * 7) // 13 weeks, the last one being this week
      return { from, to: addDays(weekStart(today), 6), unit: 'week' }
    }
    case 'this-year':
      return { from: `${year}-01-01`, to: `${year}-12-31`, unit: 'month' }
    case 'last-year':
      return { from: `${year - 1}-01-01`, to: `${year - 1}-12-31`, unit: 'month' }
    default: {
      const from = monthStart(today) // 'this-month'
      return { from, to: monthEnd(from), unit: 'day' }
    }
  }
}

// The stretch to compare a period with, cut to the same length so far: this month so far against the same days of last
// month. A period that is over is compared with the whole one before it. Returns { from, to, label }.
export function comparisonRange(id, today) {
  const { from, to, unit } = periodRange(id, today)
  const through = min(to, today) // how far the period has got
  const ongoing = through < to
  if (id === '3-months') return { from: addDays(from, -91), to: addDays(through, -91), label: 'the 3 months before' }
  if (unit === 'month') {
    const year = Number(from.slice(0, 4)) - 1
    return { from: `${year}-01-01`, to: `${year}${through.slice(4)}`, label: ongoing ? 'last year so far' : 'the year before' }
  }
  if (id === 'this-week' || id === 'last-week') return { from: addDays(from, -7), to: addDays(through, -7), label: ongoing ? 'last week so far' : 'the week before' }
  const prevFrom = addMonths(from, -1)
  return { from: prevFrom, to: ongoing ? min(monthEnd(prevFrom), addDays(prevFrom, Number(through.slice(8)) - 1)) : monthEnd(prevFrom), label: ongoing ? 'last month so far' : 'the month before' }
}

// The buckets of a period, each with what was sold in it. `rows` are lines of the sales log.
function buckets({ from, to, unit }, today, rows) {
  const out = []
  let start = from
  while (start <= to) {
    let end
    let tick
    let long
    if (unit === 'day') {
      end = start
      tick = unit === 'day' && to === addDays(from, 6) ? SHORT_DAY[toDate(start).getUTCDay()] : String(Number(start.slice(8)))
      long = dayWords(start)
    } else if (unit === 'week') {
      end = addDays(start, 6)
      tick = monthDay(start)
      long = `Week of ${monthDay(start)} to ${monthDay(end)}`
    } else {
      end = monthEnd(start)
      tick = SHORT_MONTH[Number(start.slice(5, 7)) - 1]
      long = `${LONG_MONTH[Number(start.slice(5, 7)) - 1]} ${start.slice(0, 4)}`
    }
    const mine = rows.filter((r) => r.dateKey >= start && r.dateKey <= end)
    out.push({ key: start, end, tick, long, cents: mine.reduce((sum, r) => sum + r.amountCents, 0), count: mine.length, future: start > today })
    start = addDays(end, 1)
    if (unit === 'month') start = monthStart(start)
  }
  return out
}

const sum = (rows, from, to) => {
  const mine = rows.filter((r) => r.dateKey >= from && r.dateKey <= to)
  return { cents: mine.reduce((total, r) => total + r.amountCents, 0), count: mine.length }
}

// Everything the graph needs for one period. `metric` is 'sales' (dollars) or 'clients' (how many); the change against the
// comparison stretch is for that metric.
export function buildSeries(rows, periodId, today, metric = 'sales') {
  const range = periodRange(periodId, today)
  const list = buckets(range, today, rows)
  const through = min(range.to, today)
  const now = sum(rows, range.from, through)
  const compare = comparisonRange(periodId, today)
  const before = sum(rows, compare.from, compare.to)
  const a = metric === 'clients' ? now.count : now.cents
  const b = metric === 'clients' ? before.count : before.cents
  return {
    range,
    buckets: list,
    totalCents: now.cents,
    count: now.count,
    compareLabel: compare.label,
    // a percent change, or null when there is nothing before to compare with
    changePct: b > 0 ? Math.round(((a - b) / b) * 100) : null,
    beforeEmpty: b === 0,
  }
}

// A round top for the vertical axis and ticks up to it: niceScale(137) -> { max: 150, step: 50, ticks: [0, 50, 100, 150] }.
export function niceScale(top, wanted = 4) {
  if (!(top > 0)) return { max: 1, step: 1, ticks: [0, 1] }
  const magnitude = 10 ** Math.floor(Math.log10(top / wanted))
  const step = [1, 2, 5, 10].map((m) => m * magnitude).find((s) => top / s <= wanted) || 10 * magnitude
  const max = Math.ceil(top / step) * step
  const ticks = []
  for (let v = 0; v <= max + step / 1000; v += step) ticks.push(Math.round(v * 100) / 100)
  return { max, step, ticks }
}

// Axis and tooltip numbers: $0, $250, $1.5K for sales; plain counts for clients.
export function axisLabel(value, metric) {
  if (metric === 'clients') return String(Math.round(value))
  if (value >= 1000) return `$${Number((value / 1000).toFixed(1))}K`
  return `$${value}`
}
VICBLESS_EOF
cat > "$STAGE/24" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { PERIODS, addDays, axisLabel, buildSeries, comparisonRange, niceScale, periodRange } from './salesChart.js'

const TODAY = '2026-10-22' // a Thursday
const sale = (dateKey, amountCents = 5500) => ({ dateKey, amountCents })

describe('the periods', () => {
  it('lists the seven filters Vic asked for', () => {
    expect(PERIODS.map((p) => p.label)).toEqual(['This week', 'Last week', 'This month', 'Last month', 'Past 3 months', 'This year', 'Last year'])
  })

  it('runs weeks Monday to Sunday', () => {
    expect(periodRange('this-week', TODAY)).toEqual({ from: '2026-10-19', to: '2026-10-25', unit: 'day' })
    expect(periodRange('last-week', TODAY)).toEqual({ from: '2026-10-12', to: '2026-10-18', unit: 'day' })
    expect(periodRange('this-week', '2026-10-25').from).toBe('2026-10-19') // a Sunday is the end of its week
    expect(periodRange('this-week', '2026-10-26').from).toBe('2026-10-26')
  })

  it('knows the months and years', () => {
    expect(periodRange('this-month', TODAY)).toEqual({ from: '2026-10-01', to: '2026-10-31', unit: 'day' })
    expect(periodRange('last-month', TODAY)).toEqual({ from: '2026-09-01', to: '2026-09-30', unit: 'day' })
    expect(periodRange('last-month', '2026-01-10')).toEqual({ from: '2025-12-01', to: '2025-12-31', unit: 'day' })
    expect(periodRange('this-year', TODAY)).toEqual({ from: '2026-01-01', to: '2026-12-31', unit: 'month' })
    expect(periodRange('last-year', TODAY)).toEqual({ from: '2025-01-01', to: '2025-12-31', unit: 'month' })
  })

  it('cuts the past 3 months into 13 weeks ending with this one', () => {
    expect(periodRange('3-months', TODAY)).toEqual({ from: '2026-07-27', to: '2026-10-25', unit: 'week' })
    expect(buildSeries([], '3-months', TODAY).buckets).toHaveLength(13)
  })

  it('adds days across month ends', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01')
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28')
  })
})

describe('the comparison', () => {
  it('compares an unfinished week with the same days of the week before', () => {
    expect(comparisonRange('this-week', TODAY)).toEqual({ from: '2026-10-12', to: '2026-10-15', label: 'last week so far' })
  })
  it('compares a finished week with the whole one before', () => {
    expect(comparisonRange('last-week', TODAY)).toEqual({ from: '2026-10-05', to: '2026-10-11', label: 'the week before' })
  })
  it('compares this month so far with the same days of last month', () => {
    expect(comparisonRange('this-month', TODAY)).toEqual({ from: '2026-09-01', to: '2026-09-22', label: 'last month so far' })
    expect(comparisonRange('this-month', '2026-03-31').to).toBe('2026-02-28') // never past the end of a shorter month
  })
  it('compares a finished month with the whole month before, even a longer one', () => {
    expect(comparisonRange('last-month', TODAY)).toEqual({ from: '2026-08-01', to: '2026-08-31', label: 'the month before' })
  })
  it('compares years', () => {
    expect(comparisonRange('this-year', TODAY)).toEqual({ from: '2025-01-01', to: '2025-10-22', label: 'last year so far' })
    expect(comparisonRange('last-year', TODAY)).toEqual({ from: '2024-01-01', to: '2024-12-31', label: 'the year before' })
  })
  it('compares the past 3 months with the 13 weeks before', () => {
    expect(comparisonRange('3-months', TODAY)).toMatchObject({ from: '2026-04-27', to: '2026-07-23' })
  })
})

describe('the series', () => {
  const rows = [sale('2026-10-19', 5500), sale('2026-10-19', 7000), sale('2026-10-21', 4000), sale('2026-10-12', 5500), sale('2026-10-13', 5500)]

  it('has a point for every day of the week, zero when nothing sold', () => {
    const s = buildSeries(rows, 'this-week', TODAY)
    expect(s.buckets.map((b) => b.tick)).toEqual(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
    expect(s.buckets.map((b) => b.cents)).toEqual([12500, 0, 4000, 0, 0, 0, 0])
    expect(s.buckets.map((b) => b.count)).toEqual([2, 0, 1, 0, 0, 0, 0])
  })

  it('marks days that have not happened yet', () => {
    expect(buildSeries(rows, 'this-week', TODAY).buckets.map((b) => b.future)).toEqual([false, false, false, false, true, true, true])
    expect(buildSeries(rows, 'last-week', TODAY).buckets.some((b) => b.future)).toBe(false)
  })

  it('totals only up to today and gives the change against the comparison stretch', () => {
    const s = buildSeries(rows, 'this-week', TODAY)
    expect(s.totalCents).toBe(16500)
    expect(s.count).toBe(3)
    expect(s.compareLabel).toBe('last week so far')
    expect(s.changePct).toBe(50) // 16500 vs 11000
    expect(buildSeries(rows, 'this-week', TODAY, 'clients').changePct).toBe(50) // 3 vs 2
  })

  it('has no percentage when there was nothing to compare with', () => {
    const s = buildSeries([sale('2026-10-20')], 'this-week', TODAY)
    expect(s.changePct).toBeNull()
    expect(s.beforeEmpty).toBe(true)
  })

  it('shows a drop as a negative change', () => {
    const s = buildSeries([sale('2026-10-12', 10000), sale('2026-10-20', 5000)], 'this-week', TODAY)
    expect(s.changePct).toBe(-50)
  })

  it('numbers the days of a month and the months of a year', () => {
    const m = buildSeries([sale('2026-10-05', 3000)], 'this-month', TODAY)
    expect(m.buckets).toHaveLength(31)
    expect(m.buckets[4]).toMatchObject({ tick: '5', cents: 3000, long: 'Mon, Oct 5' })
    const y = buildSeries([sale('2026-03-05', 3000), sale('2026-03-30', 1000)], 'this-year', TODAY)
    expect(y.buckets).toHaveLength(12)
    expect(y.buckets[2]).toMatchObject({ tick: 'Mar', cents: 4000, count: 2, long: 'March 2026' })
    expect(y.buckets[10].future).toBe(true)
    expect(y.buckets[9].future).toBe(false) // October has started
  })

  it('adds up weeks for the past 3 months', () => {
    const s = buildSeries([sale('2026-10-19', 1000), sale('2026-10-25', 2000), sale('2026-07-27', 500)], '3-months', TODAY)
    expect(s.buckets[12]).toMatchObject({ key: '2026-10-19', cents: 3000 })
    expect(s.buckets[0]).toMatchObject({ key: '2026-07-27', cents: 500, long: 'Week of Jul 27 to Aug 2' })
  })
})

describe('the axis', () => {
  it('picks round tops and steps', () => {
    expect(niceScale(137)).toEqual({ max: 150, step: 50, ticks: [0, 50, 100, 150] })
    expect(niceScale(5500 / 100)).toMatchObject({ max: 60 })
    expect(niceScale(0)).toEqual({ max: 1, step: 1, ticks: [0, 1] })
    expect(niceScale(1204).max).toBeGreaterThanOrEqual(1204)
    expect(niceScale(3, 4).ticks).toEqual([0, 1, 2, 3])
  })
  it('writes short labels', () => {
    expect(axisLabel(0, 'sales')).toBe('$0')
    expect(axisLabel(250, 'sales')).toBe('$250')
    expect(axisLabel(1500, 'sales')).toBe('$1.5K')
    expect(axisLabel(2, 'clients')).toBe('2')
  })
})
VICBLESS_EOF
cat > "$STAGE/25" <<'VICBLESS_EOF'
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Vicbless booking backend (API Gateway HTTP API, Lambda, DynamoDB). One stack per environment.

Parameters:
  Environment:
    Type: String
    AllowedValues: [dev, prod]
    Description: dev is the staging environment for this project; prod is the real one.
  CorsAllowedOrigins:
    Type: String
    Default: '*'
    Description: Comma separated list of site origins allowed to call the API, or * for any.

Conditions:
  IsProd: !Equals [!Ref Environment, prod]

Globals:
  Function:
    Runtime: python3.12
    # x86_64 on purpose: the GitHub runner that builds the package is x86, and pydantic is a compiled package.
    Architectures: [x86_64]
    # 1024 MB because Lambda gives CPU in proportion to memory, and the 600,000 round password hash is CPU work.
    MemorySize: 1024
    Timeout: 15

Resources:
  Table:
    Type: AWS::DynamoDB::Table
    # Retain is a fixed setting (CloudFormation cannot make it conditional). A deleted stack leaves the table behind.
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      TableName: !Sub vicbless-${Environment}
      BillingMode: PAY_PER_REQUEST
      DeletionProtectionEnabled: !If [IsProd, true, false]
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: !If [IsProd, true, false]
      AttributeDefinitions:
        - {AttributeName: pk, AttributeType: S}
        - {AttributeName: sk, AttributeType: S}
        - {AttributeName: gsi1pk, AttributeType: S}
        - {AttributeName: gsi1sk, AttributeType: S}
      KeySchema:
        - {AttributeName: pk, KeyType: HASH}
        - {AttributeName: sk, KeyType: RANGE}
      GlobalSecondaryIndexes:
        - IndexName: gsi1
          KeySchema:
            - {AttributeName: gsi1pk, KeyType: HASH}
            - {AttributeName: gsi1sk, KeyType: RANGE}
          Projection:
            ProjectionType: KEYS_ONLY
      TimeToLiveSpecification:
        AttributeName: expiresAt
        Enabled: true

  # Vic's sales log lives in its own table, apart from the bookings. Bookings are cleaned up after 90 days and are rebuilt
  # often; the sales log is his permanent record, so it has no expiry and its own backups.
  SalesTable:
    Type: AWS::DynamoDB::Table
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      TableName: !Sub vicbless-sales-${Environment}
      BillingMode: PAY_PER_REQUEST
      DeletionProtectionEnabled: !If [IsProd, true, false]
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: !If [IsProd, true, false]
      AttributeDefinitions:
        - {AttributeName: pk, AttributeType: S}
        - {AttributeName: sk, AttributeType: S}
      KeySchema:
        - {AttributeName: pk, KeyType: HASH}
        - {AttributeName: sk, KeyType: RANGE}

  ApiLogGroup:
    Type: AWS::Logs::LogGroup
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      LogGroupName: !Sub /aws/lambda/vicbless-api-${Environment}
      RetentionInDays: 14

  HttpApi:
    Type: AWS::Serverless::HttpApi
    Properties:
      StageName: $default
      DefaultRouteSettings:
        ThrottlingBurstLimit: 50
        ThrottlingRateLimit: 25
      RouteSettings:
        # Sign-in attempts are throttled hard on top of the per-address lockout inside the app.
        'POST /api/admin/login':
          ThrottlingBurstLimit: 5
          ThrottlingRateLimit: 2
      # CORS is handled inside the app, so API Gateway does not add a second set of headers.

  ApiFunction:
    Type: AWS::Serverless::Function
    DependsOn: ApiLogGroup
    Properties:
      FunctionName: !Sub vicbless-api-${Environment}
      CodeUri: ../backend/
      Handler: app.handler.lambda_handler
      Description: Vicbless booking API
      Environment:
        Variables:
          ENVIRONMENT: !Ref Environment
          TABLE_NAME: !Ref Table
          SALES_TABLE_NAME: !Ref SalesTable
          CORS_ALLOWED_ORIGINS: !Ref CorsAllowedOrigins
          EMAIL_PROVIDER: resend
          SMS_PROVIDER: textbelt
      Policies:
        - Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action:
                - dynamodb:GetItem
                - dynamodb:PutItem
                - dynamodb:UpdateItem
                - dynamodb:DeleteItem
                - dynamodb:Query
              Resource:
                - !GetAtt Table.Arn
                - !Sub ${Table.Arn}/index/gsi1
                - !GetAtt SalesTable.Arn
            - Effect: Allow
              Action: ssm:GetParameter
              Resource: !Sub arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/vicbless/${Environment}/*
      Events:
        Login:
          Type: HttpApi
          Properties:
            ApiId: !Ref HttpApi
            Path: /api/admin/login
            Method: POST
        ApiRoot:
          Type: HttpApi
          Properties:
            ApiId: !Ref HttpApi
            Path: /api
            Method: ANY
        ApiProxy:
          Type: HttpApi
          Properties:
            ApiId: !Ref HttpApi
            Path: /api/{proxy+}
            Method: ANY
        # Every 15 minutes the same function checks for appointments that are due a reminder (services/reminders.py).
        Reminders:
          Type: Schedule
          Properties:
            Schedule: rate(15 minutes)
            Description: Send appointment reminders that are due

Outputs:
  ApiUrl:
    Description: Base URL of the API (add /api/health to check it)
    Value: !Sub https://${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}
  ApiDomainName:
    Description: Domain name of the API, for the CloudFront /api/* origin
    Value: !Sub ${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}
  TableName:
    Value: !Ref Table
  SalesTableName:
    Value: !Ref SalesTable
  FunctionName:
    Value: !Ref ApiFunction
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"bdf351f1f1986b442c0dae3c91b64890d4544ecd383eb5017f7b6798a3ef9a95\", \"new\": 0}, {\"path\": \"backend/app/core/config.py\", \"base\": \"6a086cc6a898988025c73fcd988416c6c6d6e300cd0224ca9577b97e98d6d653\", \"new\": 1}, {\"path\": \"backend/app/database/keys.py\", \"base\": \"7026f2a1f4dbdae33128f59adbafe31ec4812708560ecff46fd52e1e9d74c3c3\", \"new\": 2}, {\"path\": \"backend/app/database/sales.py\", \"base\": \"8023d9ba329a5a390cae1d4d3a8f29a06664c2de51cd0542f088836875f3942d\", \"new\": 3}, {\"path\": \"backend/app/database/table.py\", \"base\": \"8ef20d9dcd041abffd7a16d171d0fed9afd0a02dcfe18a28b1488b184d216d54\", \"new\": 4}, {\"path\": \"backend/app/routes/admin.py\", \"base\": \"ce3f6b890d466862fec84ebdd38650f58507b6e97f1975ce9e204738c701a067\", \"new\": 5}, {\"path\": \"backend/app/services/sales.py\", \"base\": \"d50a5775f6a1fa01c68aade0676b5bc86598fbd03ea84487ac38608ca232351c\", \"new\": 6}, {\"path\": \"backend/scripts/migrate_sales_table.py\", \"base\": null, \"new\": 7}, {\"path\": \"backend/tests/fixtures/aws.py\", \"base\": \"2847ea1be13c228a126e516a6e2e3d6741d0e07c294170282c6e062d07b1fbf2\", \"new\": 8}, {\"path\": \"backend/tests/helpers/aws.py\", \"base\": \"cc8caeac93385e910c67bc764218ca69d583f7089cfe8d648e63c8816ea20fd6\", \"new\": 9}, {\"path\": \"backend/tests/helpers/constants.py\", \"base\": \"13568316763a888dcc3cae377eb22490d956343132210d8182fcdeafaa5628e5\", \"new\": 10}, {\"path\": \"backend/tests/helpers/template.py\", \"base\": \"08d650d3dff4cd369f6afd601fc38398bcb3bb65bd9da6ebfefce8f59d86b684\", \"new\": 11}, {\"path\": \"backend/tests/test_sales.py\", \"base\": \"5afeccc18982503c921dd03b3af80d10a80600bef187695deaad2cdcc003bdad\", \"new\": 12}, {\"path\": \"backend/tests/test_template.py\", \"base\": \"de6f16933da6b212e1bac6587d1bb17d3a37f4d26aa04d0111e289521e09d484\", \"new\": 13}, {\"path\": \"frontend/src/admin/SalesChart.jsx\", \"base\": null, \"new\": 14}, {\"path\": \"frontend/src/admin/SalesPage.jsx\", \"base\": \"83cf806bc686f03b3556922e6922b5ba2ac9a79e49cdf46fedc3b21ede2cd0db\", \"new\": 15}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"38405a1b8ff4b55581d917ea75ef93b9641fc2bca8a40010e408d825cb613f3b\", \"new\": 16}, {\"path\": \"frontend/src/admin/adminApi.js\", \"base\": \"88bbd821eb42b976cdf81d433eb47d1b90e698b06830492ac65adbd663a0c5c6\", \"new\": 17}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"e2f0824ae146d5f065bdbcacdb9f3637bb829bd464b58680c7e6f7049f056ff7\", \"new\": 18}, {\"path\": \"frontend/src/admin/realAdminApi.js\", \"base\": \"9a7d1c621b56605a2c805339ff834de391c49aaf488d402e1c0f9fbf71e0be3b\", \"new\": 19}, {\"path\": \"frontend/src/admin/realAdminApi.test.js\", \"base\": \"a9dda839fc862de95bf963477aeb69579a7f08de4b736ce48b60617b5abf870e\", \"new\": 20}, {\"path\": \"frontend/src/lib/sales.js\", \"base\": \"2c300262f84654f974c63e6a709414f7792a0b997015258dee5546fe2db2a8d3\", \"new\": 21}, {\"path\": \"frontend/src/lib/sales.test.js\", \"base\": \"9701be5427a8dcd82746437ae704fcaa93997ec6ae412eeb03549def1b6c3dda\", \"new\": 22}, {\"path\": \"frontend/src/lib/salesChart.js\", \"base\": null, \"new\": 23}, {\"path\": \"frontend/src/lib/salesChart.test.js\", \"base\": null, \"new\": 24}, {\"path\": \"infra/template.yaml\", \"base\": \"d6da7f3f19b7c4956984377f4fc41d190eb08954afa421a8defd0c807ff9a4ca\", \"new\": 25}]")

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
echo "Deploy the backend (this creates the new sales table), then deploy the frontend."
