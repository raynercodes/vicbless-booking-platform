#!/usr/bin/env bash
# Vicbless: After Hours Cuts (Thursday and Friday late slots) and Stripe payment description
# Run from the REPO ROOT:  bash vicbless-after-hours-cuts.sh
#
# Adds the After Hours Cuts service ($70) with late appointments after closing, 2 on Thursday and 2 on Friday,
# purple After hours styling and labels, a Settings section for price, description and slots per day, and a
# date, time and note description on Stripe's payment page.
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
"""Reading a day or a range of days: what is taken, and the schedule Vic sees."""

from __future__ import annotations

from datetime import date, timedelta

from ..domain import shop
from ..domain.models import Block, Booking
from . import blocks as blocks_db
from . import bookings as bookings_db
from . import keys, table
from .keys import PK


def query_range(low: str, high: str, projection: bool = False) -> list[dict]:
    """Reads all of Vic's items whose sort key is between `low` and `high`, following DynamoDB's paging.

    Sort keys start with the date, so "2026-10-12#" to "2026-10-12#~" is exactly one day, and a longer
    range is just as cheap: one query, not one per day. projection=True fetches only what availability needs.
    """
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk AND sk BETWEEN :lo AND :hi",
        "ExpressionAttributeValues": {":pk": PK, ":lo": low, ":hi": high},
        "ConsistentRead": True,
    }
    if projection:
        kwargs["ProjectionExpression"] = "#sk, #w"
        kwargs["ExpressionAttributeNames"] = {"#sk": "sk", "#w": "whole"}
    items: list[dict] = []
    while True:
        page = table.table().query(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def availability(first: date, last: date, settings: shop.ShopSettings) -> dict[str, dict]:
    """{ 'YYYY-MM-DD': { busy: [appointment starts], dayOff: bool, slotMinutes: int } } for every day in the range.

    `busy` lists the appointment starts of that day's grid that overlap anything taken (bookings and block-offs alike,
    so the site greys them out the same way). `dayOff` is true when Vic took the whole day off, so the site can say
    "Closed" instead of "Full". `slotMinutes` is how long an appointment is that day.
    """
    # Start every day empty, so days with nothing booked still appear in the answer.
    days: dict[str, dict] = {}
    taken: dict[str, set[int]] = {}
    d = first
    while d <= last:
        days[d.isoformat()] = {"busy": [], "dayOff": False, "slotMinutes": settings.slot_for(d)}
        taken[d.isoformat()] = set()
        d += timedelta(days=1)
    items = query_range(f"{first.isoformat()}#", f"{last.isoformat()}#~", projection=True)
    for item in items:
        day_key, kind, *rest = item["sk"].split("#")
        entry = days.get(day_key)
        if entry is None:
            continue
        if kind == "CLAIM":
            taken[day_key].add(keys.minutes_of(rest[0]))
        elif kind == "BLOCK" and item.get("whole"):
            entry["dayOff"] = True
    for day_key, entry in days.items():
        day = date.fromisoformat(day_key)
        entry["busy"] = shop.busy_slots(day, entry["slotMinutes"], taken[day_key], settings.after_count(day))
    return days


def day_schedule(day: date) -> tuple[list[Booking], list[Block]]:
    items = query_range(f"{day.isoformat()}#", f"{day.isoformat()}#~")
    bookings, blocks = [], []
    for item in items:
        kind = item["sk"].split("#")[1]
        if kind == "BOOKING":
            bookings.append(bookings_db.booking_from(item))
        elif kind == "BLOCK":
            blocks.append(blocks_db.block_from(item))
    bookings.sort(key=lambda b: b.start)
    blocks.sort(key=lambda b: b.start)
    return bookings, blocks
VICBLESS_EOF
cat > "$STAGE/2" <<'VICBLESS_EOF'
"""Vic's settings in the database: one item that holds his services and his appointment lengths."""

from __future__ import annotations

from datetime import datetime, timezone

from ..domain import shop
from . import keys, table
from .keys import PK

# What a service may look like, so a damaged or hand-edited item can never break the site. Anything that does not fit
# is ignored and the default is used instead.
_SLOT_RANGE = range(shop.MIN_SLOT_MINUTES, shop.MAX_SLOT_MINUTES + 1)


def _service_from(raw: object) -> shop.Service | None:
    if not isinstance(raw, dict):
        return None
    try:
        service_id, name = str(raw["id"]), str(raw["name"])
        price = int(raw["price"])
    except (KeyError, TypeError, ValueError):
        return None
    if not service_id or not name:
        return None
    return shop.Service(service_id, name, price, bool(raw.get("from", False)), str(raw.get("note", "")))


def _after_hours_from(raw: object) -> shop.AfterHours:
    """The stored after-hours offer, with anything unreadable replaced by the shop's starting value."""
    base = shop.AfterHours()
    if not isinstance(raw, dict):
        return base
    price, note, slots = base.price, base.note, base.slots
    try:
        if 0 <= int(raw["price"]) <= 999:
            price = int(raw["price"])
    except (KeyError, TypeError, ValueError):
        pass
    if isinstance(raw.get("note"), str):
        note = raw["note"]
    stored = raw.get("slots")
    if isinstance(stored, list) and len(stored) == 7:
        try:
            parsed = tuple(int(v) for v in stored)
        except (TypeError, ValueError):
            parsed = ()
        if len(parsed) == 7 and all(0 <= v <= shop.MAX_AFTER_SLOTS for v in parsed):
            slots = parsed  # type: ignore[assignment]
    return shop.AfterHours(price, note, slots)


def settings_from_item(item: dict | None) -> shop.ShopSettings:
    """Turns the stored item into ShopSettings. A missing or unreadable part falls back to the shop's defaults."""
    defaults = shop.DEFAULT_SETTINGS
    if not item:
        return defaults
    slots = defaults.slot_minutes
    stored = item.get("slotMinutes")
    if isinstance(stored, list) and len(stored) == 7:
        try:
            parsed = tuple(int(v) for v in stored)
        except (TypeError, ValueError):
            parsed = ()
        if len(parsed) == 7 and all(v in _SLOT_RANGE and v % shop.UNIT_MINUTES == 0 for v in parsed):
            slots = parsed  # type: ignore[assignment]
    services = defaults.services
    stored_services = item.get("services")
    if isinstance(stored_services, list):
        parsed_services = tuple(s for s in (_service_from(r) for r in stored_services) if s)
        if parsed_services:
            services = parsed_services
    reminders = defaults.reminder_hours
    stored_reminders = item.get("reminderHours")
    if isinstance(stored_reminders, list):  # an empty list is a real choice: no reminders
        try:
            parsed_hours = tuple(sorted({int(v) for v in stored_reminders}, reverse=True))
        except (TypeError, ValueError):
            parsed_hours = None
        if parsed_hours is not None and all(h in shop.REMINDER_CHOICES for h in parsed_hours):
            reminders = parsed_hours
    return shop.ShopSettings(
        slot_minutes=slots,
        services=services,
        reminder_hours=reminders,
        after_hours=_after_hours_from(item.get("afterHours")),
    )


def load() -> shop.ShopSettings:
    """Reads the settings (defaults if Vic has never saved any). ConsistentRead so a save is seen at once."""
    item = table.table().get_item(Key={"pk": PK, "sk": keys.SETTINGS_SK}, ConsistentRead=True).get("Item")
    return settings_from_item(item)


def save(settings: shop.ShopSettings) -> None:
    """Stores the settings, replacing the earlier ones."""
    table.table().put_item(
        Item={
            "pk": PK,
            "sk": keys.SETTINGS_SK,
            "kind": "settings",
            "slotMinutes": list(settings.slot_minutes),
            "reminderHours": list(settings.reminder_hours),
            "services": [
                {"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in settings.services
            ],
            "afterHours": {
                "price": settings.after_hours.price,
                "note": settings.after_hours.note,
                "slots": list(settings.after_hours.slots),
            },
            "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""The shop's rules: hours, the settings Vic can edit, and what counts as a bookable time.

Pure functions with an injectable clock. Nothing here touches AWS, so every rule is easy to test.

What is fixed here: the opening HOURS. What Vic edits in his dashboard (and is stored in the database):
the services and prices, and how long an appointment is on each weekday. Those live in a ShopSettings,
which the functions below receive, and DEFAULT_SETTINGS is what the shop starts with. The site has its own
copy of the defaults in frontend/src/config.js, and a test compares the two.

Time is counted in 5 minute UNITS. A booking (or blocked-off time) "claims" every unit it covers, so two things
can only share a unit if they overlap. That is what lets the appointment length change from day to day (or later)
without a double booking ever becoming possible.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from ..core.errors import InvalidSlot, SlotUnavailable

# Vic's shop runs on this clock no matter where the server is. (Lambda's own clock is UTC.)
TIMEZONE = ZoneInfo("America/New_York")
STAFF_ID = "vic"
UNIT_MINUTES = 5  # the smallest piece of time. Every appointment length is a whole number of these.
MIN_SLOT_MINUTES = 15  # the shortest appointment Vic can set
MAX_SLOT_MINUTES = 120  # the longest appointment Vic can set
REMINDER_CHOICES = (1, 2, 3, 4, 6, 12, 24, 48)  # the reminder times Vic can switch on (hours before the appointment)
DAYS_AHEAD = 14  # today plus the next 13 days, same as the booking page
LEAD_MINUTES = 30  # a time today must start more than this many minutes from now
MAX_BLOCK_DAYS_AHEAD = 365  # how far ahead Vic can block off time
MAX_RANGE_DAYS = 31  # the longest availability range one request may ask for
MAX_SERVICES = 12  # how many services Vic can list
MAX_AFTER_SLOTS = 6  # the most after-hours appointments Vic can add to one day
DAY_END = 24 * 60  # an after-hours window never runs past midnight

# After Hours Cuts: late appointments after the shop closes, one service that covers everything. It is separate from
# the services Vic lists: it can only be booked at the after-hours times, and those times can only be booked with it.
AFTER_HOURS_ID = "after-hours"
AFTER_HOURS_NAME = "After Hours Cuts"
AFTER_HOURS_PRICE = 70
AFTER_HOURS_NOTE = "Late appointments after the shop closes. Any cut, design, beard or eyebrow work, all in one price."


def at(hour: int, minute: int = 0) -> int:
    """at(12, 35) -> 755. Times are stored as minutes after midnight so they are easy to add and compare."""
    return hour * 60 + minute


# Opening hours per weekday. None = closed. A day can have several windows (Saturday has a lunch gap).
# Keyed by Python weekday: Monday = 0 ... Sunday = 6. (The frontend uses JavaScript's Sunday = 0;
# the contract test converts between the two, so a mix-up is caught.)
HOURS: dict[int, list[tuple[int, int]] | None] = {
    0: [(at(12), at(18))],
    1: [(at(12), at(18))],
    2: None,
    3: [(at(11), at(19))],
    4: [(at(11), at(19))],
    5: [(at(9), at(12)), (at(12, 35), at(17))],
    6: None,
}

# Weekday names used by the API (the frontend turns its own Sunday-first numbers into these).
WEEKDAY_KEYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


@dataclass(frozen=True)
class Service:
    """One thing a customer can book. `price` is whole dollars; from_price shows it as "$65+". The length is NOT
    here: every booking takes one appointment slot, and the slot length is a setting of the day."""

    id: str
    name: str
    price: int
    from_price: bool = False
    note: str = ""
    after_hours: bool = False  # True only for After Hours Cuts


@dataclass(frozen=True)
class AfterHours:
    """The after-hours offer Vic controls: its price, its description, and how many late appointments each day has.

    The late appointments start the moment the shop closes and run back to back, each as long as that day's
    appointment length. `slots` counts them per weekday, Monday ... Sunday. A closed day never has any.
    """

    price: int = AFTER_HOURS_PRICE
    note: str = AFTER_HOURS_NOTE
    slots: tuple[int, int, int, int, int, int, int] = (0, 0, 0, 2, 2, 0, 0)  # Thursday and Friday: 2 each


@dataclass(frozen=True)
class ShopSettings:
    """Everything Vic can change from his dashboard."""

    slot_minutes: tuple[int, int, int, int, int, int, int]  # appointment length, Monday ... Sunday
    services: tuple[Service, ...]  # in the order they are shown
    # How many hours before an appointment a reminder goes out (each one is a separate reminder). Empty = no reminders.
    reminder_hours: tuple[int, ...] = (24, 2)
    after_hours: AfterHours = AfterHours()

    def after_count(self, day: date) -> int:
        """How many after-hours appointments this date has (0 on a closed day)."""
        return self.after_hours.slots[day.weekday()] if is_open(day) else 0

    def after_service(self) -> Service:
        """After Hours Cuts as a service (it is not part of `services`, which is the list Vic edits)."""
        a = self.after_hours
        return Service(AFTER_HOURS_ID, AFTER_HOURS_NAME, a.price, False, a.note, True)

    def slot_for(self, day: date) -> int:
        """How long an appointment is on this date."""
        return self.slot_minutes[day.weekday()]

    def service(self, service_id: str) -> Service | None:
        if service_id == AFTER_HOURS_ID:
            return self.after_service()
        for s in self.services:
            if s.id == service_id:
                return s
        return None


DEFAULT_SETTINGS = ShopSettings(
    # Monday and Tuesday are 45 minutes (Vic's request, 2026-10-13); every other day stays at 35.
    slot_minutes=(45, 45, 35, 35, 35, 35, 35),
    services=(
        Service("mens-cut", "Men's haircut", 55),
        Service("mens-design", "Men's haircut with design", 65, True, "Small or freestyle design"),
        Service(
            "mens-beard-eyebrow",
            "Men's haircut with beard and eyebrow",
            65,
            True,
            "Includes free hot towel if requested and hair styling",
        ),
        Service(
            "buzz-beard",
            "Head buzzed/shave and beard",
            40,
            False,
            "Same price for just beards. Tell Vic in person if you want it buzzed or shaved.",
        ),
        Service(
            "kids-design",
            "Kids cut (12 and under) with design",
            40,
            True,
            "$5 extra for a small design, $10 more for a bigger design",
        ),
    ),
)


def starts_at(day: date, start: int) -> datetime:
    """The exact moment an appointment begins, in the shop's timezone (so 'now' can be compared with it)."""
    return datetime(day.year, day.month, day.day, tzinfo=TIMEZONE) + timedelta(minutes=start)


def now_local() -> datetime:
    """The current time in the shop's timezone. Tests replace this with a fixed clock."""
    return datetime.now(TIMEZONE)


def today(now: datetime) -> date:
    """Today's date in the shop's timezone (at 11 pm in Georgia it is already tomorrow in UTC)."""
    return now.astimezone(TIMEZONE).date()


def minutes_of_day(now: datetime) -> int:
    """What time it is in the shop, as minutes after midnight."""
    local = now.astimezone(TIMEZONE)
    return local.hour * 60 + local.minute


def hhmm(minutes: int) -> str:
    """440 -> '0720'. Used in sort keys so they sort in time order."""
    return f"{minutes // 60:02d}{minutes % 60:02d}"


def label(minutes: int) -> str:
    """Display time like '12:35 pm'."""
    h, m = divmod(minutes, 60)
    suffix = "am" if h < 12 else "pm"
    h12 = h % 12 or 12
    return f"{h12}:{m:02d} {suffix}"


def windows_for(day: date) -> list[tuple[int, int]]:
    """The opening windows for a date: [(open, close), ...], or [] if the shop is closed that day."""
    return HOURS[day.weekday()] or []


def is_open(day: date) -> bool:
    """Does Vic work that day at all?"""
    return bool(windows_for(day))


def all_windows(day: date, slot: int = 0, after: int = 0) -> list[tuple[int, int]]:
    """The opening windows plus, when `after` > 0, one more that starts at closing and holds `after` appointments of `slot`."""
    windows = list(windows_for(day))
    if windows and after > 0:
        closing = windows[-1][1]
        windows.append((closing, min(closing + after * slot, DAY_END)))
    return windows


def is_after_hours(day: date, start: int) -> bool:
    """Is this start at or after the day's closing time (so it is an after-hours appointment)?"""
    windows = windows_for(day)
    return bool(windows) and start >= windows[-1][1]


def check_service_fits_slot(after_service: bool, day: date, start: int) -> None:
    """After Hours Cuts goes only in the after-hours times, and those times take only After Hours Cuts. Raises InvalidSlot."""
    late = is_after_hours(day, start)
    if after_service and not late:
        raise InvalidSlot(f"{AFTER_HOURS_NAME} is only booked at the after-hours times. Pick one of those.")
    if late and not after_service:
        raise InvalidSlot(f"That late time is for {AFTER_HOURS_NAME}. Pick that service, or a time during regular hours.")


def grid_starts(day: date, slot: int, after: int = 0) -> list[int]:
    """Every appointment start of the day, across all opening windows (Saturday's break is not in it).

    Each window runs its own grid from its opening time, and an appointment must end by closing.
    `after` is how many after-hours appointments the day has; they follow the last window.
    """
    out: list[int] = []
    for open_, close in all_windows(day, slot, after):
        s = open_
        while s + slot <= close:
            out.append(s)
            s += slot
    return out


def occupied_starts(start: int, minutes: int) -> list[int]:
    """The 5 minute units an appointment of `minutes` starting at `start` holds. These become the "claims" in the database."""
    return list(range(start, start + minutes, UNIT_MINUTES))


def booking_window(now: datetime) -> tuple[date, date]:
    """The first and last day customers may book: today through 13 days from now."""
    first = today(now)
    return first, first + timedelta(days=DAYS_AHEAD - 1)


def fits(day: date, start: int, slot: int, after: int = 0) -> bool:
    """True if an appointment starting at `start` is on that day's grid and finishes inside one opening window."""
    for open_, close in all_windows(day, slot, after):
        if open_ <= start and start + slot <= close and (start - open_) % slot == 0:
            return True
    return False


def check_bookable(day: date, start: int, slot: int, now: datetime, after: int = 0) -> None:
    """Raise InvalidSlot (can never work) or SlotUnavailable (not right now). Returns None if OK."""
    # 1. Structure: is this a real slot of a real opening day? If not, no amount of waiting will fix it.
    if not fits(day, start, slot, after):
        raise InvalidSlot()
    # 2. Timing: a real time can still be too early, too late, or too far away.
    first, last = booking_window(now)
    if day < first or day > last:
        raise SlotUnavailable()
    # Today only: Vic needs notice, so a time must start more than 30 minutes from now.
    if day == first and start <= minutes_of_day(now) + LEAD_MINUTES:
        raise SlotUnavailable()


def check_movable(day: date, start: int, slot: int, now: datetime, after: int = 0) -> None:
    """Rules for Vic moving a booking. Looser than for customers: no 14 day limit and no 30 minute notice.

    It still has to be a real slot of an open day, it can't be in the past, and it can't be more than a year out.
    Raises InvalidSlot. (Whether the time is free is decided by the database, not here.)
    """
    if not fits(day, start, slot, after):
        raise InvalidSlot()
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can move a booking to any open time from now up to a year ahead.")
    if day == first and start <= minutes_of_day(now):
        raise InvalidSlot("That time has already passed today. Pick a later one.")


def block_units(day: date, start: int, end: int, slot: int = 0, after: int = 0) -> list[int]:
    """The 5 minute units a block-off covers: everything from `start` up to `end` that lies inside opening hours.

    The range is widened to whole units. Saturday's lunch gap is never included, so a whole-day block does not claim it.
    """
    first = start - start % UNIT_MINUTES
    last = end + (-end) % UNIT_MINUTES
    out: list[int] = []
    for open_, close in all_windows(day, slot, after):
        out.extend(u for u in range(max(first, open_), min(last, close), UNIT_MINUTES))
    return out


def busy_slots(day: date, slot: int, taken_units: set[int], after: int = 0) -> list[int]:
    """The appointment starts of the day's grid that overlap anything taken (a booking or blocked time)."""
    return [s for s in grid_starts(day, slot, after) if any(u in taken_units for u in range(s, s + slot, UNIT_MINUTES))]


def check_blockable(day: date, now: datetime) -> None:
    """Vic can only block an open day, from today up to a year ahead. Raises InvalidSlot otherwise."""
    if not is_open(day):
        raise InvalidSlot("The shop is already closed that day, so there is nothing to block.")
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can block time from today up to a year ahead.")
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
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
        expires_at: int, customer_email: str = "", description: str = "",
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
                        "price_data": {"currency": "usd", "unit_amount": amount_cents, "product_data": {"name": product_name, "description": description or None}},
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
"""Vic blocking off time (lunch, a phone booking, a day off)."""

from __future__ import annotations

from datetime import datetime

from ..core.errors import InvalidSlot, ValidationFailed
from ..core.logs import log
from ..database import blocks as blocks_db
from ..domain import shop
from ..domain.models import Block
from ..schemas.requests import BlockIn, parse_date_key
from . import settings as settings_service


def add_block(data: BlockIn, now: datetime) -> Block:
    """Blocks off part of a day, or all of it. Customers then see those times as taken (or the day as Closed)."""
    day = parse_date_key(data.dateKey)
    shop.check_blockable(day, now)  # open day, from today up to a year ahead
    settings = settings_service.current()
    slot, after = settings.slot_for(day), settings.after_count(day)
    windows = shop.all_windows(day, slot, after)
    if data.whole:
        # A whole day off runs from the first opening time to the last closing time (Saturday's lunch gap included,
        # and the after-hours appointments too).
        start, end = windows[0][0], windows[-1][1]
    else:
        start, end = data.start, data.end
        if end <= start:
            raise ValidationFailed("The end time has to be after the start time.")
    # Turn the range into the 5 minute units it covers (only inside opening hours).
    claims = shop.block_units(day, start, end, slot, after)
    if not claims:
        raise InvalidSlot("Pick times that fall inside opening hours.")
    # The database refuses (Conflict) if any of those blocks already holds a booking or another block-off.
    block = blocks_db.create_block(day=day, claims=claims, start=start, end=end, note=data.note or "", whole=data.whole)
    log("block_created", blockId=block.id, whole=block.whole, units=len(claims))
    return block


def remove_block(block_id: str) -> Block:
    """Opens blocked-off time back up."""
    block = blocks_db.delete_block(block_id)
    log("block_removed", blockId=block.id, whole=block.whole)
    return block
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
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
    shop.check_bookable(day, data.start, minutes, now, settings.after_count(day))
    shop.check_service_fits_slot(service.after_hours, day, data.start)
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
    settings = settings_service.current()
    minutes = settings.slot_for(day)  # the booking takes the new day's appointment length
    shop.check_movable(day, data.start, minutes, now, settings.after_count(day))
    shop.check_service_fits_slot(before.service_id == shop.AFTER_HOURS_ID, day, data.start)
    after = bookings_db.move_booking(before, day=day, start=data.start, minutes=minutes)  # raises SlotTaken if not free
    log("booking_moved", fromId=before.id, toId=after.id, minutes=minutes)
    return before, after
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
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
from ..domain import shop
from ..domain.models import Booking
from ..payments import PaymentError, webhook
from . import notifications
from . import settings as settings_service

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


def _description(booking: Booking) -> str:
    """The line under the service name on Stripe's page and the customer's receipt: when it is, and what the service is."""
    when = f"{booking.day.strftime('%A, %B')} {booking.day.day} at {shop.label(booking.start)} with Vic"
    service = settings_service.current().service(booking.service_id)
    note = service.note if service else ""
    return f"{when}. {note}"[:500] if note else when


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
            description=_description(booking),
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
cat > "$STAGE/9" <<'VICBLESS_EOF'
"""Vic's settings: read them (cached for a few seconds) and save them.

Every booking and every availability request needs the settings, so they are kept in memory for CACHE_SECONDS
instead of read from the database each time. A save clears the cache at once on the instance that handled it; another
running copy of the API may still use the old settings for up to CACHE_SECONDS, which is harmless: bookings claim exact
5 minute units, so an appointment made under the older settings can never overlap another one.
"""

from __future__ import annotations

import secrets
import threading
import time

from ..core import config
from ..core.logs import log
from ..database import settings as settings_db
from ..domain import shop
from ..schemas.requests import SettingsIn

CACHE_SECONDS = 15

_lock = threading.Lock()
_cached: tuple[float, shop.ShopSettings] | None = None


def reset_cache() -> None:
    global _cached
    with _lock:
        _cached = None


config.on_reset(reset_cache)  # tests clear it together with the other caches


def current() -> shop.ShopSettings:
    """The settings right now (from the cache when it is fresh)."""
    global _cached
    now = time.monotonic()
    with _lock:
        if _cached and now - _cached[0] < CACHE_SECONDS:
            return _cached[1]
    loaded = settings_db.load()
    with _lock:
        _cached = (now, loaded)
    return loaded


def _new_service_id() -> str:
    return "svc-" + secrets.token_hex(3)


def save(data: SettingsIn) -> shop.ShopSettings:
    """Stores what Vic sent. A service without an id is new and gets one; the others keep theirs (bookings refer to it)."""
    services = []
    for item in data.services:
        services.append(
            shop.Service(
                id=item.id or _new_service_id(),
                name=item.name,
                price=item.price,
                from_price=item.from_price,
                note=item.note,
            )
        )
    updated = shop.ShopSettings(
        slot_minutes=tuple(data.slotMinutes[key] for key in shop.WEEKDAY_KEYS),  # type: ignore[arg-type]
        services=tuple(services),
        reminder_hours=(
            tuple(sorted(data.reminderHours, reverse=True)) if data.reminderHours is not None else current().reminder_hours
        ),
        after_hours=(
            shop.AfterHours(
                price=data.afterHours.price,
                note=data.afterHours.note,
                slots=tuple(data.afterHours.slots[key] for key in shop.WEEKDAY_KEYS),  # type: ignore[arg-type]
            )
            if data.afterHours is not None
            else current().after_hours
        ),
    )
    settings_db.save(updated)
    log("settings_saved", services=len(updated.services), slotMinutes=list(updated.slot_minutes), reminderHours=list(updated.reminder_hours))
    global _cached
    with _lock:
        _cached = (time.monotonic(), updated)
    return updated


def to_view(settings: shop.ShopSettings) -> dict:
    """The settings as the site reads them (the same for customers and for Vic's dashboard)."""
    return {
        "services": [
            {"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in settings.services
        ],
        "slotMinutes": dict(zip(shop.WEEKDAY_KEYS, settings.slot_minutes)),
        "reminderHours": list(settings.reminder_hours),
        "afterHours": {
            "id": shop.AFTER_HOURS_ID,
            "name": shop.AFTER_HOURS_NAME,
            "price": settings.after_hours.price,
            "note": settings.after_hours.note,
            "slots": dict(zip(shop.WEEKDAY_KEYS, settings.after_hours.slots)),
        },
    }
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
"""After Hours Cuts: late appointments after closing, one service that covers everything, $70 by default.

Thursday and Friday are open 11:00 am to 7:00 pm. With the 35 minute classic grid used in these tests, the two
after-hours appointments are 7:00 pm (1140) and 7:35 pm (1175).
"""

from datetime import date

import pytest

from app.domain import shop
from tests.helpers.api import book, busy, schedule_of
from tests.helpers.builders import booking_body
from tests.helpers.constants import MONDAY, NOW, TUESDAY, WEDNESDAY

THURSDAY = "2026-10-15"
FRIDAY = "2026-10-16"
SEVEN = 19 * 60
SEVEN_35 = SEVEN + 35
EIGHT_10 = SEVEN + 70
LATE = {"serviceId": "after-hours", "dateKey": THURSDAY}


def late(client, start=SEVEN, **over):
    return book(client, **{**LATE, "start": start, **over})


def put_settings(client, auth, **after):
    current = client.get("/api/admin/settings", headers=auth).json()
    body = {"services": current["services"], "slotMinutes": current["slotMinutes"]}
    if after:
        base = current["afterHours"]
        body["afterHours"] = {"price": base["price"], "note": base["note"], "slots": base["slots"], **after}
    return client.put("/api/admin/settings", headers=auth, json=body)


# --- the shop's rules -------------------------------------------------------------------------------


def test_the_late_times_follow_closing():
    thursday = date(2026, 10, 15)
    assert shop.all_windows(thursday, 35, 2) == [(660, 1140), (1140, 1210)]
    assert shop.grid_starts(thursday, 35, 2)[-2:] == [SEVEN, SEVEN_35]
    assert shop.is_after_hours(thursday, SEVEN) and not shop.is_after_hours(thursday, 1080)
    assert shop.all_windows(date(2026, 10, 14), 35, 2) == []  # a closed day has none
    assert shop.all_windows(thursday, 35, 0) == [(660, 1140)]


def test_the_late_window_never_runs_past_midnight():
    saturday = date(2026, 10, 17)  # closes at 5 pm
    assert shop.all_windows(saturday, 120, shop.MAX_AFTER_SLOTS)[-1] == (17 * 60, 24 * 60)


def test_the_settings_start_with_thursday_and_friday():
    defaults = shop.AfterHours()
    assert defaults.price == 70 and defaults.slots == (0, 0, 0, 2, 2, 0, 0)
    service = shop.DEFAULT_SETTINGS.service("after-hours")
    assert service.name == "After Hours Cuts" and service.price == 70 and service.after_hours
    assert [s.id for s in shop.DEFAULT_SETTINGS.services] == [  # it is not one of the services Vic edits
        "mens-cut", "mens-design", "mens-beard-eyebrow", "buzz-beard", "kids-design",
    ]  # fmt: skip


# --- what customers read -------------------------------------------------------------------------------


def test_customers_read_the_after_hours_offer(client):
    offer = client.get("/api/settings").json()["afterHours"]
    assert offer["id"] == "after-hours" and offer["name"] == "After Hours Cuts" and offer["price"] == 70
    assert offer["slots"] == {"mon": 0, "tue": 0, "wed": 0, "thu": 2, "fri": 2, "sat": 0, "sun": 0}
    assert "after the shop closes" in offer["note"]


def test_the_late_times_show_in_availability(client):
    assert busy(client, THURSDAY) == []
    assert late(client).status_code == 201
    assert busy(client, THURSDAY) == [SEVEN]
    assert busy(client, MONDAY) == []  # no late times on a Monday


# --- booking ---------------------------------------------------------------------------------------------


def test_after_hours_cuts_books_a_late_time(client, auth):
    r = late(client)
    assert r.status_code == 201
    [item] = schedule_of(client, auth, THURSDAY)["items"]
    assert item["serviceName"] == "After Hours Cuts"
    assert item["serviceId"] == "after-hours" and item["amountCents"] == 7000 and item["start"] == SEVEN


def test_both_late_times_book_and_then_it_is_full(client):
    assert late(client, SEVEN).status_code == 201
    assert late(client, SEVEN_35, name="Other Person", phone="5550109999").status_code == 201
    assert late(client, EIGHT_10, name="Third Person", phone="5550108888").status_code == 422  # only two late times
    assert busy(client, THURSDAY) == [SEVEN, SEVEN_35]


def test_a_day_with_no_late_times_refuses(client):
    r = late(client, 18 * 60 + 25, dateKey=TUESDAY)  # Tuesday closes at 6 pm
    assert r.status_code == 422
    r = late(client, 18 * 60, dateKey=WEDNESDAY)
    assert r.status_code == 422


def test_a_regular_service_cannot_take_a_late_time(client):
    r = book(client, dateKey=THURSDAY, start=SEVEN)
    assert r.status_code == 422 and "After Hours Cuts" in r.json()["error"]["message"]


def test_after_hours_cuts_cannot_take_a_regular_time(client):
    r = late(client, 11 * 60)
    assert r.status_code == 422 and "after-hours times" in r.json()["error"]["message"]


# --- Vic's settings ---------------------------------------------------------------------------------------


def test_vic_adds_a_third_late_time(client, auth):
    assert late(client, EIGHT_10).status_code == 422
    new_slots = {"mon": 0, "tue": 0, "wed": 0, "thu": 3, "fri": 2, "sat": 0, "sun": 0}
    assert put_settings(client, auth, slots=new_slots).status_code == 200
    assert late(client, EIGHT_10).status_code == 201


def test_vic_turns_the_late_times_off_for_a_day(client, auth):
    off = {"mon": 0, "tue": 0, "wed": 0, "thu": 0, "fri": 2, "sat": 0, "sun": 0}
    assert put_settings(client, auth, slots=off).status_code == 200
    assert late(client).status_code == 422
    assert late(client, dateKey=FRIDAY).status_code == 201


def test_vic_changes_the_price_and_description(client, auth):
    r = put_settings(client, auth, price=80, note="Nights only.")
    assert r.status_code == 200 and r.json()["afterHours"]["price"] == 80 and r.json()["afterHours"]["note"] == "Nights only."
    assert client.get("/api/settings").json()["afterHours"]["price"] == 80
    late(client)
    [item] = client.get(f"/api/admin/schedule?date={THURSDAY}", headers=auth).json()["items"]
    assert item["amountCents"] == 8000


def test_saving_without_the_after_hours_part_keeps_what_was_saved(client, auth):
    put_settings(client, auth, price=85)
    assert put_settings(client, auth).json()["afterHours"]["price"] == 85


@pytest.mark.parametrize(
    "bad",
    [
        {"slots": {"mon": 0, "tue": 0, "wed": 0, "thu": 7, "fri": 2, "sat": 0, "sun": 0}},  # too many
        {"slots": {"mon": -1, "tue": 0, "wed": 0, "thu": 2, "fri": 2, "sat": 0, "sun": 0}},
        {"slots": {"thu": 2}},  # a day is missing
        {"price": -5},
        {"price": 1000},
        {"note": "x" * 121},
    ],
)
def test_bad_after_hours_settings_are_refused(client, auth, bad):
    assert put_settings(client, auth, **bad).status_code == 422


def test_unreadable_stored_after_hours_falls_back_to_the_starting_offer():
    from app.database.settings import settings_from_item

    got = settings_from_item({"afterHours": {"price": "lots", "note": 5, "slots": [1, 2]}}).after_hours
    assert got == shop.AfterHours()
    assert settings_from_item({"afterHours": "nope"}).after_hours == shop.AfterHours()
    assert settings_from_item(None).after_hours == shop.AfterHours()


# --- blocking and moving -----------------------------------------------------------------------------------


def test_a_whole_day_off_takes_the_late_times_too(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": THURSDAY, "whole": True})
    assert r.status_code == 201, r.text
    assert busy(client, THURSDAY)[-2:] == [SEVEN, SEVEN_35]
    assert late(client).status_code == 409


def test_vic_can_block_just_the_late_times(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": THURSDAY, "start": SEVEN, "end": EIGHT_10})
    assert r.status_code == 201, r.text
    assert busy(client, THURSDAY) == [SEVEN, SEVEN_35]


def test_a_late_booking_moves_only_to_another_late_time(client, auth):
    assert late(client).status_code == 201
    booking_id = schedule_of(client, auth, THURSDAY)["items"][0]["id"]

    def move(day, start):
        return client.patch(f"/api/admin/bookings/{booking_id}", headers=auth, json={"dateKey": day, "start": start})

    assert move(THURSDAY, 11 * 60).status_code == 422  # a regular time
    r = move(FRIDAY, SEVEN)
    assert r.status_code == 200, r.text


def test_a_regular_booking_cannot_move_into_a_late_time(client, auth):
    assert book(client).status_code == 201
    booking_id = schedule_of(client, auth, TUESDAY)["items"][0]["id"]
    r = client.patch(f"/api/admin/bookings/{booking_id}", headers=auth, json={"dateKey": THURSDAY, "start": SEVEN})
    assert r.status_code == 422


# --- the Stripe page --------------------------------------------------------------------------------------


def test_the_payment_page_says_when_and_what(client, stripe):
    r = late(client, payment="online")
    assert r.status_code == 201, r.text
    [session] = stripe.sessions.values()
    form = session["form"]
    assert form["line_items[0][price_data][unit_amount]"] == "7000"
    assert form["line_items[0][price_data][product_data][name]"] == "After Hours Cuts at Vicbless Barbershop"
    description = form["line_items[0][price_data][product_data][description]"]
    assert description.startswith("Thursday, October 15 at 7:00 pm with Vic. ")
    assert "all in one price" in description


def test_a_service_with_no_note_gets_only_the_time(client, stripe, auth):
    current = client.get("/api/admin/settings", headers=auth).json()
    services = [{**s, "note": ""} for s in current["services"]]
    client.put("/api/admin/settings", headers=auth, json={"services": services, "slotMinutes": current["slotMinutes"]})
    assert book(client, payment="online").status_code == 201
    [session] = stripe.sessions.values()
    assert session["form"]["line_items[0][price_data][product_data][description]"] == "Tuesday, October 13 at 12:00 pm with Vic"
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
"""The site and the API must agree on hours, services and the slot grid. This reads the real frontend config."""

import re
from pathlib import Path

from app.domain import shop

CONFIG = Path(__file__).resolve().parents[2] / "frontend" / "src" / "config.js"


def source() -> str:
    assert CONFIG.exists(), f"Expected the frontend config at {CONFIG}. The contract test needs the whole repo."
    return CONFIG.read_text()


def block(text: str, start: str, end: str) -> str:
    i = text.index(start)
    return text[i : text.index(end, i)]


def test_days_ahead():
    assert int(re.search(r"export const DAYS_AHEAD = (\d+)", source()).group(1)) == shop.DAYS_AHEAD


def test_slot_limits_match():
    """The dashboard's appointment-length picker offers exactly the lengths the API accepts."""
    text = source()
    found = {name: int(n) for name, n in re.findall(r"export const (SLOT_MIN|SLOT_MAX|SLOT_STEP|MAX_SERVICES) = (\d+)", text)}
    assert found == {
        "SLOT_MIN": shop.MIN_SLOT_MINUTES,
        "SLOT_MAX": shop.MAX_SLOT_MINUTES,
        "SLOT_STEP": shop.UNIT_MINUTES,
        "MAX_SERVICES": shop.MAX_SERVICES,
    }


def test_default_slot_lengths_match():
    """The site starts from the same appointment lengths as the backend (Monday and Tuesday 45, the rest 35)."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const SLOT_MINUTES_BY_DAY = {", "}")
    js = {int(day): int(minutes) for day, minutes in re.findall(r"(\d):\s*(\d+)", body)}
    assert set(js) == set(range(7))
    for js_day, minutes in js.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        assert REAL_DEFAULTS.slot_minutes[py_day] == minutes, f"JS day {js_day}"


def test_staff():
    assert "id: 'vic'" in block(source(), "export const STAFF", "\n")


def test_hours_match():
    body = block(source(), "export const HOURS = {", "\n}")
    body = re.sub(r"//[^\n]*", "", body).split("{", 1)[1]
    body = re.sub(r"at\((\d+),\s*(\d+)\)", r"(\1*60+\2)", body)
    body = re.sub(r"at\((\d+)\)", r"(\1*60)", body)
    js_hours = eval("{" + body.replace("null", "None") + "}", {"__builtins__": {}})  # our own repo file
    assert set(js_hours) == set(range(7))
    for js_day, windows in js_hours.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        expected = [tuple(w) for w in windows] if windows else None
        assert shop.HOURS[py_day] == expected, f"JS day {js_day}"


STRING = r"""(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")"""


def js_string(match_tuple) -> str:
    """Whichever of the two quote styles matched."""
    return match_tuple[0] or match_tuple[1]


def test_default_services_match():
    """The services the site starts with (before the API answers) are the backend's starting services, in the same order."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const SERVICES = [", "\n]")
    found = []
    for obj in re.findall(r"\{[^{}]*\}", body):
        sid = re.search(r"id:\s*" + STRING, obj)
        name = re.search(r"name:\s*" + STRING, obj)
        price = re.search(r"price:\s*(\d+)", obj)
        note = re.search(r"note:\s*" + STRING, obj)
        found.append(
            (
                js_string(sid.groups()),
                js_string(name.groups()),
                int(price.group(1)),
                "from: true" in obj,
                js_string(note.groups()) if note else "",
            )
        )
    assert found, "No services found in the frontend config"
    assert found == [(s.id, s.name, s.price, s.from_price, s.note) for s in REAL_DEFAULTS.services]


def test_input_limits_match():
    """The booking form's character limits (and the 0/500 counter) must be the same numbers the API enforces."""
    from app.schemas import requests

    match = re.search(r"export const LIMITS = \{\s*name:\s*(\d+),\s*notes:\s*(\d+)\s*\}", source())
    assert match, "frontend/src/config.js has no LIMITS yet. Run update-vicbless-notes-counter.sh (from inside frontend/) first."
    assert (int(match.group(1)), int(match.group(2))) == (requests.NAME_MAX, requests.NOTES_MAX)


def test_contact_email_matches():
    """The email customers are told to write to is the same on the site and in the emails and error messages."""
    from app.core.brand import CONTACT_EMAIL

    match = re.search(r"email:\s*'([^']+)'", block(source(), "export const BUSINESS", "\n}"))
    assert match and match.group(1) == CONTACT_EMAIL


def test_reminder_choices_and_defaults_match_the_site():
    """The dashboard offers the same reminder times the API accepts, and starts from the same ones."""
    text = source()
    choices = re.search(r"export const REMINDER_CHOICES = \[([\d,\s]+)\]", text)
    default = re.search(r"export const REMINDER_HOURS_DEFAULT = \[([\d,\s]+)\]", text)
    assert choices and default, "frontend/src/config.js is missing REMINDER_CHOICES or REMINDER_HOURS_DEFAULT"
    as_ints = lambda m: tuple(int(n) for n in re.findall(r"\d+", m.group(1)))  # noqa: E731
    assert sorted(as_ints(choices)) == sorted(shop.REMINDER_CHOICES)
    assert as_ints(default) == shop.DEFAULT_SETTINGS.reminder_hours


def test_the_consent_line_on_the_booking_form_says_what_carriers_expect():
    text = source()
    line = re.search(r"export const SMS_CONSENT = '([^']+)'", text)
    assert line, "frontend/src/config.js has no SMS_CONSENT"
    assert "Msg & data rates may apply" in line.group(1) and "Reply STOP to opt out" in line.group(1)


def test_after_hours_defaults_match():
    """After Hours Cuts starts the same on the site and in the API: id, name, price, description, and the late appointments per day."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const AFTER_HOURS = {", "\n}")
    js_id = js_string(re.search(r"id:\s*" + STRING, body).groups())
    js_name = js_string(re.search(r"name:\s*" + STRING, body).groups())
    js_note = js_string(re.search(r"note:\s*" + STRING, body).groups())
    js_price = int(re.search(r"price:\s*(\d+)", body).group(1))
    slots = re.search(r"slots:\s*\{([^}]*)\}", body).group(1)
    js_slots = {int(k): int(v) for k, v in re.findall(r"(\d):\s*(\d+)", slots)}
    assert js_id == shop.AFTER_HOURS_ID and js_name == shop.AFTER_HOURS_NAME
    assert js_price == REAL_DEFAULTS.after_hours.price and js_note == REAL_DEFAULTS.after_hours.note
    for js_day, count in js_slots.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        assert REAL_DEFAULTS.after_hours.slots[py_day] == count, f"JS day {js_day}"
    assert len(js_slots) == 7
    max_slots = int(re.search(r"export const MAX_AFTER_SLOTS = (\d+)", source()).group(1))
    assert max_slots == shop.MAX_AFTER_SLOTS
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
import { useMemo, useState } from 'react'
import { fmtTime, fromKey } from '../lib/availability.js'
import { dayGrid, describeRange, findConflicts, rangeFromChoice, wholeDayRange } from './blocks.js'
import { hoursFor, isAfterStart, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { addBlock } from './adminApi.js'

// "Block off time": part of the day or the whole day, with an optional note (Lunch, Phone booking...).
// It will not let Vic block over a booking or over time that is already blocked, and says which.
export default function BlockOff({ dateKey, items, blocks, onSaved, onClose }) {
  const shop = useShopSettings()
  const date = useMemo(() => fromKey(dateKey), [dateKey])
  const SLOT_MINUTES = slotFor(shop, date) // how long an appointment is on this day
  const hours = useMemo(() => hoursFor(shop), [shop]) // opening hours with the late appointments added
  const grid = useMemo(() => dayGrid({ date, hours, slotMinutes: SLOT_MINUTES }), [date, hours, SLOT_MINUTES])

  const [mode, setMode] = useState('part')
  const [from, setFrom] = useState(grid[0])
  const [until, setUntil] = useState(grid[0])
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const choice =
    mode === 'whole'
      ? wholeDayRange({ date, hours })
      : rangeFromChoice({ grid, fromStart: from, untilStart: until, slotMinutes: SLOT_MINUTES })
  const range = choice && !choice.error ? choice : null
  const rangeProblem = choice && choice.error ? choice.error : ''
  const conflicts = range ? findConflicts({ range, grid, items, blocks, slotMinutes: SLOT_MINUTES }) : { bookings: [], blocks: [] }
  const hasConflict = conflicts.bookings.length > 0 || conflicts.blocks.length > 0
  const canSave = !!range && !hasConflict && !saving

  async function submit(e) {
    e.preventDefault()
    if (!canSave) return
    setSaving(true)
    setError('')
    try {
      await addBlock({ dateKey, start: range.start, end: range.end, note, whole: mode === 'whole' })
      onSaved(
        mode === 'whole'
          ? 'Day off saved. Customers see the whole day as unavailable.'
          : `Blocked ${describeRange(range.start, range.end)}. Customers see it as unavailable.`,
      )
    } catch (ex) {
      setError(
        ex.code === 'CONFLICT'
          ? 'Something changed while you were choosing. Check the schedule and try again.'
          : 'Could not save. Try again.',
      )
      setSaving(false)
    }
  }

  return (
    <form className="admin-block-form" onSubmit={submit} noValidate aria-label="Block off time">
      <h3>Block off time</h3>

      <fieldset>
        <legend>What do you want to block?</legend>
        <label className="admin-radio">
          <input type="radio" name="block-mode" value="part" checked={mode === 'part'} onChange={() => setMode('part')} />
          Part of the day
        </label>
        <label className="admin-radio">
          <input type="radio" name="block-mode" value="whole" checked={mode === 'whole'} onChange={() => setMode('whole')} />
          The whole day
        </label>
      </fieldset>

      {mode === 'part' && (
        <div className="admin-block-times">
          <div className="field">
            <label htmlFor="block-from">From</label>
            <select
              id="block-from"
              value={from}
              onChange={(e) => {
                const value = Number(e.target.value)
                setFrom(value)
                if (until < value) setUntil(value)
              }}
            >
              {grid.map((s) => (
                <option key={s} value={s}>
                  {fmtTime(s)}
                  {isAfterStart(date, s) ? ' (after hours)' : ''}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="block-until">Until</label>
            <select id="block-until" value={until} onChange={(e) => setUntil(Number(e.target.value))}>
              {grid.map((s) => (
                <option key={s} value={s}>
                  {fmtTime(s + SLOT_MINUTES)}
                  {isAfterStart(date, s) ? ' (after hours)' : ''}
                </option>
              ))}
            </select>
          </div>
        </div>
      )}

      <div className="field">
        <label htmlFor="block-note">
          Note <span className="hint">(optional)</span>
        </label>
        <input
          id="block-note"
          value={note}
          maxLength={80}
          placeholder="Lunch, errand, phone booking..."
          onChange={(e) => setNote(e.target.value)}
        />
      </div>

      {rangeProblem && (
        <p className="err" role="alert">
          {rangeProblem}
        </p>
      )}

      {hasConflict && (
        <div className="admin-conflicts" role="alert">
          {conflicts.bookings.map((item) => (
            <p key={item.id}>
              {item.name} is booked at {fmtTime(item.start)}. Cancel that booking first, or pick other times.
            </p>
          ))}
          {conflicts.blocks.map((block) => (
            <p key={block.id}>{describeRange(block.start, block.end)} is already blocked. Remove that block first.</p>
          ))}
        </div>
      )}

      {error && (
        <p className="err" role="alert">
          {error}
        </p>
      )}

      <div className="actions">
        <button type="button" className="btn" onClick={onClose} disabled={saving}>
          Close
        </button>
        <button type="submit" className="btn btn-primary" disabled={!canSave}>
          {saving ? 'Saving…' : 'Block this time'}
        </button>
      </div>
    </form>
  )
}
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { getAvailability } from '../lib/api.js'
import { fmtTime, fromKey, keyOf, slotStarts } from '../lib/availability.js'
import { AFTER_HOURS_ID, findService, hoursFor, isAfterStart, slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { moveBooking } from './adminApi.js'
import { moveDateRange, moveOptions, ownStarts } from './moveTimes.js'

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/
const dayLabel = (dateKey) => fromKey(dateKey).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })

// "Change time": Vic picks a new day and one of its free times for an existing booking.
// Times that are taken or blocked are shown greyed out, so he can see why they cannot be picked.
// The API has the final say (it refuses a time that was taken a moment ago), and this screen says so.
export default function MoveBooking({ item, onClose, onMoved }) {
  const dateId = useId()
  const range = useMemo(() => moveDateRange(new Date()), [])
  const [dateKey, setDateKey] = useState(item.dateKey)
  const [day, setDay] = useState({ status: 'loading' })
  const [picked, setPicked] = useState(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const shop = useShopSettings()
  const service = findService(shop, item.serviceId)
  const serviceName = item.serviceName || (service ? service.name : 'Appointment')
  const sameDay = dateKey === item.dateKey

  // Look up the chosen day's taken times. A newer choice cancels the answer to an older one.
  useEffect(() => {
    let alive = true
    setDay({ status: 'loading' })
    setPicked(null)
    getAvailability([dateKey])
      .then((all) => alive && setDay({ status: 'ready', ...all[dateKey] }))
      .catch(() => alive && setDay({ status: 'error' }))
    return () => {
      alive = false
    }
  }, [dateKey])

  const options = useMemo(() => {
    if (day.status !== 'ready') return []
    const now = new Date()
    // The booking takes the appointment length of the day it is moved to (the API does the same).
    const date = fromKey(dateKey)
    const slot = slotFor(shop, date)
    const hours = hoursFor(shop)
    // A late booking moves only to another late time, and a regular one only to a regular time (the API checks the same).
    const late = item.serviceId === AFTER_HOURS_ID
    return moveOptions({
      date,
      hours,
      slotMinutes: slot,
      minutes: slot,
      busy: day.busy,
      own: sameDay ? ownStarts(item, slot, slotStarts(date, hours, slot)) : [],
      current: sameDay ? item.start : null,
      nowMinutes: dateKey === keyOf(now) ? now.getHours() * 60 + now.getMinutes() : null,
    }).filter((o) => isAfterStart(date, o.start) === late)
  }, [day, dateKey, item, sameDay, shop])

  const anyFree = options.some((o) => o.state === 'free')

  function pickDay(value) {
    // Clearing the field, or typing a day outside the allowed range, does nothing.
    if (DATE_PATTERN.test(value) && value >= range.min && value <= range.max) setDateKey(value)
  }

  async function submit(e) {
    e.preventDefault()
    if (picked === null || saving) return
    setSaving(true)
    setError('')
    try {
      await moveBooking(item, { dateKey, start: picked })
      onMoved(`Moved ${item.name} to ${dayLabel(dateKey)} at ${fmtTime(picked)}.`)
    } catch (ex) {
      setError(
        ex.code === 'CONFLICT'
          ? 'That time was just taken. Pick another one.'
          : 'Could not move it. Nothing was changed. Try again.',
      )
      setSaving(false)
      if (ex.code === 'CONFLICT') {
        // Show the fresh picture of the day so the time that was just taken is greyed out.
        getAvailability([dateKey]).then((all) => setDay({ status: 'ready', ...all[dateKey] })).catch(() => {})
        setPicked(null)
      }
    }
  }

  return (
    <form className="admin-block-form admin-move-form" onSubmit={submit} noValidate aria-label={`Change ${item.name}'s time`}>
      <h3>Change time</h3>
      <p className="admin-meta">
        {item.name}, {serviceName}. Now: {dayLabel(item.dateKey)} at {fmtTime(item.start)}.
      </p>

      <div className="field">
        <label htmlFor={dateId}>New day</label>
        <input id={dateId} type="date" min={range.min} max={range.max} value={dateKey} onChange={(e) => pickDay(e.target.value)} />
      </div>

      {day.status === 'loading' && (
        <p role="status" className="admin-status">
          Checking {dayLabel(dateKey)}…
        </p>
      )}
      {day.status === 'error' && (
        <p className="err" role="alert">
          Could not check that day. Pick the day again to retry.
        </p>
      )}
      {day.status === 'ready' && options.length === 0 && <p className="empty">Vic is closed that day. Pick another day.</p>}
      {day.status === 'ready' && options.length > 0 && !anyFree && (
        <p className="empty">Nothing is free that day. Pick another day.</p>
      )}

      {options.length > 0 && (
        <div className="admin-move-times" role="group" aria-label="Pick a new time">
          {options.map((o) => {
            const label = fmtTime(o.start)
            const note = { taken: ', taken', current: ', where it is now', past: ', already passed' }[o.state] || ''
            return (
              <button
                key={o.start}
                type="button"
                className={`admin-move-time admin-move-${o.state}`}
                disabled={o.state !== 'free'}
                aria-pressed={picked === o.start}
                aria-label={label + note}
                onClick={() => setPicked(o.start)}
              >
                {label}
                {isAfterStart(fromKey(dateKey), o.start) && <span className="admin-move-late">After hours</span>}
                {o.state === 'current' && <span className="admin-move-now">now</span>}
              </button>
            )
          })}
        </div>
      )}

      {picked !== null && (
        <p className="admin-move-summary" role="status">
          Move {item.name} to {dayLabel(dateKey)} at {fmtTime(picked)}? If they left an email, they are told about the new time.
        </p>
      )}

      {error && (
        <p className="err" role="alert">
          {error}
        </p>
      )}

      <div className="actions">
        <button type="button" className="btn" onClick={onClose} disabled={saving}>
          Close
        </button>
        <button type="submit" className="btn btn-primary" disabled={picked === null || saving}>
          {saving ? 'Moving…' : picked === null ? 'Pick a time' : `Move to ${fmtTime(picked)}`}
        </button>
      </div>
    </form>
  )
}
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
import { useEffect, useMemo, useRef, useState } from 'react'
import { fmtTime, fromKey, keyOf } from '../lib/availability.js'
import { formatPhone, mailtoHref, telHref } from '../lib/format.js'
import { AFTER_HOURS_ID, findService, hoursFor, slotFor } from '../lib/shopSettings.js'
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
    <article className={item.serviceId === AFTER_HOURS_ID ? 'admin-card admin-card-after' : 'admin-card'}>
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
        {item.serviceId === AFTER_HOURS_ID && <span className="after-badge">After hours</span>}
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
            hours: hoursFor(shop),
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
      {previous && !group.after && (
        <li className="admin-break">
          Break, {fmtTime(previous.close)} to {fmtTime(group.open)}
        </li>
      )}
      {group.after && <li className="admin-after-divider">After hours</li>}
      {group.rows.map((row) => (
        <li key={row.start} className={`admin-row admin-${row.kind}${group.after ? ' admin-row-after' : ''}`}>
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
cat > "$STAGE/15" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { AFTER_HOURS, HOURS, MAX_AFTER_SLOTS, MAX_SERVICES, REMINDER_CHOICES, SLOT_MAX, SLOT_MIN, SLOT_STEP } from '../config.js'
import { fmtTime } from '../lib/availability.js'
import {
  DAY_NAMES,
  NAME_MAX,
  NOTE_MAX,
  PRICE_MAX,
  checkDraft,
  draftFrom,
  fromApi,
  isChanged,
  newDraftService,
  setShopSettings,
  toApi,
  toggleReminder,
} from '../lib/shopSettings.js'
import { getAdminSettings, saveSettings } from './adminApi.js'

const NO_ERRORS = { general: '', services: {}, slots: {}, after: { slots: {} } }

// Monday first, the way people read a week (the numbers are JavaScript's: 0 is Sunday).
const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0]

const hoursText = (day) => {
  const windows = HOURS[day]
  return windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'
}

// Vic's shop settings, only reachable from inside his dashboard (Menu > Settings > Shop settings):
//   - the services, their prices and notes (add, rename, reorder, remove)
//   - After Hours Cuts: its price, its description, and how many late appointments each open weekday has
//   - how long an appointment is on each weekday, in steps of 5 minutes
// Saving changes what customers see and book straight away. Bookings already made keep their times and names.
export default function SettingsPanel({ onClose }) {
  const [saved, setSaved] = useState(null) // the settings as last saved, in the screens' shape
  const [draft, setDraft] = useState(null) // what Vic is editing
  const [errors, setErrors] = useState(NO_ERRORS)
  const [status, setStatus] = useState('loading') // loading | ready | error
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')
  const [failure, setFailure] = useState('')
  const [attempt, setAttempt] = useState(0)
  const uid = useId()

  useEffect(() => {
    let alive = true
    setStatus('loading')
    getAdminSettings()
      .then((raw) => {
        const parsed = fromApi(raw)
        if (!alive) return
        if (!parsed) throw new Error('unreadable')
        setSaved(parsed)
        setDraft(draftFrom(parsed))
        setStatus('ready')
      })
      .catch(() => alive && setStatus('error'))
    return () => {
      alive = false
    }
  }, [attempt])

  const changed = useMemo(() => !!draft && !!saved && isChanged(draft, saved), [draft, saved])

  const touch = (change) => {
    setDraft((d) => change(d))
    setMessage('')
    setFailure('')
  }
  const editService = (key, field, value) =>
    touch((d) => ({ ...d, services: d.services.map((s) => (s.key === key ? { ...s, [field]: value } : s)) }))
  const move = (index, by) =>
    touch((d) => {
      const services = [...d.services]
      const target = index + by
      if (target < 0 || target >= services.length) return d
      ;[services[index], services[target]] = [services[target], services[index]]
      return { ...d, services }
    })
  const remove = (key) => touch((d) => ({ ...d, services: d.services.filter((s) => s.key !== key) }))
  const add = () => touch((d) => ({ ...d, services: [...d.services, newDraftService()] }))

  async function submit(e) {
    e.preventDefault()
    if (saving) return
    const result = checkDraft(draft)
    setErrors(result.ok ? NO_ERRORS : result.errors)
    if (!result.ok) {
      setFailure('Some things need fixing. They are marked below.')
      return
    }
    setSaving(true)
    setFailure('')
    setMessage('')
    try {
      const reply = fromApi(await saveSettings(toApi(result.settings)))
      if (!reply) throw new Error('unreadable')
      setSaved(reply)
      setDraft(draftFrom(reply))
      setShopSettings(reply) // every page open in this browser now shows the new settings
      setMessage('Saved. Customers see the new services and times right away.')
    } catch (ex) {
      // The API's own sentence is written for Vic ("Two services have the same name...").
      setFailure(ex && ex.message && ex.code !== 'network' ? ex.message : 'Could not save. Nothing was changed. Try again.')
    } finally {
      setSaving(false)
    }
  }

  if (status === 'loading') {
    return (
      <section className="admin-settings" aria-label="Shop settings">
        <p role="status" className="admin-status">
          Loading your settings…
        </p>
      </section>
    )
  }
  if (status === 'error') {
    return (
      <section className="admin-settings" aria-label="Shop settings">
        <p className="err" role="alert">
          Could not load your settings.
        </p>
        <div className="actions">
          <button type="button" className="btn" onClick={onClose}>
            Back to schedule
          </button>
          <button type="button" className="btn btn-primary" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      </section>
    )
  }

  return (
    <form className="admin-settings" onSubmit={submit} noValidate aria-label="Shop settings">
      <div className="admin-settings-head">
        <h2>Shop settings</h2>
        <button type="button" className="admin-box-btn" onClick={onClose}>
          Back to schedule
        </button>
      </div>
      <p className="admin-meta">Changes apply to new bookings as soon as you save. Bookings already made keep their time and service name.</p>

      <fieldset className="admin-settings-group">
        <legend>Services and prices</legend>
        {errors.general && (
          <p className="err" role="alert">
            {errors.general}
          </p>
        )}
        <ul className="admin-svc-list">
          {draft.services.map((s, i) => {
            const e = errors.services[s.key] || {}
            return (
              <li key={s.key} className="admin-svc">
                <div className="field">
                  <label htmlFor={`${uid}-n-${s.key}`}>Service name</label>
                  <input id={`${uid}-n-${s.key}`} value={s.name} maxLength={NAME_MAX} aria-invalid={!!e.name} onChange={(ev) => editService(s.key, 'name', ev.target.value)} />
                  {e.name && <p className="err">{e.name}</p>}
                </div>
                <div className="admin-svc-price">
                  <div className="field">
                    <label htmlFor={`${uid}-p-${s.key}`}>Price ($)</label>
                    <input id={`${uid}-p-${s.key}`} inputMode="numeric" value={s.price} maxLength={3} aria-invalid={!!e.price} onChange={(ev) => editService(s.key, 'price', ev.target.value)} />
                    {e.price && <p className="err">{e.price}</p>}
                  </div>
                  <label className="admin-radio admin-svc-from">
                    <input type="checkbox" checked={s.from} onChange={(ev) => editService(s.key, 'from', ev.target.checked)} />
                    Starting price (shown as ${s.price.trim() || '0'}+)
                  </label>
                </div>
                <div className="field">
                  <label htmlFor={`${uid}-t-${s.key}`}>
                    Note <span className="hint">(optional, shown under the service)</span>
                  </label>
                  <input id={`${uid}-t-${s.key}`} value={s.note} aria-invalid={!!e.note} onChange={(ev) => editService(s.key, 'note', ev.target.value)} />
                  <p className="counter">
                    {s.note.length}/{NOTE_MAX}
                  </p>
                  {e.note && <p className="err">{e.note}</p>}
                </div>
                <div className="admin-svc-actions">
                  <button type="button" className="admin-box-btn" disabled={i === 0} onClick={() => move(i, -1)} aria-label={`Move ${s.name || 'this service'} up`}>
                    Move Up
                  </button>
                  <button type="button" className="admin-box-btn" disabled={i === draft.services.length - 1} onClick={() => move(i, 1)} aria-label={`Move ${s.name || 'this service'} down`}>
                    Move Down
                  </button>
                  <button type="button" className="admin-box-btn admin-box-danger" disabled={draft.services.length <= 1} onClick={() => remove(s.key)} aria-label={`Remove ${s.name || 'this service'}`}>
                    Remove
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
        <button type="button" className="btn" onClick={add} disabled={draft.services.length >= MAX_SERVICES}>
          Add a service
        </button>
        {draft.services.length >= MAX_SERVICES && <p className="admin-meta">That is the most you can list ({MAX_SERVICES}).</p>}
      </fieldset>

      <fieldset className="admin-settings-group admin-after-group">
        <legend>{AFTER_HOURS.name}</legend>
        <p className="admin-meta">
          Late appointments that start the moment the shop closes. Customers book them as one service with its own price, and they
          are marked "After hours" on the site. Set how many each day has: 0 turns the day off, and you can add up to {MAX_AFTER_SLOTS}.
        </p>
        <div className="admin-svc-price">
          <div className="field">
            <label htmlFor={`${uid}-ap`}>Price ($)</label>
            <input id={`${uid}-ap`} inputMode="numeric" value={draft.after.price} maxLength={3} aria-invalid={!!errors.after.price} onChange={(ev) => touch((d) => ({ ...d, after: { ...d.after, price: ev.target.value } }))} />
            {errors.after.price && <p className="err">{errors.after.price}</p>}
          </div>
        </div>
        <div className="field">
          <label htmlFor={`${uid}-an`}>
            Description <span className="hint">(shown under the service)</span>
          </label>
          <input id={`${uid}-an`} value={draft.after.note} aria-invalid={!!errors.after.note} onChange={(ev) => touch((d) => ({ ...d, after: { ...d.after, note: ev.target.value } }))} />
          <p className="counter">
            {draft.after.note.length}/{NOTE_MAX}
          </p>
          {errors.after.note && <p className="err">{errors.after.note}</p>}
        </div>
        <ul className="admin-slot-list">
          {WEEK_ORDER.filter((day) => HOURS[day]).map((day) => {
            const windows = HOURS[day]
            return (
              <li key={day} className="admin-slot-row">
                <div className="admin-slot-day">
                  <label htmlFor={`${uid}-a-${day}`}>{DAY_NAMES[day]}</label>
                  <span className="admin-meta">Starting at {fmtTime(windows[windows.length - 1][1])}</span>
                </div>
                <div className="admin-slot-input">
                  <input
                    id={`${uid}-a-${day}`}
                    type="number"
                    inputMode="numeric"
                    min={0}
                    max={MAX_AFTER_SLOTS}
                    step={1}
                    value={draft.after.slots[day]}
                    aria-invalid={!!errors.after.slots[day]}
                    onChange={(ev) => touch((d) => ({ ...d, after: { ...d.after, slots: { ...d.after.slots, [day]: ev.target.value } } }))}
                  />
                  <span aria-hidden="true">late</span>
                </div>
                {errors.after.slots[day] && <p className="err">{errors.after.slots[day]}</p>}
              </li>
            )
          })}
        </ul>
        <p className="admin-meta">Each late appointment is as long as that day's appointment length (below).</p>
      </fieldset>

      <fieldset className="admin-settings-group">
        <legend>How long an appointment is</legend>
        <p className="admin-meta">
          Each day's times are cut into appointments of this length, from {SLOT_MIN} to {SLOT_MAX} minutes, in steps of {SLOT_STEP} (for example 25, 35 or 45).
        </p>
        <ul className="admin-slot-list">
          {WEEK_ORDER.map((day) => (
            <li key={day} className="admin-slot-row">
              <div className="admin-slot-day">
                <label htmlFor={`${uid}-d-${day}`}>{DAY_NAMES[day]}</label>
                <span className="admin-meta">{hoursText(day)}</span>
              </div>
              <div className="admin-slot-input">
                <input
                  id={`${uid}-d-${day}`}
                  type="number"
                  inputMode="numeric"
                  min={SLOT_MIN}
                  max={SLOT_MAX}
                  step={SLOT_STEP}
                  value={draft.slots[day]}
                  aria-invalid={!!errors.slots[day]}
                  aria-describedby={errors.slots[day] ? `${uid}-e-${day}` : undefined}
                  onChange={(ev) => touch((d) => ({ ...d, slots: { ...d.slots, [day]: ev.target.value } }))}
                />
                <span aria-hidden="true">min</span>
              </div>
              {errors.slots[day] && (
                <p className="err" id={`${uid}-e-${day}`}>
                  {errors.slots[day]}
                </p>
              )}
            </li>
          ))}
        </ul>
      </fieldset>

      <fieldset className="admin-settings-group">
        <legend>Reminders</legend>
        <p className="admin-meta">
          Tick when customers get a reminder before their appointment. They get it by email if they left one, and by text if they
          ticked the box to be texted. A reminder is never sent for a time that had already passed when the booking was made.
        </p>
        <ul className="admin-remind-list">
          {[...REMINDER_CHOICES].sort((a, b) => b - a).map((hours) => (
            <li key={hours}>
              <label className="admin-radio">
                <input type="checkbox" checked={draft.reminders.includes(hours)} onChange={() => touch((d) => toggleReminder(d, hours))} />
                {hours === 1 ? '1 hour before' : hours === 48 ? '2 days before' : hours === 24 ? '1 day before' : `${hours} hours before`}
              </label>
            </li>
          ))}
        </ul>
        {draft.reminders.length === 0 && <p className="admin-meta">No reminders will be sent.</p>}
      </fieldset>

      {failure && (
        <p className="err" role="alert">
          {failure}
        </p>
      )}
      {message && (
        <p className="admin-flash" role="status">
          {message}
        </p>
      )}

      <div className="actions">
        <button type="button" className="btn" onClick={onClose} disabled={saving}>
          {changed ? 'Discard and go back' : 'Back to schedule'}
        </button>
        <button type="submit" className="btn btn-primary" disabled={!changed || saving}>
          {saving ? 'Saving…' : 'Save settings'}
        </button>
      </div>
    </form>
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
  margin-left: 8px;
  vertical-align: middle;
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
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
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
import { fromKey, slotStarts } from '../lib/availability.js'
import { afterService, fromApi, isAfterStart, toApi } from '../lib/shopSettings.js'
import {
  blockedStartsFor,
  hoursNow,
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
VICBLESS_EOF
cat > "$STAGE/18" <<'VICBLESS_EOF'
import { blocksFor } from '../lib/availability.js'

// Turns one day's bookings and blocked time into the rows of the schedule. Pure, so it is easy to test.
//   hours    map of dayIndex -> [[open, close], ...] | null   (minutes after midnight)
//   items    bookings for that day: { start, minutes, ...details }
//   blocks   time Vic blocked off: { start, end, ...details }
//
// Every 35 minute block in the open windows becomes a row: a booking, the continuation of a longer
// booking, blocked, still blocked, or open. Nothing is ever hidden: a booking that does not land on
// the grid (for example if the hours were changed after it was made) comes back in `unmatched`, and a
// block with no free row to sit on comes back in `unmatchedBlocks`. A booking always wins over a block.
export function buildDayRows({ date, hours, items, blocks = [], slotMinutes = 35 }) {
  const windows = hours[date.getDay()]
  if (!windows) {
    return { closed: true, groups: [], unmatched: [], unmatchedBlocks: [], booked: 0, blocked: 0, open: 0 }
  }

  const byStart = new Map()
  for (const item of items) {
    const count = blocksFor(item.minutes, slotMinutes)
    for (let k = 0; k < count; k++) {
      byStart.set(item.start + k * slotMinutes, k === 0 ? { kind: 'booking', item } : { kind: 'continues', item })
    }
  }

  const shown = new Set()
  const groups = windows.map(([open, close, kind]) => {
    const rows = []
    for (let start = open; start + slotMinutes <= close; start += slotMinutes) {
      const hit = byStart.get(start)
      if (hit) shown.add(hit.item)
      rows.push({ start, ...(hit || { kind: 'open' }) })
    }
    return { open, close, rows, after: kind === 'after' }
  })

  const allRows = groups.flatMap((g) => g.rows)
  const placed = new Set()
  for (const block of blocks) {
    let first = true
    for (const row of allRows) {
      if (row.kind === 'open' && row.start >= block.start && row.start < block.end) {
        row.kind = first ? 'blocked' : 'blocked-continues'
        row.block = block
        first = false
        placed.add(block)
      }
    }
  }

  return {
    closed: false,
    groups,
    unmatched: items.filter((item) => !shown.has(item)),
    unmatchedBlocks: blocks.filter((block) => !placed.has(block)),
    booked: allRows.filter((r) => r.kind === 'booking' || r.kind === 'continues').length,
    blocked: allRows.filter((r) => r.kind === 'blocked' || r.kind === 'blocked-continues').length,
    open: allRows.filter((r) => r.kind === 'open').length,
  }
}
VICBLESS_EOF
cat > "$STAGE/19" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { buildDayRows } from './schedule.js'

const at = (h, m = 0) => h * 60 + m
const HOURS = {
  0: null,
  1: [[at(12), at(18)]],
  2: [[at(12), at(18)]],
  3: null,
  4: [[at(11), at(19)]],
  5: [[at(11), at(19)]],
  6: [
    [at(9), at(12)],
    [at(12, 35), at(17)],
  ],
}
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const build = (date, items = []) => buildDayRows({ date, hours: HOURS, items })

describe('buildDayRows', () => {
  it('a closed day has no rows', () => {
    const v = build(WEDNESDAY)
    expect(v.closed).toBe(true)
    expect(v.groups).toEqual([])
    expect(v.booked + v.open).toBe(0)
  })

  it('an empty open day is every block open', () => {
    const v = build(TUESDAY)
    expect(v.closed).toBe(false)
    expect(v.groups).toHaveLength(1)
    expect(v.groups[0].rows).toHaveLength(10)
    expect(v.open).toBe(10)
    expect(v.booked).toBe(0)
    expect(v.groups[0].rows[0].start).toBe(at(12))
    expect(v.groups[0].rows[1].start).toBe(at(12, 35))
  })

  it('puts each booking on its own block and counts booked and open', () => {
    const v = build(TUESDAY, [
      { start: at(12), minutes: 35, name: 'A' },
      { start: at(13, 10), minutes: 35, name: 'B' },
    ])
    const rows = v.groups[0].rows
    expect(rows[0].kind).toBe('booking')
    expect(rows[0].item.name).toBe('A')
    expect(rows[1].kind).toBe('open')
    expect(rows[2].kind).toBe('booking')
    expect(v.booked).toBe(2)
    expect(v.open).toBe(8)
  })

  it('a longer booking takes several blocks, shown as a booking plus continuations', () => {
    const v = build(TUESDAY, [{ start: at(12, 35), minutes: 70, name: 'Long' }])
    const rows = v.groups[0].rows
    expect(rows[1].kind).toBe('booking')
    expect(rows[2].kind).toBe('continues')
    expect(rows[2].item.name).toBe('Long')
    expect(rows[3].kind).toBe('open')
    expect(v.booked).toBe(2)
  })

  it('Saturday is two groups, each on its own grid', () => {
    const v = build(SATURDAY)
    expect(v.groups).toHaveLength(2)
    expect(v.groups[0].rows[0].start).toBe(at(9))
    expect(v.groups[1].rows[0].start).toBe(at(12, 35))
    expect(v.groups[0].close).toBe(at(12))
    expect(v.groups[1].open).toBe(at(12, 35))
  })

  it('never hides a booking that is not on the grid', () => {
    const odd = { start: at(14, 5), minutes: 35, name: 'Off grid' }
    const v = build(TUESDAY, [odd])
    expect(v.unmatched).toEqual([odd])
    expect(v.booked).toBe(0)
  })

  it('a booking on a day the shop is closed is not lost either', () => {
    const v = build(WEDNESDAY, [{ start: at(13), minutes: 35, name: 'Closed day' }])
    expect(v.closed).toBe(true)
  })

  it('a booking on the very last block is placed', () => {
    const v = build(TUESDAY, [{ start: at(12) + 9 * 35, minutes: 35, name: 'Last' }])
    expect(v.groups[0].rows.at(-1).kind).toBe('booking')
    expect(v.unmatched).toEqual([])
  })
})

describe('blocked time', () => {
  const block = (start, end, extra = {}) => ({ id: 'b', start, end, note: '', ...extra })

  it('fills the rows it covers: the first is blocked, the rest are still blocked', () => {
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [block(at(12, 35), at(14, 20))] })
    const rows = v.groups[0].rows
    expect(rows.map((r) => r.kind).slice(0, 6)).toEqual(['open', 'blocked', 'blocked-continues', 'blocked-continues', 'open', 'open'])
    expect(rows[1].block.id).toBe('b')
    expect(v.blocked).toBe(3)
    expect(v.open).toBe(7)
    expect(v.booked).toBe(0)
  })

  it('counts booked, blocked and open so they always add up to the day', () => {
    const v = buildDayRows({
      date: TUESDAY, hours: HOURS,
      items: [{ start: at(12), minutes: 35, name: 'A' }],
      blocks: [block(at(13, 10), at(14, 20))],
    })
    expect(v.booked + v.blocked + v.open).toBe(10)
    expect([v.booked, v.blocked, v.open]).toEqual([1, 2, 7])
  })

  it('a day off blocks every row', () => {
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [block(at(12), at(18), { whole: true })] })
    expect(v.groups[0].rows.every((r) => r.kind === 'blocked' || r.kind === 'blocked-continues')).toBe(true)
    expect(v.open).toBe(0)
  })

  it('a block runs across the Saturday break, each window keeping its own rows', () => {
    const v = buildDayRows({ date: SATURDAY, hours: HOURS, items: [], blocks: [block(at(11, 20), at(13, 10))] })
    expect(v.groups[0].rows.at(-1).kind).toBe('blocked')
    expect(v.groups[1].rows[0].kind).toBe('blocked-continues')
    expect(v.groups[1].rows[1].kind).toBe('open')
  })

  it('a booking always wins over a block, and is never hidden', () => {
    const v = buildDayRows({
      date: TUESDAY, hours: HOURS,
      items: [{ start: at(12, 35), minutes: 35, name: 'Booked' }],
      blocks: [block(at(12), at(14, 20))],
    })
    const rows = v.groups[0].rows
    expect(rows[1].kind).toBe('booking')
    expect(rows[0].kind).toBe('blocked')
    expect(rows[2].kind).toBe('blocked-continues')
  })

  it('a block with no free row to sit on is not lost', () => {
    const lonely = block(at(12), at(12, 35))
    const v = buildDayRows({ date: TUESDAY, hours: HOURS, items: [{ start: at(12), minutes: 35, name: 'Booked' }], blocks: [lonely] })
    expect(v.unmatchedBlocks).toEqual([lonely])
    const offGrid = block(at(3), at(4))
    expect(buildDayRows({ date: TUESDAY, hours: HOURS, items: [], blocks: [offGrid] }).unmatchedBlocks).toEqual([offGrid])
  })

  it('a closed day has no blocked rows', () => {
    expect(buildDayRows({ date: WEDNESDAY, hours: HOURS, items: [], blocks: [block(at(12), at(18))] }).closed).toBe(true)
  })
})

describe('after hours', () => {
  const THURSDAY = new Date(2026, 9, 15)
  const withLate = { ...HOURS, 4: [[at(11), at(19)], [at(19), at(20, 10), 'after']] }

  it('shows the late appointments as their own group, after the regular ones', () => {
    const v = buildDayRows({ date: THURSDAY, hours: withLate, items: [], slotMinutes: 35 })
    expect(v.groups.map((g) => g.after)).toEqual([false, true])
    expect(v.groups[1].rows.map((r) => r.start)).toEqual([at(19), at(19, 35)])
  })

  it('puts a late booking on its late row', () => {
    const item = { id: 'a', start: at(19, 35), minutes: 35 }
    const v = buildDayRows({ date: THURSDAY, hours: withLate, items: [item], slotMinutes: 35 })
    expect(v.groups[1].rows[1]).toMatchObject({ kind: 'booking', item })
    expect(v.unmatched).toEqual([])
  })

  it('lists a late booking that no longer has a late row among the other items', () => {
    const item = { id: 'a', start: at(19), minutes: 35 }
    const v = buildDayRows({ date: THURSDAY, hours: HOURS, items: [item], slotMinutes: 35 })
    expect(v.unmatched).toEqual([item])
  })
})
VICBLESS_EOF
cat > "$STAGE/20" <<'VICBLESS_EOF'
// Everything business-specific lives here.
// Hours, services, address and social links are Vic's real ones. The phone number is still a PLACEHOLDER.

export const BUSINESS = {
  name: 'Vicbless Barbershop',
  // How customers reach Vic. The site shows this email wherever it used to show the phone number.
  email: 'vicslegacy89@gmail.com',
  phone: '(555) 010-0123', // PLACEHOLDER, not shown anywhere on the site right now
  address: ['656 S Main St, Suite C', 'Baxley, GA 31513'],
}

export const SOCIAL = {
  tiktok: 'https://www.tiktok.com/@vicblesss',
  instagram: 'https://www.instagram.com/vicblessss',
}

// Vic is the only staff for now. Add more entries later and the booking
// payload already carries a staffId, so the data model will not change.
export const STAFF = [{ id: 'vic', name: 'Vic' }]

// Opening windows per weekday, in minutes after midnight. 0 = Sunday.
// null = closed. A day can have several windows (Saturday has a break).
const at = (h, m = 0) => h * 60 + m

export const HOURS = {
  0: null, // Sunday: closed
  1: [[at(12), at(18)]], // Monday 12:00 pm to 6:00 pm
  2: [[at(12), at(18)]], // Tuesday 12:00 pm to 6:00 pm
  3: null, // Wednesday: closed
  4: [[at(11), at(19)]], // Thursday 11:00 am to 7:00 pm
  5: [[at(11), at(19)]], // Friday 11:00 am to 7:00 pm
  6: [
    [at(9), at(12)], // Saturday 9:00 am to 12:00 pm
    [at(12, 35), at(17)], // and 12:35 pm to 5:00 pm
  ],
}

// What Vic can change from his dashboard (Settings > Shop settings): the services with their prices, and how long
// an appointment is on each weekday. The real values live in the database; these are the shop's STARTING values.
// The site shows them until the API answers and keeps using them if it never does, and the backend starts from the
// same numbers (a backend test fails if the two ever differ).
//
// price is the starting price in whole dollars. from: true shows it as "$65+".
export const SERVICES = [
  { id: 'mens-cut', name: "Men's haircut", price: 55 },
  {
    id: 'mens-design',
    name: "Men's haircut with design",
    price: 65,
    from: true,
    note: 'Small or freestyle design',
  },
  {
    id: 'mens-beard-eyebrow',
    name: "Men's haircut with beard and eyebrow",
    price: 65,
    from: true,
    note: 'Includes free hot towel if requested and hair styling',
  },
  {
    id: 'buzz-beard',
    name: 'Head buzzed/shave and beard',
    price: 40,
    note: 'Same price for just beards. Tell Vic in person if you want it buzzed or shaved.',
  },
  {
    id: 'kids-design',
    name: 'Kids cut (12 and under) with design',
    price: 40,
    from: true,
    note: '$5 extra for a small design, $10 more for a bigger design',
  },
]

// After Hours Cuts: late appointments after the shop closes, one service that covers everything. It is not one of the
// services above: it can only be booked at the after-hours times, and those times can only be booked with it.
// Vic edits the price, the description and how many late appointments each weekday has (0 = Sunday) in Shop settings.
// The backend starts from the same values (a backend test fails if the two ever differ).
export const AFTER_HOURS = {
  id: 'after-hours',
  name: 'After Hours Cuts',
  price: 70,
  note: 'Late appointments after the shop closes. Any cut, design, beard or eyebrow work, all in one price.',
  slots: { 0: 0, 1: 0, 2: 0, 3: 0, 4: 2, 5: 2, 6: 0 }, // Thursday (4) and Friday (5): 2 late appointments each
}
export const MAX_AFTER_SLOTS = 6 // the most late appointments Vic can add to one day

// How long one appointment is on each weekday, in minutes (0 = Sunday). Every service takes one appointment.
// Monday and Tuesday are 45 minutes (Vic's request); the other days are 35. Vic can change any day in 5 minute steps.
export const SLOT_MINUTES_BY_DAY = { 0: 35, 1: 45, 2: 45, 3: 35, 4: 35, 5: 35, 6: 35 }
export const SLOT_MIN = 15 // the shortest appointment Vic can set
export const SLOT_MAX = 120 // the longest
export const SLOT_STEP = 5 // lengths go up in steps of this many minutes
export const MAX_SERVICES = 12
export const DAYS_AHEAD = 14

// Appointment reminders. Vic switches each of these on or off in Shop settings. The numbers are hours before the
// appointment; the backend accepts exactly these (a backend test checks). Reminders go out by email and, for customers
// who ticked the box below, by text.
export const REMINDER_CHOICES = [48, 24, 12, 6, 4, 3, 2, 1]
export const REMINDER_HOURS_DEFAULT = [24, 2]

// The tick box on the booking form. Left unticked until the customer ticks it (texting someone needs their yes).
// Texts are sent for the confirmation, the reminders and any change Vic makes to the appointment.
export const SMS_CONSENT = 'Text me my confirmation, reminders and any changes. Msg & data rates may apply. Reply STOP to opt out.'

// The branded call to action. Used on every booking button.
export const CTA_TEXT = 'Book here to get blessed'

// The photo section under the video: headline, paragraph, and the words stacked over the photo.
export const STATEMENT = {
  headline: "EVERY CUT ISN'T JUST A CUT. IT'S A BLESSING.",
  body: 'Consistent precision cuts with clean detail and a personalized cut experience to give you confidence and blessings.',
  words: ['Quality', 'Detail', 'Consistency', 'Baxley, GA'],
}

// Call to action in the middle of the photo section (exact wording from Vic).
export const STATEMENT_CTA = 'Book Here to get blessed'

// Small credit in the footer.
export const CREDIT = { text: 'Website By RaynerCodes Cloud Solutions', url: 'https://raynercodes.dev' }

// Big headline on the screen shown after a booking is confirmed (exact wording from Vic).
// Two lines; the second one is shown in the purple accent colour.
export const SUCCESS_HEADLINE = ['If you wanna get fresh..', 'Come to Vicbless']

// Words shown at the top of the home page video, right under the logo. A TEST for Vic.
// One entry per line. The last line is shown in the purple accent colour.
// To hide it, change the list to just an empty pair of brackets.
export const HOME_TAGLINE = ['If you wanna get fresh,', 'come to VicBless']

// The most a customer may type. The booking form enforces these and shows the notes counter; the API
// enforces the same numbers, and a backend test fails if the two ever differ.
export const LIMITS = { name: 50, notes: 500 }

// Which comes first on the home page, a TEST for Vic (change this one word to compare the two looks):
//   'photo-first'  the photo section (headline, paragraph, stacked words) is the first thing under the logo, then the video
//   'video-first'  the video first, then the photo section (how it was)
export const HOME_ORDER = 'photo-first'
VICBLESS_EOF
cat > "$STAGE/21" <<'VICBLESS_EOF'
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

import { SlotTakenError } from './errors.js'
import { AFTER_HOURS_ID, DAY_KEYS, findService, isAfterStart } from './shopSettings.js'
import { fromKey, slotStarts } from './availability.js'
import {
  blockedStartsFor,
  hoursNow,
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
  for (const s of slotStarts(fromKey(dateKey), hoursNow(), slot)) {
    if (hash(dateKey + s) % 100 < 30 && !cancelled.has(s)) busy.add(s)
  }

  // real bookings made through the site: every appointment start they overlap is taken, whatever length they had
  const bookings = readBookings().filter((b) => b.dateKey === dateKey)
  for (const s of slotStarts(fromKey(dateKey), hoursNow(), slot)) {
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
    afterHours: {
      price: settings.afterHours.price,
      note: settings.afterHours.note,
      slots: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.afterHours.slots[day]])),
    },
    payOnline: true, // the preview shows the card option; "paying" in it simply marks the booking paid
  }
}

export async function createBooking(payload) {
  await delay(500)
  const slot = slotMinutesOn(payload.dateKey)
  if (busyFor(payload.dateKey).includes(payload.start) || !slotStarts(fromKey(payload.dateKey), hoursNow(), slot).includes(payload.start)) {
    throw new SlotTakenError()
  }
  // After Hours Cuts goes only in the late times, and those take only it (the real backend checks the same)
  if ((payload.serviceId === AFTER_HOURS_ID) !== isAfterStart(fromKey(payload.dateKey), payload.start)) {
    throw new SlotTakenError()
  }
  const code = 'VB-' + hash(JSON.stringify(payload) + Date.now()).toString(36).toUpperCase().slice(0, 5)
  // The service's name is kept with the booking, like the real backend does, so a later rename does not change it.
  const service = findService(readShopSettings(), payload.serviceId)
  // Paying online is pretended here: the booking is simply marked paid. The real API sends the customer to Stripe.
  const payment = payload.payment === 'online' ? 'paid' : 'shop'
  const amountCents = service ? service.price * 100 : 0
  const booking = { ...payload, minutes: slot, serviceName: service ? service.name : '', code, payment, amountCents }
  writeBookings([...readBookings(), booking])
  return booking
}
VICBLESS_EOF
cat > "$STAGE/22" <<'VICBLESS_EOF'
// MOCK storage shared by the customer-facing mock (lib/api.js) and the admin mock.
// It exists so that cancelling or blocking time in the dashboard changes what customers see.
// It goes away when the real backend exists.

import { fromKey, slotStarts } from './availability.js'
import { DEFAULT_SHOP_SETTINGS, fromApi, hoursFor, slotFor } from './shopSettings.js'

const KEYS = {
  bookings: 'vicbless.bookings', // bookings made through the site
  blocks: 'vicbless.blocks', // time Vic blocked off
  cancelledSamples: 'vicbless.cancelledSamples', // sample bookings Vic cancelled in the dashboard
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
cat > "$STAGE/23" <<'VICBLESS_EOF'
// Vic's shop settings: the services with their prices, and how long an appointment is on each weekday.
//
// The real values live in the database (Vic edits them in his dashboard). This file holds the pure helpers that
// turn what the API sends into what the screens use, check what Vic typed, and a tiny shared store so every page
// sees the same settings. Nothing here talks to the network except loadShopSettings().
//
// Shape used by the screens ("settings"):
//   { services: [{ id, name, price, from, note }], slotMinutes: { 0: 35, 1: 45, ... 6: 35 }, reminderHours: [24, 2],
//     afterHours: { price, note, slots: { 0: 0, ... 4: 2, 5: 2, 6: 0 } } }
//   (0 = Sunday; reminderHours = how many hours before an appointment a reminder goes out, biggest first;
//    afterHours = the After Hours Cuts offer: its price, its description and how many late appointments each weekday has)
// The API uses weekday names instead of numbers ({ mon: 45 }); fromApi / toApi convert.

import {
  AFTER_HOURS,
  HOURS,
  MAX_AFTER_SLOTS,
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
  afterHours: { price: AFTER_HOURS.price, note: AFTER_HOURS.note, slots: { ...AFTER_HOURS.slots } },
})

// Reminder times, biggest first, only ones Vic is allowed to pick, each once.
const cleanHours = (list) => [...new Set(list)].filter((h) => REMINDER_CHOICES.includes(h)).sort((a, b) => b - a)

const isCount = (n) => Number.isInteger(n) && n >= 0 && n <= MAX_AFTER_SLOTS

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
  // After Hours Cuts. An answer from before it existed has none: keep the starting offer.
  let afterHours = DEFAULT_SHOP_SETTINGS.afterHours
  if (raw.afterHours !== undefined) {
    const a = raw.afterHours
    if (!a || !Number.isInteger(a.price) || typeof a.note !== 'string' || !a.slots || typeof a.slots !== 'object') return null
    const slots = {}
    for (let day = 0; day < 7; day++) {
      const count = a.slots[DAY_KEYS[day]]
      if (!isCount(count)) return null
      slots[day] = count
    }
    afterHours = { price: a.price, note: a.note, slots }
  }
  // Whether customers can pay by card. Only the customer-facing answer says so (Vic's own settings do not).
  const online = raw.payOnline === undefined ? {} : { payOnline: raw.payOnline === true }
  return { services, slotMinutes, reminderHours, afterHours, ...online }
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
    afterHours: {
      price: settings.afterHours.price,
      note: settings.afterHours.note || '',
      slots: Object.fromEntries(DAY_KEYS.map((key, day) => [key, settings.afterHours.slots[day]])),
    },
  }
}

// How long an appointment is on `date` (a Date).
export const slotFor = (settings, date) => settings.slotMinutes[date.getDay()]

// ---- After Hours Cuts -------------------------------------------------------------------------------------------

export const AFTER_HOURS_ID = AFTER_HOURS.id

// How many late appointments `date` has (0 on a day the shop is closed).
export const afterCount = (settings, date) => (HOURS[date.getDay()] ? settings.afterHours.slots[date.getDay()] : 0)

// After Hours Cuts as a service, or null while no day has any late appointments (then there is nothing to offer).
export function afterService(settings) {
  const any = Object.keys(HOURS).some((day) => HOURS[day] && settings.afterHours.slots[day] > 0)
  if (!any) return null
  const { price, note } = settings.afterHours
  return { id: AFTER_HOURS.id, name: AFTER_HOURS.name, price, from: false, note, afterHours: true }
}

// The short names of the days that have late appointments, in week order starting Monday: ['Thu', 'Fri'].
export function afterDays(settings) {
  return [1, 2, 3, 4, 5, 6, 0].filter((day) => HOURS[day] && settings.afterHours.slots[day] > 0).map((day) => DAY_NAMES[day].slice(0, 3))
}

// Everything a customer can book: Vic's services, then After Hours Cuts.
export const bookableServices = (settings) => [...settings.services, afterService(settings)].filter(Boolean)

// The opening windows of every weekday for these settings: the regular windows, plus one more per day that starts at
// closing and holds that day's late appointments (marked 'after' as its third entry). Everything that draws or checks
// a day's times takes this instead of HOURS, so the late times behave exactly like the regular ones.
export function hoursFor(settings) {
  const out = {}
  for (let day = 0; day < 7; day++) {
    const windows = HOURS[day]
    const count = settings.afterHours.slots[day]
    if (!windows || !count) {
      out[day] = windows
      continue
    }
    const closing = windows[windows.length - 1][1]
    out[day] = [...windows, [closing, Math.min(closing + count * settings.slotMinutes[day], 24 * 60), 'after']]
  }
  return out
}

// Does this start fall after the shop closes on `date`?
export function isAfterStart(date, start) {
  const windows = HOURS[date.getDay()]
  return !!windows && start >= windows[windows.length - 1][1]
}

export const findService = (settings, id) => bookableServices(settings).find((s) => s.id === id) || null

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
    after: {
      price: String(settings.afterHours.price),
      note: settings.afterHours.note || '',
      slots: Object.fromEntries(Object.entries(settings.afterHours.slots).map(([day, count]) => [day, String(count)])),
    },
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
//   { general, services: { [key]: { name?, price?, note? } }, slots: { [day]: message }, after: { price?, note?, slots: { [day]: message } } }
export function checkDraft(draft) {
  const errors = { general: '', services: {}, slots: {}, after: { slots: {} } }
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

  // After Hours Cuts: a price, a description, and 0 to MAX_AFTER_SLOTS late appointments for each day.
  const afterPriceText = draft.after.price.trim()
  const afterPrice = /^\d{1,3}$/.test(afterPriceText) ? Number(afterPriceText) : NaN
  if (!(afterPrice >= 0 && afterPrice <= PRICE_MAX)) errors.after.price = `Whole dollars, 0 to ${PRICE_MAX}.`
  if (draft.after.note.length > NOTE_MAX) errors.after.note = `Up to ${NOTE_MAX} characters.`
  const afterSlots = {}
  for (let day = 0; day < 7; day++) {
    const text = String(draft.after.slots[day] ?? '').trim()
    const count = /^\d$/.test(text) ? Number(text) : NaN
    if (!isCount(count)) errors.after.slots[day] = `0 to ${MAX_AFTER_SLOTS}.`
    afterSlots[day] = count
  }

  const bad =
    errors.general ||
    Object.keys(errors.services).length ||
    Object.keys(errors.slots).length ||
    errors.after.price ||
    errors.after.note ||
    Object.keys(errors.after.slots).length
  return bad
    ? { ok: false, errors }
    : {
        ok: true,
        settings: {
          services,
          slotMinutes,
          reminderHours: cleanHours(draft.reminders),
          afterHours: { price: afterPrice, note: draft.after.note.trim(), slots: afterSlots },
        },
      }
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
cat > "$STAGE/24" <<'VICBLESS_EOF'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  AFTER_HOURS_ID,
  DAY_KEYS,
  DEFAULT_SHOP_SETTINGS,
  checkDraft,
  draftFrom,
  afterCount,
  afterDays,
  afterService,
  bookableServices,
  findService,
  hoursFor,
  isAfterStart,
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
    const s = { ...DEFAULT_SHOP_SETTINGS, services: [{ id: '', name: 'Shave', price: 20, from: false, note: '' }] }
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

describe('After Hours Cuts', () => {
  const THURSDAY = new Date(2026, 9, 15)
  const TUESDAY = new Date(2026, 9, 13)
  const WEDNESDAY = new Date(2026, 9, 14)
  const none = { ...DEFAULT_SHOP_SETTINGS, afterHours: { ...DEFAULT_SHOP_SETTINGS.afterHours, slots: { 0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0 } } }

  it('starts at $70 with two late appointments on Thursday and Friday', () => {
    expect(DEFAULT_SHOP_SETTINGS.afterHours.price).toBe(70)
    expect(DEFAULT_SHOP_SETTINGS.afterHours.slots).toEqual({ 0: 0, 1: 0, 2: 0, 3: 0, 4: 2, 5: 2, 6: 0 })
    expect(afterCount(DEFAULT_SHOP_SETTINGS, THURSDAY)).toBe(2)
    expect(afterCount(DEFAULT_SHOP_SETTINGS, TUESDAY)).toBe(0)
    expect(afterDays(DEFAULT_SHOP_SETTINGS)).toEqual(['Thu', 'Fri'])
  })

  it('is offered as a service after the others, and only while some day has late times', () => {
    const all = bookableServices(DEFAULT_SHOP_SETTINGS)
    expect(all.map((s) => s.id).slice(-2)).toEqual(['kids-design', AFTER_HOURS_ID])
    expect(all.at(-1)).toMatchObject({ name: 'After Hours Cuts', price: 70, from: false, afterHours: true })
    expect(afterService(none)).toBeNull()
    expect(bookableServices(none)).toHaveLength(5)
    expect(findService(DEFAULT_SHOP_SETTINGS, AFTER_HOURS_ID).price).toBe(70)
  })

  it('adds a window after closing that holds the late appointments', () => {
    const hours = hoursFor(DEFAULT_SHOP_SETTINGS)
    expect(hours[4]).toEqual([[660, 1140], [1140, 1210, 'after']]) // Thursday, 35 minute appointments
    expect(hours[1]).toEqual([[720, 1080]]) // Monday has none
    expect(hours[3]).toBeNull()
    expect(hoursFor(none)[4]).toEqual([[660, 1140]])
  })

  it('never runs past midnight', () => {
    const lots = { ...DEFAULT_SHOP_SETTINGS, slotMinutes: { ...DEFAULT_SHOP_SETTINGS.slotMinutes, 4: 120 }, afterHours: { ...DEFAULT_SHOP_SETTINGS.afterHours, slots: { ...DEFAULT_SHOP_SETTINGS.afterHours.slots, 4: 6 } } }
    expect(hoursFor(lots)[4].at(-1)).toEqual([1140, 1440, 'after'])
  })

  it('tells late starts from regular ones', () => {
    expect(isAfterStart(THURSDAY, 1140)).toBe(true)
    expect(isAfterStart(THURSDAY, 1080)).toBe(false)
    expect(isAfterStart(WEDNESDAY, 1140)).toBe(false) // closed
  })

  it('round-trips through the API shape', () => {
    const api = toApi(DEFAULT_SHOP_SETTINGS)
    expect(api.afterHours).toEqual({ price: 70, note: DEFAULT_SHOP_SETTINGS.afterHours.note, slots: { sun: 0, mon: 0, tue: 0, wed: 0, thu: 2, fri: 2, sat: 0 } })
    expect(fromApi(api).afterHours).toEqual(DEFAULT_SHOP_SETTINGS.afterHours)
  })

  it('keeps the starting offer when an older answer has none, and refuses a damaged one', () => {
    const { afterHours, ...old } = apiBody()
    expect(fromApi(old).afterHours).toEqual(DEFAULT_SHOP_SETTINGS.afterHours)
    expect(fromApi({ ...apiBody(), afterHours: { ...afterHours, slots: { ...afterHours.slots, thu: 7 } } })).toBeNull()
    expect(fromApi({ ...apiBody(), afterHours: { ...afterHours, price: '70' } })).toBeNull()
    expect(fromApi({ ...apiBody(), afterHours: null })).toBeNull()
  })

  it('checks what Vic types for it', () => {
    const draft = draftFrom(DEFAULT_SHOP_SETTINGS)
    const ok = checkDraft(draft)
    expect(ok.ok).toBe(true)
    expect(ok.settings.afterHours).toEqual(DEFAULT_SHOP_SETTINGS.afterHours)
    const bad = checkDraft({ ...draft, after: { price: 'abc', note: 'x'.repeat(121), slots: { ...draft.after.slots, 4: '9', 5: '' } } })
    expect(bad.ok).toBe(false)
    expect(bad.errors.after.price).toBeTruthy()
    expect(bad.errors.after.note).toBeTruthy()
    expect(Object.keys(bad.errors.after.slots).sort()).toEqual(['4', '5'])
    expect(isChanged({ ...draft, after: { ...draft.after, price: '80' } }, DEFAULT_SHOP_SETTINGS)).toBe(true)
  })
})
VICBLESS_EOF
cat > "$STAGE/25" <<'VICBLESS_EOF'
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
                {service.name} ({slotFor(shop, fromKey(dateKey))} min), {priceLabel(service)}
                {isAfter && <span className="after-badge">After hours</span>}
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
cat > "$STAGE/26" <<'VICBLESS_EOF'
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
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"456cc58eee9e290542ada8e5414431046c234a0f6921d1251740c5f11270708d\", \"new\": 0}, {\"path\": \"backend/app/database/schedule.py\", \"base\": \"35fca6243d8421eae674e4ed9472b75d4f19d8d1be5691b86e1905ced903433b\", \"new\": 1}, {\"path\": \"backend/app/database/settings.py\", \"base\": \"96d01f1a1f60a5bc6df4cac98eeea753db84b06b6fdc133f58f050345c09e6f8\", \"new\": 2}, {\"path\": \"backend/app/domain/shop.py\", \"base\": \"45a6889131ba3e2c45802eb3c948018e4c593a5df98ae419e2f362f34d491533\", \"new\": 3}, {\"path\": \"backend/app/payments/stripe.py\", \"base\": \"03fa27e573efd027983a16cd908410208d417247309d2888af0ab295a00ba448\", \"new\": 4}, {\"path\": \"backend/app/schemas/requests.py\", \"base\": \"049f3e968fbef4f9517a2e73627b9ebc765f947f2b6c9feb700ede3f171e9205\", \"new\": 5}, {\"path\": \"backend/app/services/blocks.py\", \"base\": \"7370c874bd035d6d716f64263ca648aca85668c3e532e9ebb5259cb2e67e1f2a\", \"new\": 6}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"0bc248e7dfe921671000ff3c8960cc7b34a436f58d0f34fcdf6675b2a2f9063d\", \"new\": 7}, {\"path\": \"backend/app/services/payments.py\", \"base\": \"a0ad4cdd734a3bff4f200699da93b3c339c6120298ec4123422fb67b63ae5ba9\", \"new\": 8}, {\"path\": \"backend/app/services/settings.py\", \"base\": \"cd6bd42fc93f3d015a40af4055e07a3c30bb7eba2db141282de7730cbfcf44b1\", \"new\": 9}, {\"path\": \"backend/tests/test_after_hours.py\", \"base\": null, \"new\": 10}, {\"path\": \"backend/tests/test_contract.py\", \"base\": \"ee7c229e78c2bf107131966811874ec771e492e5cc24a46c3e3d6c2e5f31bdf1\", \"new\": 11}, {\"path\": \"frontend/src/admin/BlockOff.jsx\", \"base\": \"f1586122262990f18930e14c93115e258f61ca157cc4a9c5d0ea286a9ea24977\", \"new\": 12}, {\"path\": \"frontend/src/admin/MoveBooking.jsx\", \"base\": \"69ce7bc2f2536bdfd313c3498b854ce818f9944387ddce9ecfd6c72c32c89df1\", \"new\": 13}, {\"path\": \"frontend/src/admin/Schedule.jsx\", \"base\": \"e984b59517d909cef274cd8b085f637a41c41ea21a1239f3f302d8d562719ee1\", \"new\": 14}, {\"path\": \"frontend/src/admin/SettingsPanel.jsx\", \"base\": \"69bfea271ef1a74c31db9233205d3b27ce4cf4b0d9072aa34fd09f29ac963463\", \"new\": 15}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"75238ca39649a808e9ed54b65aaad5f5d9093b0a802f141993b062be2e987ad7\", \"new\": 16}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"58e4e04c98063c2926043efd69c2781803bae416492d445d8e125d623c8f7dfe\", \"new\": 17}, {\"path\": \"frontend/src/admin/schedule.js\", \"base\": \"ccbcac24dfb5f04b548771750ccc616aba8977090fe4c4e14e9b1e5426415f21\", \"new\": 18}, {\"path\": \"frontend/src/admin/schedule.test.js\", \"base\": \"6ea2861259ab84f65839e465a5968e651e22996edb0abd5f8cd7965537de612e\", \"new\": 19}, {\"path\": \"frontend/src/config.js\", \"base\": \"52ae7f3bf0b798334150c0e3c1dd7a267c53056f7906dded801b59374169a76c\", \"new\": 20}, {\"path\": \"frontend/src/lib/mockApi.js\", \"base\": \"d0db724706bf8280422c2d0ad49c91c2d7704c2933bc5e51fd72073b561b07d9\", \"new\": 21}, {\"path\": \"frontend/src/lib/mockStore.js\", \"base\": \"59de088a47a7c9c07b050aac9f0122f1564a8c24331d9a219a5b79a797ff28f9\", \"new\": 22}, {\"path\": \"frontend/src/lib/shopSettings.js\", \"base\": \"1f000c974ab47900623bb4a49c4a685b88f54611384870c4c1821e1390395d22\", \"new\": 23}, {\"path\": \"frontend/src/lib/shopSettings.test.js\", \"base\": \"4e1ddf8566030324a507c3a614bfd48cdf9e24c3a15dab025c5d63553e3e548b\", \"new\": 24}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"a9cd9fdd23e1cfa7699aa7127fb1249a33505d46c9f8481f0809af3310ac280c\", \"new\": 25}, {\"path\": \"frontend/src/styles.css\", \"base\": \"2253e3658fbab3097db5c92119cbd048dbcfb1053cbdb6679ccf00c57f0f3f03\", \"new\": 26}]")

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
echo "Next: run the backend tests, deploy, then open Menu > Settings > Shop settings to see After Hours Cuts."
