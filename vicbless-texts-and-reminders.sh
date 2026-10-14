#!/usr/bin/env bash
# Vicbless: text messages, reminders, and Move Up / Move Down
# Run from the REPO ROOT:  bash vicbless-texts-and-reminders.sh
#
# Adds Textbelt texts (to Vic about new bookings; to customers who tick the box), appointment reminders by
# email and text (24 and 2 hours before to start; Vic can change them in Shop settings), the consent tick box
# on the booking form, and renames the service buttons to Move Up / Move Down.
# Needs the settings installer (vicbless-editable-settings-and-45-minute-mon-tue.sh) applied first.
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
`email-from` (String). `app-version` is written by the deploy workflow.
Make the first three with `python backend/scripts/hash_password.py --env dev`.

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

# How long a secret stays cached in memory. Reading from AWS on every request would be slow and cost money;
# five minutes means a changed secret takes effect within five minutes without a redeploy.
PARAM_TTL_SECONDS = 300


@dataclass(frozen=True)
class Settings:
    """Plain (non-secret) settings, set as environment variables by the SAM template."""

    environment: str
    table_name: str
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
                raise
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
) -> dict:  # fmt: skip
    """The raw DynamoDB item for a booking. One place builds it, so a new booking and a moved one can't differ."""
    return {
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
    }


def create_booking(
    *, day: date, start: int, service_id: str, service_name: str, minutes: int, name: str, phone: str, email: str,
    notes: str, code: str, sms_consent: bool = False,
) -> Booking:  # fmt: skip
    booking_id = new_id(day, start)
    claims = shop.occupied_starts(start, minutes)  # the 5 minute units this booking will hold
    created = datetime.now(timezone.utc).isoformat(timespec="seconds")
    item = _booking_item(
        booking_id=booking_id, day=day, start=start, service_id=service_id, service_name=service_name,
        minutes=minutes, name=name, phone=phone, email=email, notes=notes, code=code, created=created,
        updated=created, sms_consent=sms_consent,
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
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Reminder bookkeeping in the database: which bookings are coming up, and marking a reminder as sent."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..domain.models import Booking
from . import keys, schedule, table
from .bookings import booking_from
from .keys import PK


def upcoming(first: date, last: date) -> list[Booking]:
    """Every booking from `first` through `last` (both days included), earliest first."""
    items = schedule.query_range(f"{first.isoformat()}#", f"{last.isoformat()}#~")
    return [booking_from(i) for i in items if i.get("kind") == "booking"]


def claim(booking: Booking, tag: str) -> bool:
    """Marks the reminder `tag` (like "24h") as sent for this booking. True if THIS call marked it, False if it already
    was (or the booking is gone, or was moved a moment ago), so two overlapping sweeps can never both send it."""
    try:
        table.table().update_item(
            Key={"pk": PK, "sk": keys.booking_sk(booking.day, booking.start, booking.id)},
            UpdateExpression="SET remindersSent = list_append(if_not_exists(remindersSent, :none), :tag)",
            ConditionExpression="attribute_exists(pk) AND (attribute_not_exists(remindersSent) OR NOT contains(remindersSent, :t))",
            ExpressionAttributeValues={":none": [], ":tag": [tag], ":t": tag},
        )
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise
    return True
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
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
    return shop.ShopSettings(slot_minutes=slots, services=services, reminder_hours=reminders)


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
            "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
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
        }

    def public_view(self) -> dict:
        """What the customer gets back. The internal id is left out."""
        return {
            "code": self.code,
            "dateKey": self.day.isoformat(),
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
            "staffId": shop.STAFF_ID,
        }


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
cat > "$STAGE/6" <<'VICBLESS_EOF'
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


@dataclass(frozen=True)
class ShopSettings:
    """Everything Vic can change from his dashboard."""

    slot_minutes: tuple[int, int, int, int, int, int, int]  # appointment length, Monday ... Sunday
    services: tuple[Service, ...]  # in the order they are shown
    # How many hours before an appointment a reminder goes out (each one is a separate reminder). Empty = no reminders.
    reminder_hours: tuple[int, ...] = (24, 2)

    def slot_for(self, day: date) -> int:
        """How long an appointment is on this date."""
        return self.slot_minutes[day.weekday()]

    def service(self, service_id: str) -> Service | None:
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


def grid_starts(day: date, slot: int) -> list[int]:
    """Every appointment start of the day, across all opening windows (Saturday's break is not in it).

    Each window runs its own grid from its opening time, and an appointment must end by closing.
    """
    out: list[int] = []
    for open_, close in windows_for(day):
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


def fits(day: date, start: int, slot: int) -> bool:
    """True if an appointment starting at `start` is on that day's grid and finishes inside one opening window."""
    for open_, close in windows_for(day):
        if open_ <= start and start + slot <= close and (start - open_) % slot == 0:
            return True
    return False


def check_bookable(day: date, start: int, slot: int, now: datetime) -> None:
    """Raise InvalidSlot (can never work) or SlotUnavailable (not right now). Returns None if OK."""
    # 1. Structure: is this a real slot of a real opening day? If not, no amount of waiting will fix it.
    if not fits(day, start, slot):
        raise InvalidSlot()
    # 2. Timing: a real time can still be too early, too late, or too far away.
    first, last = booking_window(now)
    if day < first or day > last:
        raise SlotUnavailable()
    # Today only: Vic needs notice, so a time must start more than 30 minutes from now.
    if day == first and start <= minutes_of_day(now) + LEAD_MINUTES:
        raise SlotUnavailable()


def check_movable(day: date, start: int, slot: int, now: datetime) -> None:
    """Rules for Vic moving a booking. Looser than for customers: no 14 day limit and no 30 minute notice.

    It still has to be a real slot of an open day, it can't be in the past, and it can't be more than a year out.
    Raises InvalidSlot. (Whether the time is free is decided by the database, not here.)
    """
    if not fits(day, start, slot):
        raise InvalidSlot()
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can move a booking to any open time from now up to a year ahead.")
    if day == first and start <= minutes_of_day(now):
        raise InvalidSlot("That time has already passed today. Pick a later one.")


def block_units(day: date, start: int, end: int) -> list[int]:
    """The 5 minute units a block-off covers: everything from `start` up to `end` that lies inside opening hours.

    The range is widened to whole units. Saturday's lunch gap is never included, so a whole-day block does not claim it.
    """
    first = start - start % UNIT_MINUTES
    last = end + (-end) % UNIT_MINUTES
    out: list[int] = []
    for open_, close in windows_for(day):
        out.extend(u for u in range(max(first, open_), min(last, close), UNIT_MINUTES))
    return out


def busy_slots(day: date, slot: int, taken_units: set[int]) -> list[int]:
    """The appointment starts of the day's grid that overlap anything taken (a booking or blocked time)."""
    return [s for s in grid_starts(day, slot) if any(u in taken_units for u in range(s, s + slot, UNIT_MINUTES))]


def check_blockable(day: date, now: datetime) -> None:
    """Vic can only block an open day, from today up to a year ahead. Raises InvalidSlot otherwise."""
    if not is_open(day):
        raise InvalidSlot("The shop is already closed that day, so there is nothing to block.")
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can block time from today up to a year ahead.")
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
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
    footer = f"Pay at the shop. Need to change something? Reply to this email or write to {CONTACT_EMAIL} and quote your code."
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
        ("Name", escape(booking.name)),
        ("Phone", escape(booking.phone)),
        ("Email", email_cell),
        ("Notes", escape(booking.notes).replace("\n", "<br>") or "none"),
        ("Code", escape(booking.code)),
    ]
    text = (
        f"New booking\n\nWhen: {when}\nService: {_service_name(booking)}\nName: {booking.name}\n"
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
    footer = f"Pay at the shop. Need to change it? Write to {CONTACT_EMAIL} and quote your code."
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
cat > "$STAGE/8" <<'VICBLESS_EOF'
"""AWS Lambda entry point. Two kinds of events arrive here:

  - web requests from API Gateway (HTTP API) -> Mangum -> FastAPI
  - a scheduled event from EventBridge every 15 minutes -> the reminder sweep (services/reminders.py)
"""

from mangum import Mangum

from .main import app
from .services import reminders

_web = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    # A scheduled EventBridge event says source "aws.events". Web requests never do.
    if isinstance(event, dict) and event.get("source") == "aws.events":
        return reminders.send_due()
    return _web(event, context)
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
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
cat > "$STAGE/10" <<'VICBLESS_EOF'
"""Booking rules in action: what happens when a customer asks for a time.

This layer decides WHAT should happen and in which order. It calls the shop rules (domain/shop.py)
to ask "is this a valid time?" and the database layer to actually store it. It knows nothing about
web requests or DynamoDB details, which is what keeps it easy to read and easy to test.
"""

from __future__ import annotations

from datetime import date, datetime

from ..core.brand import CONTACT_EMAIL
from ..core.errors import NotFound, SlotTaken, TooManyBookings, ValidationFailed
from ..database import bookings as bookings_db
from ..database import schedule
from ..domain import shop
from ..domain.models import Booking, new_code
from ..schemas.requests import MSG_SERVICE, BookingIn, MoveIn, parse_date_key
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

    if bookings_db.upcoming_for_phone(data.phone, shop.today(now)) >= MAX_UPCOMING_PER_PHONE:
        # The cap is reached, but a retry of an already-made booking must still be answered with it.
        replay = earlier_attempt()
        if replay:
            return replay, False
        raise TooManyBookings(
            f"This phone number already has {MAX_UPCOMING_PER_PHONE} upcoming bookings, which is the most we allow. "
            f"Please email Vic at {CONTACT_EMAIL} if you need to change one."
        )
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
        )
    except SlotTaken:
        # Someone holds the time. If that someone is this very request (a retry), hand it back.
        replay = earlier_attempt()
        if replay:
            return replay, False
        raise
    return booking, True


def cancel_booking(booking_id: str) -> Booking:
    """Vic cancels a booking. Frees every block it held, and returns it so the customer can be told."""
    return bookings_db.cancel_booking(booking_id)


def move_booking(booking_id: str, data: MoveIn, now: datetime) -> tuple[Booking, Booking]:
    """Vic moves a booking to another time. Returns (before, after) so the customer can be told both.

    The customer keeps the same code. The booking gets a new id, because the id contains the day and time.
    """
    before = bookings_db.get_booking(booking_id)
    if not before:
        raise NotFound("That booking was not found. It may already be cancelled.")
    day = parse_date_key(data.dateKey)
    if (day, data.start) == (before.day, before.start):
        raise ValidationFailed("That booking is already at that time. Pick a different one.")
    minutes = settings_service.current().slot_for(day)  # the booking takes the new day's appointment length
    shop.check_movable(day, data.start, minutes, now)
    after = bookings_db.move_booking(before, day=day, start=data.start, minutes=minutes)  # raises SlotTaken if not free
    return before, after
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
"""Sends the emails and texts around a booking. Best effort: a failed one is logged and never fails the booking.

Vic is texted at his own number (the `owner-phone` setting) about new bookings. A customer is texted only if they ticked
"text me" when booking, and emailed only if they left an email address."""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates
from ..texting import SmsMessage, us_number
from ..texting import get_sender as get_sms_sender
from ..texting import templates as sms_templates


def _send_all(builders) -> None:
    """Builds and sends each email on its own. One failing never stops the others, and none can fail the booking."""
    try:
        owner = config.params.get("owner-email") or ""
        sender = get_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("email_setup_failed", reason=type(exc).__name__)
        return
    for build in builders:
        try:
            message: EmailMessage | None = build(owner)
            if message is not None and message.to:
                sender.send(message)
        except Exception as exc:
            log("email_error", reason=type(exc).__name__)


def booking_created(booking: Booking) -> None:
    """Vic always hears about a new booking; the customer gets a confirmation only if they left an email."""
    _send_all(
        [
            lambda owner: templates.owner_notification(booking, owner) if owner else None,
            lambda owner: templates.customer_confirmation(booking, owner) if booking.email else None,
        ]
    )
    texts_for_created(booking)


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (by email and/or text, whichever they chose)."""
    _send_all([lambda owner: templates.customer_cancellation(booking, owner) if booking.email else None])
    texts_for_cancelled(booking)


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (by email and/or text, whichever they chose)."""
    _send_all([lambda owner: templates.customer_rescheduled(before, after, owner) if after.email else None])
    texts_for_moved(before, after)


def _send_texts(builders) -> None:
    """Builds and sends each text on its own. A builder gets Vic's number and returns (number, text) or None to skip."""
    try:
        owner = us_number(config.params.get("owner-phone"))
        sender = get_sms_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("sms_setup_failed", reason=type(exc).__name__)
        return
    for build in builders:
        try:
            built = build(owner)
            if built is not None:
                to, body = built
                if to:
                    sender.send(SmsMessage(to=to, body=body))
        except Exception as exc:
            log("sms_error", reason=type(exc).__name__)


def _to_customer(booking: Booking, body: str):
    """(number, text) for a customer who agreed to texts and gave a US number, otherwise None."""
    return (us_number(booking.phone), body) if booking.sms_consent else None


def texts_for_created(booking: Booking) -> None:
    _send_texts(
        [
            lambda owner: (owner, sms_templates.owner_new_booking(booking)) if owner else None,
            lambda owner: _to_customer(booking, sms_templates.customer_confirmation(booking)),
        ]
    )


def texts_for_cancelled(booking: Booking) -> None:
    _send_texts([lambda owner: _to_customer(booking, sms_templates.customer_cancellation(booking))])


def texts_for_moved(before: Booking, after: Booking) -> None:
    _send_texts([lambda owner: _to_customer(after, sms_templates.customer_rescheduled(before, after))])


def booking_reminder(booking: Booking) -> None:
    """The reminder before an appointment: an email if they left one, a text if they agreed to texts."""
    _send_all([lambda owner: templates.customer_reminder(booking, owner) if booking.email else None])
    _send_texts([lambda owner: _to_customer(booking, sms_templates.customer_reminder(booking))])
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
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
    notifications.booking_reminder(booking)
    return True


def send_due(now: datetime | None = None) -> dict[str, int]:
    """One sweep. Returns how many reminders were sent and how many bookings could not be handled."""
    moment = (now or shop.now_local()).astimezone(timezone.utc)
    hours_list = settings_service.current().reminder_hours
    result = {"sent": 0, "errors": 0}
    if not hours_list:
        return result
    first = shop.today(moment)
    last: date = first + timedelta(days=max(hours_list) // 24 + 2)
    for booking in reminders_db.upcoming(first, last):
        try:
            if _handle(booking, hours_list, moment):
                result["sent"] += 1
        except Exception as exc:  # one broken booking must not stop everyone else's reminder
            result["errors"] += 1
            log("reminder_error", reason=type(exc).__name__)
    log("reminders_swept", **result)
    return result
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
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
    )
    settings_db.save(updated)
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
    }
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
"""Sending text messages (SMS). The rest of the app only knows about SmsSender and SmsMessage.

Today the provider is Textbelt (texting/textbelt.py): simple, no sign-up verification, pay per text. It is a bridge,
like the email one. When Vic's account at AWS (End User Messaging / SNS) is approved: add texting/aws.py with the same
`send` method, add it to get_sender() below, set SMS_PROVIDER=aws, then delete textbelt.py and its line here.
Nothing else changes.

Only US mobile numbers are texted (10 digits). Anything else is skipped and logged, never an error.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Protocol

from ..core import config
from ..core.logs import log


@dataclass(frozen=True)
class SmsMessage:
    """One text, independent of which provider sends it. `to` is a 10 digit US number."""

    to: str
    body: str


class SmsSender(Protocol):
    """Anything with a send() method counts as a provider (Textbelt now, AWS later)."""

    def send(self, message: SmsMessage) -> None: ...


class NullSender:
    """Used when no provider is set up. Logs that a text would have gone out, and sends nothing."""

    def send(self, message: SmsMessage) -> None:
        log("sms_skipped", reason="no_provider")


def us_number(raw: str | None) -> str | None:
    """'(555) 010-0777', '+1 555 010 0777' or '5550100777' -> '5550100777'. None when it is not a 10 digit US number."""
    digits = re.sub(r"\D", "", raw or "")
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    return digits if len(digits) == 10 and digits[0] not in "01" else None


def get_sender() -> SmsSender:
    """Picks the provider named by the SMS_PROVIDER setting. If its key isn't set up yet, texts are skipped (and
    logged) rather than breaking bookings. That is what lets the app run before Textbelt is configured."""
    provider = config.get_settings().sms_provider
    if provider == "textbelt":
        from .textbelt import TextbeltSender

        key = config.params.get("textbelt-key")
        if key:
            return TextbeltSender(api_key=key)
        log("sms_not_configured", provider="textbelt")
        return NullSender()
    return NullSender()
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
"""The texts. Short and plain (no emoji, no links) so they send as few segments as possible and are never filtered.

Every text to a customer says who it is from and ends with the opt-out line carriers expect. Texts to Vic himself
do not need it. Everything a customer typed is flattened to one line first.
"""

from __future__ import annotations

from ..core.brand import ADDRESS_LINES, BRAND_NAME, CONTACT_EMAIL
from ..domain import shop
from ..domain.models import Booking

OPT_OUT = "Reply STOP to opt out."


def _line(text: str, limit: int) -> str:
    """One line, no control characters, cut to `limit` characters."""
    return " ".join("".join(c if c.isprintable() else " " for c in text).split())[:limit]


def _when(booking: Booking) -> str:
    """'Tue, Oct 13 at 12:45 pm'."""
    d = booking.day
    return f"{d:%a}, {d:%b} {d.day} at {shop.label(booking.start)}"


def _service(booking: Booking) -> str:
    if booking.service_name:
        return booking.service_name
    service = shop.DEFAULT_SETTINGS.service(booking.service_id)
    return service.name if service else booking.service_id


def owner_new_booking(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: New booking. {_line(booking.name, 40)}, {_line(_service(booking), 50)}, {_when(booking)}. "
        f"Phone {booking.phone}. Code {booking.code}."
    )


def customer_confirmation(booking: Booking) -> str:
    first = _line(booking.name.split()[0] if booking.name.split() else "", 20)
    return (
        f"{BRAND_NAME}: You're booked, {first}. {_when(booking)} with Vic. Code {booking.code}. Pay at the shop. "
        f"To change it, email {CONTACT_EMAIL}. {OPT_OUT}"
    )


def customer_cancellation(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: Your appointment on {_when(booking)} was cancelled. You can book a new time anytime on our site. "
        f"{OPT_OUT}"
    )


def customer_rescheduled(before: Booking, after: Booking) -> str:
    return (
        f"{BRAND_NAME}: Your appointment moved to {_when(after)} (it was {_when(before)}). Code {after.code}. "
        f"Questions? Email {CONTACT_EMAIL}. {OPT_OUT}"
    )


def customer_reminder(booking: Booking) -> str:
    return (
        f"{BRAND_NAME}: Reminder, you're booked {_when(booking)} at {ADDRESS_LINES[0]}. Code {booking.code}. "
        f"Need to change it? Email {CONTACT_EMAIL}. {OPT_OUT}"
    )
VICBLESS_EOF
cat > "$STAGE/16" <<'VICBLESS_EOF'
"""Textbelt bridge. Delete this file when the AWS SMS account is approved (see texting/__init__.py).

Uses only the standard library, so it adds nothing to the Lambda package.
API: POST https://textbelt.com/text  (docs.textbelt.com), form fields: phone, message, key, sender.
Answer: JSON { success, quotaRemaining, textId } or { success: false, error }.
Textbelt answers STOP replies by itself. The `sender` field names the business, which their rules ask for.
The key is the Textbelt key bought for Vic, kept in Parameter Store (/vicbless/<env>/textbelt-key). The special key
"textbelt" is Textbelt's free test key (about one text a day for everyone), good only to check that it is wired up.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from ..core.brand import BRAND_NAME
from ..core.logs import log
from . import SmsMessage

API_URL = "https://textbelt.com/text"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 5


class SmsSendError(Exception):
    """Raised when Textbelt could not deliver. The caller (services/notifications.py) logs it and carries on."""

    pass


class TextbeltSender:
    def __init__(self, api_key: str):
        self.api_key = api_key

    def _request(self, message: SmsMessage) -> urllib.request.Request:
        """The full HTTP request. The key goes only in the form body, and neither it nor the number is ever logged."""
        form = urllib.parse.urlencode(
            {"phone": message.to, "message": message.body, "key": self.api_key, "sender": BRAND_NAME.title()}
        )
        return urllib.request.Request(
            API_URL,
            data=form.encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT},
        )

    def send(self, message: SmsMessage) -> None:
        """Send one text. Raises SmsSendError when Textbelt refuses it or cannot be reached."""
        try:
            with urllib.request.urlopen(self._request(message), timeout=TIMEOUT_SECONDS) as response:
                answer = json.loads(response.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            log("sms_failed", provider="textbelt", status=err.code)
            raise SmsSendError(f"Textbelt answered {err.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            log("sms_failed", provider="textbelt", reason=type(err).__name__)
            raise SmsSendError("Could not reach Textbelt") from None
        if not isinstance(answer, dict) or not answer.get("success"):
            # Textbelt's own reason ("Out of quota", "Invalid phone number") is safe to log: it has no personal details.
            reason = str(answer.get("error", "unknown"))[:80] if isinstance(answer, dict) else "unknown"
            log("sms_failed", provider="textbelt", reason=reason)
            raise SmsSendError("Textbelt refused the text")
        remaining = answer.get("quotaRemaining")
        if isinstance(remaining, (int, float)) and remaining <= 10:
            log("sms_quota_low", provider="textbelt", remaining=remaining)  # a nudge in the logs to buy more credit
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock, classic_grid   run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails
    texts                catches outgoing texts (and sets Vic's number)

Shared test data and shortcuts live in tests/helpers/ (builders, api shortcuts, constants).
"""

from tests.fixtures.api import admin_setup, auth, client  # noqa: F401
from tests.fixtures.aws import atomic_transactions, aws  # noqa: F401
from tests.fixtures.clock import fixed_clock  # noqa: F401
from tests.fixtures.email import sent  # noqa: F401
from tests.fixtures.settings import classic_grid  # noqa: F401
from tests.fixtures.sms import texts  # noqa: F401
VICBLESS_EOF
cat > "$STAGE/18" <<'VICBLESS_EOF'
"""Catching texts instead of sending them."""

import pytest

from app.services import notifications
from tests.helpers.aws import put_param

OWNER_PHONE = "(555) 010-0777"


@pytest.fixture
def texts(monkeypatch):
    """A list that fills with every text the app tries to send. Also sets Vic's number, so owner texts go somewhere."""
    box = []

    class Recorder:
        def send(self, message):
            box.append(message)

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Recorder())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    return box
VICBLESS_EOF
cat > "$STAGE/19" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/20" <<'VICBLESS_EOF'
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
    assert handler.lambda_handler(event, None) == {"sent": 3, "errors": 0}


def test_a_web_request_still_goes_to_the_api():
    from app.handler import lambda_handler
    from tests.test_handler import http_api_event

    assert lambda_handler(http_api_event("GET", "/api/health"), None)["statusCode"] == 200


def test_a_real_sweep_through_the_handler_with_nothing_to_do():
    from app.handler import lambda_handler

    assert lambda_handler({"source": "aws.events"}, None) == {"sent": 0, "errors": 0}
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
    "services": {"core", "domain", "schemas", "database", "emailing", "texting"},
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
cat > "$STAGE/23" <<'VICBLESS_EOF'
"""Texts: the Textbelt bridge, who gets a text and when, and the wording."""

import io
import json
import urllib.error
import urllib.parse
import urllib.request

import pytest

from app.core import config
from app.texting import NullSender, SmsMessage, get_sender, templates, us_number
from app.texting.textbelt import SmsSendError, TextbeltSender
from tests.fixtures.sms import OWNER_PHONE
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_model

# --- numbers ----------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("(555) 010-0777", "5550100777"),
        ("+1 555 010 0777", "5550100777"),
        ("15550100777", "5550100777"),
        ("5550100777", "5550100777"),
        ("010-0777", None),  # too short
        ("+44 7700 900123", None),  # not a US number
        ("0125550100", None),  # US area codes never start with 0 or 1
        ("", None),
        (None, None),
    ],
)
def test_us_number(raw, expected):
    assert us_number(raw) == expected


# --- the Textbelt bridge --------------------------------------------------------------------------------------


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def fake_urlopen(monkeypatch, answer=None, raises=None):
    """Replaces the network. Returns the list of requests that were made."""
    made = []

    def urlopen(request, timeout=None):
        made.append((request, timeout))
        if raises:
            raise raises
        return FakeResponse(json.dumps(answer).encode())

    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    return made


def test_a_text_is_posted_to_textbelt_with_the_key_in_the_form(monkeypatch):
    made = fake_urlopen(monkeypatch, {"success": True, "quotaRemaining": 99, "textId": "1"})
    TextbeltSender(api_key="secret-key").send(SmsMessage(to="5550100777", body="Hello there"))
    request, timeout = made[0]
    assert request.full_url == "https://textbelt.com/text" and request.get_method() == "POST" and timeout == 5
    form = urllib.parse.parse_qs(request.data.decode())
    assert form["phone"] == ["5550100777"] and form["message"] == ["Hello there"] and form["key"] == ["secret-key"]
    assert form["sender"] == ["Vicbless Barbershop"]
    assert "secret-key" not in request.full_url  # never in the address


@pytest.mark.parametrize(
    "kwargs",
    [
        {"answer": {"success": False, "error": "Out of quota"}},
        {"answer": ["not", "a", "dict"]},
        {"raises": urllib.error.URLError("down")},
        {"raises": TimeoutError()},
        {"raises": urllib.error.HTTPError("https://textbelt.com/text", 500, "boom", {}, None)},
    ],
)
def test_a_refused_or_unreachable_textbelt_raises_sms_send_error(monkeypatch, kwargs):
    fake_urlopen(monkeypatch, **kwargs)
    with pytest.raises(SmsSendError):
        TextbeltSender(api_key="k").send(SmsMessage(to="5550100777", body="x"))


def watch_logs(monkeypatch):
    """Replaces the bridge's logger with a list of (event, fields)."""
    from app.texting import textbelt

    seen = []
    monkeypatch.setattr(textbelt, "log", lambda event, **fields: seen.append((event, fields)))
    return seen


def test_logs_never_contain_the_key_or_the_number(monkeypatch):
    seen = watch_logs(monkeypatch)
    fake_urlopen(monkeypatch, {"success": False, "error": "Out of quota"})
    with pytest.raises(SmsSendError):
        TextbeltSender(api_key="super-secret").send(SmsMessage(to="5550100777", body="hi"))
    assert seen == [("sms_failed", {"provider": "textbelt", "reason": "Out of quota"})]
    assert "super-secret" not in str(seen) and "5550100777" not in str(seen)


def test_a_low_quota_is_noted_in_the_logs(monkeypatch):
    seen = watch_logs(monkeypatch)
    fake_urlopen(monkeypatch, {"success": True, "quotaRemaining": 4})
    TextbeltSender(api_key="k").send(SmsMessage(to="5550100777", body="x"))
    assert seen[0][0] == "sms_quota_low"


# --- picking the provider ---------------------------------------------------------------------------------


def test_without_a_key_texts_are_skipped():
    assert isinstance(get_sender(), NullSender)


def test_with_a_key_textbelt_is_used():
    put_param("textbelt-key", "abc123")
    assert isinstance(get_sender(), TextbeltSender)


def test_an_unknown_provider_means_no_texts(monkeypatch):
    monkeypatch.setenv("SMS_PROVIDER", "carrier-pigeon")
    config.params.reset()
    assert isinstance(get_sender(), NullSender)


# --- the wording ----------------------------------------------------------------------------------------------


def test_customer_texts_name_the_shop_and_carry_the_opt_out():
    b = booking_model()
    for body in (
        templates.customer_confirmation(b),
        templates.customer_cancellation(b),
        templates.customer_rescheduled(b, booking_model(start=765)),
        templates.customer_reminder(b),
    ):
        assert body.startswith("VICBLESS BARBERSHOP:") and body.endswith("Reply STOP to opt out.")
        assert "\n" not in body and len(body) < 300


def test_the_texts_have_the_details_a_customer_needs():
    b = booking_model()
    assert "Tue, Oct 13 at 12:00 pm" in templates.customer_confirmation(b) and "VB-ABC234" in templates.customer_confirmation(b)
    assert "Marcus" in templates.customer_confirmation(b)
    moved = templates.customer_rescheduled(b, booking_model(start=765))
    assert "12:45 pm" in moved and "was Tue, Oct 13 at 12:00 pm" in moved.replace("it was", "was")
    assert "656 S Main St" in templates.customer_reminder(b)


def test_the_owner_text_has_no_opt_out_and_shows_the_phone():
    body = templates.owner_new_booking(booking_model())
    assert "STOP" not in body and "5550101234" in body and "Marcus Jones" in body and "Men's haircut" in body


def test_what_a_customer_typed_cannot_break_a_text_into_lines():
    b = booking_model(name="Mal\nlory\r\n" + "x" * 80, service_name="Cut\x00\x07 and" + "y" * 100)
    body = templates.owner_new_booking(b)
    assert "\n" not in body and "\x00" not in body and "x" * 41 not in body and "y" * 51 not in body


# --- who gets a text, and when ---------------------------------------------------------------------------------


def numbers(texts):
    return sorted(m.to for m in texts)


def test_vic_is_texted_about_every_booking_and_a_customer_only_if_they_agreed(client, texts):
    assert book(client).status_code == 201  # no consent given
    assert numbers(texts) == ["5550100777"]
    assert "New booking" in texts[0].body
    texts.clear()
    assert book(client, start=12 * 60 + 35, phone="(555) 010-9999", smsConsent=True).status_code == 201
    assert numbers(texts) == ["5550109999", "5550100777"] or numbers(texts) == sorted(["5550109999", "5550100777"])
    assert any("You're booked" in m.body and m.to == "5550109999" for m in texts)


def test_without_vics_number_only_the_customer_is_texted(client, texts):
    put_param("owner-phone", " ", secure=False)
    book(client, smsConsent=True)
    assert numbers(texts) == ["5550101234"]


def test_a_number_that_is_not_a_us_mobile_is_skipped_quietly(client, texts):
    r = book(client, phone="+44 7700 900123", smsConsent=True)
    assert r.status_code == 201
    assert numbers(texts) == ["5550100777"]  # only Vic


def test_sms_consent_must_be_true_or_false(client, texts):
    assert book(client, smsConsent="yes").status_code == 422
    assert texts == []


def test_a_failing_text_provider_never_fails_the_booking(client, monkeypatch):
    from app.services import notifications

    class Broken:
        def send(self, message):
            raise SmsSendError("down")

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Broken())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    assert book(client, smsConsent=True).status_code == 201


def test_cancel_and_move_text_only_customers_who_agreed(client, auth, texts):
    book(client, smsConsent=True)
    book(client, start=12 * 60 + 35, phone="(555) 010-7777", name="No Texts")
    texts.clear()
    first, second = schedule_of(client, auth)["items"]
    assert client.patch(f"/api/admin/bookings/{first['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660}).status_code == 200
    assert [m.to for m in texts] == ["5550101234"] and "moved" in texts[0].body
    texts.clear()
    assert client.delete(f"/api/admin/bookings/{second['id']}", headers=auth).status_code == 200
    assert texts == []  # this customer never agreed to texts
    moved_id = [i for i in schedule_of(client, auth, "2026-10-15")["items"]][0]["id"]
    assert client.delete(f"/api/admin/bookings/{moved_id}", headers=auth).status_code == 200
    assert [m.to for m in texts] == ["5550101234"] and "cancelled" in texts[0].body


def test_consent_survives_a_move(client, auth, texts):
    book(client, smsConsent=True)
    item = schedule_of(client, auth)["items"][0]
    client.patch(f"/api/admin/bookings/{item['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    from app.database import bookings as bookings_db

    moved = schedule_of(client, auth, "2026-10-15")["items"][0]
    assert bookings_db.get_booking(moved["id"]).sms_consent is True


# --- the reminder email -------------------------------------------------------------------------------------


def test_the_reminder_email_is_branded_and_has_the_details():
    from app.emailing import templates as email_templates

    message = email_templates.customer_reminder(booking_model(), "vic@example.com")
    assert message.to == "m@example.com" and message.reply_to == "vic@example.com"
    assert "Reminder" in message.subject and "Tuesday, October 13 at 12:00 pm" in message.subject
    for part in (message.text, message.html):
        assert "VB-ABC234" in part and "VICBLESS BARBERSHOP" in part and "656 S Main St" in part
VICBLESS_EOF
cat > "$STAGE/24" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS, MAX_SERVICES, REMINDER_CHOICES, SLOT_MAX, SLOT_MIN, SLOT_STEP } from '../config.js'
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

// Monday first, the way people read a week (the numbers are JavaScript's: 0 is Sunday).
const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0]

const hoursText = (day) => {
  const windows = HOURS[day]
  return windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'
}

// Vic's shop settings, only reachable from inside his dashboard (Menu > Settings > Shop settings):
//   - the services, their prices and notes (add, rename, reorder, remove)
//   - how long an appointment is on each weekday, in steps of 5 minutes
// Saving changes what customers see and book straight away. Bookings already made keep their times and names.
export default function SettingsPanel({ onClose }) {
  const [saved, setSaved] = useState(null) // the settings as last saved, in the screens' shape
  const [draft, setDraft] = useState(null) // what Vic is editing
  const [errors, setErrors] = useState({ general: '', services: {}, slots: {} })
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
    setErrors(result.ok ? { general: '', services: {}, slots: {} } : result.errors)
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
cat > "$STAGE/25" <<'VICBLESS_EOF'
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
  display: flex;
  flex-wrap: wrap;
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
  flex: 1 1 0;
  width: auto;
  min-width: 0;
}

.admin-remind-list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.admin-svc-actions .admin-box-btn {
  padding-inline: 8px;
  font-size: 0.95rem;
  white-space: nowrap;
}
VICBLESS_EOF
cat > "$STAGE/26" <<'VICBLESS_EOF'
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
cat > "$STAGE/27" <<'VICBLESS_EOF'
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
  const booking = { ...payload, minutes: slot, serviceName: service ? service.name : '', code }
  writeBookings([...readBookings(), booking])
  return booking
}
VICBLESS_EOF
cat > "$STAGE/29" <<'VICBLESS_EOF'
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
cat > "$STAGE/30" <<'VICBLESS_EOF'
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
cat > "$STAGE/31" <<'VICBLESS_EOF'
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
  return { services, slotMinutes, reminderHours }
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
  current = settings
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
cat > "$STAGE/32" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/33" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, SMS_CONSENT, STAFF, SUCCESS_HEADLINE } from '../config.js'
import { fmtTime, fromKey, keyOf, slotsForDay, startsForDay } from '../lib/availability.js'
import { createBooking, getAvailability, SlotTakenError } from '../lib/api.js'
import { countLabel, nearLimit, priceLabel, serviceIdFromHash } from '../lib/format.js'
import { slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'

const STEPS = ['Service', 'Time', 'Details']
const REFRESH_MS = 30000 // how often the time grid re-checks while it is open
const payLine = (s) =>
  s.from
    ? `Pay at the shop. Starts at $${s.price}, the final price depends on what you get.`
    : `Pay at the shop. $${s.price} total.`

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
  // A service link on the home page (#/book?service=mens-design) arrives with the service chosen.
  const [preselected] = useState(() => serviceIdFromHash(window.location.hash, shop.services))
  const [step, setStep] = useState(preselected ? 1 : 0)
  const [serviceId, setServiceId] = useState(preselected)
  const [dateKey, setDateKey] = useState(null)
  const [time, setTime] = useState(null)
  const [form, setForm] = useState({ name: '', phone: '', email: '', notes: '', sms: false })
  const [errors, setErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [notice, setNotice] = useState('')
  const [done, setDone] = useState(null)

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
    if (!(slotsByDay[dateKey] || []).includes(time)) {
      setTime(null)
      setNotice('That time was just taken. Pick another time.')
    }
  }, [slotsByDay])

  const reach = !service ? 0 : time === null ? 1 : 2

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
      })
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
    } finally {
      setSubmitting(false)
    }
  }

  if (done) {
    // the booking remembers the name it was made with; the price comes from the current list when it is still there
    const current = SERVICES.find((s) => s.id === done.serviceId)
    const booked = { ...(current || { price: 0 }), name: done.serviceName || (current && current.name) || 'Appointment' }
    return (
      <main className="book book-done">
        <section className="done" aria-live="polite">
          <Reveal as="h1" from="above" className="done-headline">
            <span>{SUCCESS_HEADLINE[0]}</span> <span className="done-line-2">{SUCCESS_HEADLINE[1]}</span>
          </Reveal>
          <h2 className="book-title done-booked">You're booked, {done.name.split(' ')[0]}.</h2>
          <p className="code" aria-label="Confirmation code">{done.code}</p>
          <p>
            <strong>{booked.name}</strong> with {staff.name}
          </p>
          <p>
            {dayLabel(fromKey(done.dateKey))} at {fmtTime(done.start)}
          </p>
          {current && <p>{payLine(booked)}</p>}
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
            <p className="muted">Pay at the shop. No card needed to book.</p>
            <div className="actions">
              <button type="button" className="btn" onClick={() => setStep(1)}>
                Back
              </button>
              <button type="submit" className="btn btn-primary" disabled={submitting}>
                {submitting ? 'Confirming…' : 'Confirm booking'}
              </button>
            </div>
          </form>
        </section>
      )}
    </main>
  )
}
VICBLESS_EOF
cat > "$STAGE/34" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/35" <<'VICBLESS_EOF'
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
  FunctionName:
    Value: !Ref ApiFunction
VICBLESS_EOF
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"a08e9a95389866b5681c66f377453e7854c7610b18375644a881afeed630925c\", \"new\": 0}, {\"path\": \"backend/app/core/config.py\", \"base\": \"4762492b298344b02f0498ddab796da8000dc0eea7ef9fefd437feed35136699\", \"new\": 1}, {\"path\": \"backend/app/database/bookings.py\", \"base\": \"73fe54e45c578a1c14bf9af785627fef44c36971cb3b77cf37687635685f4cfc\", \"new\": 2}, {\"path\": \"backend/app/database/reminders.py\", \"base\": null, \"new\": 3}, {\"path\": \"backend/app/database/settings.py\", \"base\": \"6b6ec195b7d05ff865be0f937cb84b4ca125b8611e70930b97105bbb47b90382\", \"new\": 4}, {\"path\": \"backend/app/domain/models.py\", \"base\": \"24da101b47786ada9b123aa5e95b4746bea558170bf8fbd7100a47268c649693\", \"new\": 5}, {\"path\": \"backend/app/domain/shop.py\", \"base\": \"04e08b38bf19f7f00b3c090c9a735b52a9a3e156baa6f6b96acae11d8f7b9646\", \"new\": 6}, {\"path\": \"backend/app/emailing/templates.py\", \"base\": \"f7c8ad0e64eedaea780a944f9a4667a424c7727cd1b84719da63bdb9d76756b1\", \"new\": 7}, {\"path\": \"backend/app/handler.py\", \"base\": \"7d07cc5bc98fe5291c60526cdf14944a524d78e9496c20259b18504c935819f5\", \"new\": 8}, {\"path\": \"backend/app/schemas/requests.py\", \"base\": \"8dff7c071b5f65e270c19717322d6e38d2326170515349cb040e8e32fb49dea1\", \"new\": 9}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"2a2e10fd794906c6e88e64db40d77569b2756a855a8e21cd12af2e394bba9c5d\", \"new\": 10}, {\"path\": \"backend/app/services/notifications.py\", \"base\": \"9485774a49ad5937f6789620066ee5f34c5e1086f0a86fc2602c408f550cfbc0\", \"new\": 11}, {\"path\": \"backend/app/services/reminders.py\", \"base\": null, \"new\": 12}, {\"path\": \"backend/app/services/settings.py\", \"base\": \"e7bc4dfef7532630f0a7c70fe9fa4bc8f5217c390aeb441a3ed583723efe0764\", \"new\": 13}, {\"path\": \"backend/app/texting/__init__.py\", \"base\": null, \"new\": 14}, {\"path\": \"backend/app/texting/templates.py\", \"base\": null, \"new\": 15}, {\"path\": \"backend/app/texting/textbelt.py\", \"base\": null, \"new\": 16}, {\"path\": \"backend/tests/conftest.py\", \"base\": \"f3d3e91f4a2e4aebabbc147b4bd9863e72919b593f34e8f4fe1eba53de57a2c8\", \"new\": 17}, {\"path\": \"backend/tests/fixtures/sms.py\", \"base\": null, \"new\": 18}, {\"path\": \"backend/tests/test_contract.py\", \"base\": \"6e257a3c273fcaabfae3721944d881e48c7b93d1ae13c97089b28bb956324530\", \"new\": 19}, {\"path\": \"backend/tests/test_reminders.py\", \"base\": null, \"new\": 20}, {\"path\": \"backend/tests/test_structure.py\", \"base\": \"af1c4a6b50d48d018d6596733474d6ec7e739989f13ae0be94f617bb28ab719a\", \"new\": 21}, {\"path\": \"backend/tests/test_template.py\", \"base\": \"cfbb7d4e0a9e781ebe5b53cbde60264b0b76e574b4f85a155bc4c9594ad326a9\", \"new\": 22}, {\"path\": \"backend/tests/test_texting.py\", \"base\": null, \"new\": 23}, {\"path\": \"frontend/src/admin/SettingsPanel.jsx\", \"base\": \"b51ee5a7b0e8ad898352cff25ad69e86242ed2ef2e1fb6394bf0f44cc60b1bbc\", \"new\": 24}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"d1a9f09584dc14c9b361e09c00dcc07dcd42eb7739b1a72ee073af305772bba8\", \"new\": 25}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"5de73fe9da259066f3dcda712f48e2042e1d95f4c6746ac55edc20b9de7969ff\", \"new\": 26}, {\"path\": \"frontend/src/config.js\", \"base\": \"3e1a11dd1522707dee187201b584f997e1a85bcb4c40b525d6a5686607578789\", \"new\": 27}, {\"path\": \"frontend/src/lib/mockApi.js\", \"base\": \"eaf2c9a9da0ee200e981b10a68ffecdb1c73e4adb3dc99a7b51cba13dceafba7\", \"new\": 28}, {\"path\": \"frontend/src/lib/realApi.js\", \"base\": \"f2285f798cb0f70ea511af4ebd0695fee106ddf5ac0303ecc028888cb50fef9f\", \"new\": 29}, {\"path\": \"frontend/src/lib/realApi.test.js\", \"base\": \"e00865fafeef9b15e2d29d261f2e6c8f4a1265a01d92378e8cdbd4dc477326f3\", \"new\": 30}, {\"path\": \"frontend/src/lib/shopSettings.js\", \"base\": \"3d61bbaa5d473e0b12cd98690d839fc99812a57fa4b39add423ea5fccaad1700\", \"new\": 31}, {\"path\": \"frontend/src/lib/shopSettings.test.js\", \"base\": \"9dacf499473e90da0786298ef8392e53649b6c68ae6adb295a20c1aadb9d0819\", \"new\": 32}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"85b90b316e7f1e46c0301b9c0d94d838b9351e35aa36281d728c985fbb9316ad\", \"new\": 33}, {\"path\": \"frontend/src/styles.css\", \"base\": \"e12c2bfa13e6983b7da7e07be4bb44e096baf517ec4a7ef76914215fc357ff9b\", \"new\": 34}, {\"path\": \"infra/template.yaml\", \"base\": \"ee417c04604aec36f1e1f17faa466cb58e0a3ce5acffc753b6976682b1b92e64\", \"new\": 35}]")

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
echo "Next: add Vic's number and the Textbelt key to AWS (see the message that came with this script), commit, push to dev."
