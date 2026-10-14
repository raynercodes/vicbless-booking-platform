#!/usr/bin/env bash
# Vicbless: editable services and appointment lengths (Monday/Tuesday 45 minutes)
# Run from the REPO ROOT:  bash vicbless-editable-settings-and-45-minute-mon-tue.sh
#
# Adds Shop settings to Vic's dashboard (services, prices, per-day appointment length in 5 minute steps),
# Monday and Tuesday at 45 minutes by default, and a one-time migration script.
# Needs the branded-email installer applied first.
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
    services/      what happens: bookings.py, blocks.py, auth.py, schedule.py, notifications.py (emails)
    database/      everything that touches DynamoDB: bookings.py, blocks.py, schedule.py (reads),
                   login_attempts.py, keys.py (how items are named), transactions.py (the no-double-booking write), table.py
    domain/        the shop itself: shop.py (hours, default services and appointment lengths, booking rules) and models.py (Booking, Block, ids)
    schemas/       requests.py: what the site is allowed to send, cleaned and checked
    core/          config.py (settings + AWS secrets), security.py (password + session), aws.py, logs.py, errors.py, web.py (headers, CORS, error JSON)
    emailing/      email providers: resend.py (today), templates.py (the three emails)
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
- the wording of an email: `emailing/templates.py`

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
VICBLESS_EOF
cat > "$STAGE/3" <<'VICBLESS_EOF'
"""Plumbing every request goes through: error JSON, security headers, request ids, body size, CORS.

Nothing in here is about bookings. It makes sure every response, success or failure, looks the same
and carries the same safety headers.
"""

from __future__ import annotations

import logging
import time
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import config
from .errors import ApiError
from .logs import log, request_id

# A booking is a few hundred bytes. Refusing anything bigger than 16 KB stops oversized junk early.
MAX_BODY_BYTES = 16 * 1024

# Added to every response. no-store means browsers and CloudFront never cache API answers
# (a cached availability list could show a time as free after it was taken).
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}


def error_response(status: int, code: str, message: str, **extra) -> JSONResponse:
    """Every error looks like { "error": { "code", "message", ... } } so the site only needs one way to read them."""
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message, **extra}})


def add_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError):
        extra = {"field": exc.field} if exc.field else {}
        return error_response(exc.status, exc.code, exc.message, **extra)

    @app.exception_handler(RequestValidationError)
    async def _invalid(_: Request, exc: RequestValidationError):
        # Only the first problem is reported, so the person fixes one thing at a time.
        first = exc.errors()[0] if exc.errors() else {}
        field = ".".join(str(p) for p in first.get("loc", ()) if p not in ("body", "query"))
        if first.get("type") == "value_error":
            # Our own validators (schemas/requests.py) wrote this sentence for people. Show it as it is.
            message = str(first.get("msg", "")).removeprefix("Value error, ")
        else:
            # Pydantic's own wording ("Input should be a valid integer") is for programmers, so replace it.
            message = "Some of the details aren't valid. Please check them and try again."
        return error_response(422, "validation_error", message, field=field)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException):
        codes = {404: "not_found", 405: "method_not_allowed"}
        message = "We couldn't find that." if exc.status_code == 404 else "That isn't allowed."
        return error_response(exc.status_code, codes.get(exc.status_code, "error"), message)


def add_middleware(app: FastAPI) -> None:
    # CORS: which websites may call this API from a browser. Set per environment from the template.
    # No cookies are used (admin sends a Bearer token), so credentials stay off.
    origins = config.get_settings().cors_origins
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(origins),
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type"],
            allow_credentials=False,
            max_age=600,
        )

    # One wrapper around every request: tag it with an id, refuse oversized bodies, turn surprises into
    # a clean 500, add the safety headers, and write one log line (never with names, phones or emails).
    @app.middleware("http")
    async def _wrap(request: Request, call_next):
        # The id ties together every log line from one request, and is sent back so a problem can be traced.
        rid = request.headers.get("x-amzn-trace-id") or uuid.uuid4().hex
        token = request_id.set(rid[:64])
        started = time.perf_counter()
        try:
            length = request.headers.get("content-length")
            if length and length.isdigit() and int(length) > MAX_BODY_BYTES:
                response = error_response(413, "payload_too_large", "That request is too big.")
            else:
                try:
                    response = await call_next(request)
                except Exception as exc:
                    log("unhandled_error", logging.ERROR, errorType=type(exc).__name__, path=request.url.path)
                    # The real error goes to the logs only. The caller never sees internal details.
                    response = error_response(500, "server_error", "Something went wrong on our side. Please try again.")
            for name, value in SECURITY_HEADERS.items():
                response.headers.setdefault(name, value)
            response.headers["X-Request-Id"] = rid[:64]
            log(
                "request",
                method=request.method,
                path=request.url.path,
                status=response.status_code,
                ms=round((time.perf_counter() - started) * 1000),
            )
            return response
        finally:
            request_id.reset(token)
VICBLESS_EOF
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""Blocked time (lunch, a day off) in the database: create, find, remove."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import Conflict, NotFound, SlotTaken
from ..domain.models import Block, new_id, parse_id
from . import keys, table, transactions
from .keys import PK


def block_from(item: dict) -> Block:
    """Turns a raw DynamoDB item into a Block."""
    return Block(
        id=item["id"],
        day=date.fromisoformat(item["date"]),
        start=int(item["start"]),
        end=int(item["end"]),
        note=item.get("note", ""),
        whole=bool(item.get("whole", False)),
        claims=tuple(int(s) for s in item.get("blocks", [])),
    )


def get_block(block_id: str) -> Block | None:
    parsed = parse_id(block_id)
    if not parsed:
        return None
    day, start = parsed
    item = table.table().get_item(Key={"pk": PK, "sk": keys.block_sk(day, start, block_id)}, ConsistentRead=True).get("Item")
    return block_from(item) if item else None


def create_block(*, day: date, claims: list[int], start: int, end: int, note: str, whole: bool) -> Block:
    # Same trick as a booking: claim every covered 5 minute unit together with the block itself. If a booking or
    # another block-off already holds one of them, nothing is written and Vic gets a Conflict.
    block_id = new_id(day, claims[0])
    item = {
        "pk": PK,
        "sk": keys.block_sk(day, claims[0], block_id),
        "kind": "block",
        "id": block_id,
        "date": day.isoformat(),
        "start": start,
        "end": end,
        "note": note,
        "whole": whole,
        "blocks": claims,
        "units": True,  # claims are 5 minute units (see scripts/migrate_unit_claims.py for older items)
        "expiresAt": keys.expires(day),
    }
    put_item = {
        "Put": {
            "TableName": table.table_name(),
            "Item": item,
            "ConditionExpression": "attribute_not_exists(pk)",
        }
    }
    try:
        # One transaction normally; a very long block (a whole Saturday has over a hundred units) is split by write_claimed.
        transactions.write_claimed(put_item, day, claims, block_id)
    except SlotTaken:
        raise Conflict() from None
    return block_from(item)


def delete_block(block_id: str) -> Block:
    block = get_block(block_id)
    if not block:
        raise NotFound("That blocked time was not found. It may already be removed.")
    delete_item = {
        "Delete": {
            "TableName": table.table_name(),
            "Key": {"pk": PK, "sk": keys.block_sk(block.day, block.claims[0], block.id)},
            "ConditionExpression": "attribute_exists(pk)",
        }
    }
    try:
        transactions.delete_claimed(delete_item, block.day, list(block.claims), block.id)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            if get_block(block_id) is None:
                raise NotFound("That blocked time was not found. It may already be removed.") from None
        raise
    return block
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
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
    phone: str, email: str, notes: str, code: str, created: str,
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
        "blocks": shop.occupied_starts(start, minutes),  # the claims it holds. Releasing exactly these is what keeps cancelling safe
        "units": True,  # claims are 5 minute units (items made before that are brought up to date by scripts/migrate_unit_claims.py)
        "gsi1pk": f"PHONE#{phone}",  # sparse index: lets us count a phone number's upcoming bookings
        "gsi1sk": f"{day.isoformat()}#{shop.hhmm(start)}",
        "expiresAt": keys.expires(day),
    }


def create_booking(
    *, day: date, start: int, service_id: str, service_name: str, minutes: int, name: str, phone: str, email: str,
    notes: str, code: str,
) -> Booking:  # fmt: skip
    booking_id = new_id(day, start)
    claims = shop.occupied_starts(start, minutes)  # the 5 minute units this booking will hold
    created = datetime.now(timezone.utc).isoformat(timespec="seconds")
    item = _booking_item(
        booking_id=booking_id, day=day, start=start, service_id=service_id, service_name=service_name,
        minutes=minutes, name=name, phone=phone, email=email, notes=notes, code=code, created=created,
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
cat > "$STAGE/6" <<'VICBLESS_EOF'
"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 5 minute unit (a 45 minute booking holds nine)
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
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


def block_sk(day: date, start: int, block_id: str) -> str:
    return f"{day.isoformat()}#BLOCK#{shop.hhmm(start)}#{block_id}"


def minutes_of(hhmm: str) -> int:
    """'1235' -> 755 minutes after midnight (the reverse of shop.hhmm)."""
    return int(hhmm[:2]) * 60 + int(hhmm[2:])
VICBLESS_EOF
cat > "$STAGE/7" <<'VICBLESS_EOF'
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
        entry["busy"] = shop.busy_slots(day, entry["slotMinutes"], taken[day_key])
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
cat > "$STAGE/8" <<'VICBLESS_EOF'
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
    return shop.ShopSettings(slot_minutes=slots, services=services)


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
            "services": [
                {"id": s.id, "name": s.name, "price": s.price, "from": s.from_price, "note": s.note} for s in settings.services
            ],
            "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/10" <<'VICBLESS_EOF'
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
cat > "$STAGE/11" <<'VICBLESS_EOF'
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
cat > "$STAGE/12" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
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
from ..schemas.requests import BlockIn, LoginIn, MoveIn, SettingsIn, date_from_query
from ..services import auth, blocks, bookings, notifications
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
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
"""Routes anyone can call (mounted under /api).

A route's job is small: read the request, hand it to a service, and shape the answer. The decisions
(is this time bookable? who wins a race?) are made in services/ and database/, not here.
"""

from __future__ import annotations

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from ..core import config
from ..domain import shop
from ..schemas.requests import BookingIn, date_from_query
from ..services import bookings, notifications
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
    return settings_service.to_view(settings_service.current())


@router.post("/bookings")
def create_booking(body: BookingIn) -> JSONResponse:
    """A customer books a time.

    201 = a new booking was made. 200 = this exact request had already succeeded (a retry), so the
    same booking is returned and no second email goes out.
    """
    booking, created = bookings.create_booking(body, shop.now_local())
    if created:
        notifications.booking_created(booking)  # best effort: a failed email never fails the booking
    # public_view() leaves out the internal id; the customer only needs their code.
    return JSONResponse(status_code=201 if created else 200, content=booking.public_view())
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
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
cat > "$STAGE/16" <<'VICBLESS_EOF'
"""Vic blocking off time (lunch, a phone booking, a day off)."""

from __future__ import annotations

from datetime import datetime

from ..core.errors import InvalidSlot, ValidationFailed
from ..database import blocks as blocks_db
from ..domain import shop
from ..domain.models import Block
from ..schemas.requests import BlockIn, parse_date_key


def add_block(data: BlockIn, now: datetime) -> Block:
    """Blocks off part of a day, or all of it. Customers then see those times as taken (or the day as Closed)."""
    day = parse_date_key(data.dateKey)
    shop.check_blockable(day, now)  # open day, from today up to a year ahead
    windows = shop.windows_for(day)
    if data.whole:
        # A whole day off runs from the first opening time to the last closing time (Saturday's lunch gap included).
        start, end = windows[0][0], windows[-1][1]
    else:
        start, end = data.start, data.end
        if end <= start:
            raise ValidationFailed("The end time has to be after the start time.")
    # Turn the range into the 5 minute units it covers (only inside opening hours).
    claims = shop.block_units(day, start, end)
    if not claims:
        raise InvalidSlot("Pick times that fall inside opening hours.")
    # The database refuses (Conflict) if any of those blocks already holds a booking or another block-off.
    return blocks_db.create_block(day=day, claims=claims, start=start, end=end, note=data.note or "", whole=data.whole)


def remove_block(block_id: str) -> Block:
    """Opens blocked-off time back up."""
    return blocks_db.delete_block(block_id)
VICBLESS_EOF
cat > "$STAGE/17" <<'VICBLESS_EOF'
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
cat > "$STAGE/18" <<'VICBLESS_EOF'
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
    }
VICBLESS_EOF
cat > "$STAGE/19" <<'VICBLESS_EOF'
#!/usr/bin/env python3
"""One-time upgrade: give bookings and block-offs made BEFORE the settings update the 5 minute claims they need.

    AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev            # shows what it WOULD do
    AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev --apply    # does it

Why: the old site claimed one item per 35 minute block. The new site claims every 5 minute unit, so that the
appointment length can differ by weekday (Monday and Tuesday 45 minutes) and change later without any chance of a
double booking. A booking made the old way holds only its first unit(s); until it is upgraded, a new booking on a
different grid could overlap it. This script adds the missing units to every old booking and block-off.

Order of a release: 1) deploy the backend, 2) run this with --apply for that environment, 3) deploy the frontend.
It is safe to run twice (items already upgraded are skipped) and safe while the site is live: it only ever ADDS
claims that are free. If a claim is held by something else, that item is reported as a conflict and left alone
so Vic can look at it by hand.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.errors import SlotTaken  # noqa: E402
from app.database import keys, table, transactions  # noqa: E402
from app.database.keys import PK  # noqa: E402
from app.domain import shop  # noqa: E402

OLD_BLOCK_MINUTES = 35  # the length every old claim stood for


def wanted_units(item: dict) -> list[int]:
    """Every 5 minute unit an old item should hold."""
    if item["kind"] == "booking":
        start, minutes = int(item["start"]), int(item["minutes"])
        return shop.occupied_starts(start, minutes)
    old = sorted(int(u) for u in item.get("blocks", []))
    if not old:
        return []
    return list(range(old[0], old[-1] + OLD_BLOCK_MINUTES, shop.UNIT_MINUTES))


def old_items() -> list[dict]:
    """All bookings and block-offs not yet upgraded (they have no `units` marker). Follows DynamoDB paging."""
    found: list[dict] = []
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk",
        "ExpressionAttributeValues": {":pk": PK},
        "ConsistentRead": True,
    }
    while True:
        page = table.table().query(**kwargs)
        found += [i for i in page["Items"] if i.get("kind") in ("booking", "block") and not i.get("units")]
        if "LastEvaluatedKey" not in page:
            return found
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def upgrade(item: dict, units: list[int]) -> None:
    """Claims the units (in chunks), then marks the item upgraded. Raises SlotTaken if another item holds one."""
    day = date.fromisoformat(item["date"])
    ref = item["id"]
    size = transactions.CHUNK_CLAIMS
    for i in range(0, len(units), size):
        transactions.write_all_or_nothing(
            [transactions.claim_put(day, u, ref, allow_same_ref=True) for u in units[i : i + size]]
        )
    table.table().update_item(
        Key={"pk": item["pk"], "sk": item["sk"]},
        UpdateExpression="SET #b = :b, units = :t",
        ExpressionAttributeNames={"#b": "blocks"},
        ExpressionAttributeValues={":b": units, ":t": True},
    )


def migrate(apply: bool) -> dict[str, int]:
    """Upgrades (or, without `apply`, only counts) every old item. Returns {'upgraded', 'conflicts', 'already_ok'}."""
    report = {"upgraded": 0, "conflicts": 0, "already_ok": 0}
    for item in old_items():
        units = wanted_units(item)
        if not units:
            report["already_ok"] += 1
            continue
        label = f"{item['kind']} {item['id']}"
        if not apply:
            print(f"would upgrade {label}: {len(units)} units")
            report["upgraded"] += 1
            continue
        try:
            upgrade(item, units)
        except SlotTaken:
            print(f"CONFLICT {label}: a unit is held by something else. Left alone; check it by hand.", file=sys.stderr)
            report["conflicts"] += 1
        else:
            print(f"upgraded {label}: {len(units)} units")
            report["upgraded"] += 1
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--apply", action="store_true", help="really write (without this it only shows what it would do)")
    args = parser.parse_args()

    os.environ["ENVIRONMENT"] = args.env
    os.environ["TABLE_NAME"] = f"vicbless-{args.env}"
    os.environ.setdefault("AWS_DEFAULT_REGION", args.region)

    report = migrate(args.apply)
    verb = "Upgraded" if args.apply else "Would upgrade"
    print(f"\n{verb} {report['upgraded']}; conflicts {report['conflicts']}; nothing to do {report['already_ok']}.")
    if not args.apply and report["upgraded"]:
        print("Run again with --apply to write the changes.")
    return 1 if report["conflicts"] else 0


if __name__ == "__main__":
    sys.exit(main())
VICBLESS_EOF
cat > "$STAGE/20" <<'VICBLESS_EOF'
"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock, classic_grid   run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails

Shared test data and shortcuts live in tests/helpers/ (builders, api shortcuts, constants).
"""

from tests.fixtures.api import admin_setup, auth, client  # noqa: F401
from tests.fixtures.aws import atomic_transactions, aws  # noqa: F401
from tests.fixtures.clock import fixed_clock  # noqa: F401
from tests.fixtures.email import sent  # noqa: F401
from tests.fixtures.settings import classic_grid  # noqa: F401
VICBLESS_EOF
cat > "$STAGE/21" <<'VICBLESS_EOF'
"""The shop's settings in tests."""

import dataclasses

import pytest

from app.domain import shop

# The shop's real defaults (Monday and Tuesday are 45 minutes). Captured at import, before any test changes them,
# so the few tests about the defaults themselves can still see the real ones.
REAL_DEFAULTS = shop.DEFAULT_SETTINGS

# What most tests run with: every day 35 minutes, the grid the first tests were written for. They are about HOW booking
# works (claims, races, emails), not about which length a weekday has, so one familiar grid keeps them easy to read.
# Tests about the 45 minute days, mixed lengths, and saving settings set their own.
CLASSIC = dataclasses.replace(REAL_DEFAULTS, slot_minutes=(35,) * 7)


@pytest.fixture(autouse=True)
def classic_grid(monkeypatch):
    """Runs around every test: until a test saves its own settings, the shop's settings are CLASSIC."""
    monkeypatch.setattr(shop, "DEFAULT_SETTINGS", CLASSIC)
VICBLESS_EOF
cat > "$STAGE/22" <<'VICBLESS_EOF'
"""Builds test data. Each builder has sensible defaults, so a test only spells out what it is about."""

from datetime import date

from app.database import bookings as bookings_db
from app.database import keys
from app.database import schedule as schedule_db
from app.domain import shop
from app.domain.models import Booking

from .constants import TUESDAY


def booking_body(**over) -> dict:
    """The JSON the booking page sends, as a dict. Override any field: booking_body(name="A")."""
    body = {
        "staffId": "vic",
        "serviceId": "mens-cut",
        "dateKey": TUESDAY,
        "start": 12 * 60,  # 12:00 pm, the first block on a Tuesday
        "minutes": 35,
        "name": "Marcus Jones",
        "phone": "(555) 010-1234",
        "email": "",
        "notes": "",
    }
    body.update(over)
    return body


def booking_model(**over) -> Booking:
    """A Booking object (no database involved), for template and formatting tests."""
    args = dict(
        id="2026-10-13.1200.abcdef12",
        code="VB-ABC234",
        day=date(2026, 10, 13),
        start=720,
        minutes=35,
        service_id="mens-cut",
        service_name="Men's haircut",
        name="Marcus Jones",
        phone="5550101234",
        email="m@example.com",
        notes="",
        created_at="",
    )
    args.update(over)
    return Booking(**args)


def make_booking(start=720, minutes=35, phone="5550101234", day=date(2026, 10, 13), **over) -> Booking:
    """Writes a booking straight into the database, skipping the web layer and the booking rules."""
    args = dict(
        day=day,
        start=start,
        service_id="mens-cut",
        service_name="Men's haircut",
        minutes=minutes,
        name="A Person",
        phone=phone,
        email="",
        notes="",
        code="VB-AAAAAA",
    )
    args.update(over)
    return bookings_db.create_booking(**args)


def taken_blocks(day: date = date(2026, 10, 13)) -> list[int]:
    """The taken appointment starts for one day, as the database reports them (with the settings tests use)."""
    return schedule_db.availability(day, day, shop.DEFAULT_SETTINGS)[day.isoformat()]["busy"]


def taken_units(day: date = date(2026, 10, 13)) -> list[int]:
    """Every 5 minute unit that is claimed on one day, straight from the claim items."""
    items = schedule_db.query_range(f"{day.isoformat()}#CLAIM#", f"{day.isoformat()}#CLAIM#~")
    return sorted(keys.minutes_of(item["sk"].split("#")[2]) for item in items)
VICBLESS_EOF
cat > "$STAGE/23" <<'VICBLESS_EOF'
import time

import jwt
import pytest

from app.core import security
from tests.helpers.api import schedule_of
from tests.helpers.builders import booking_body
from tests.helpers.constants import ADMIN_PASSWORD, JWT_SECRET, TUESDAY

D = TUESDAY


def test_login_wrong_password(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": "nope"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"


def test_login_not_configured(client):
    r = client.post("/api/admin/login", json={"password": "x"})
    assert r.status_code == 503 and r.json()["error"]["code"] == "not_configured"


def test_login_ok_returns_a_12_hour_token(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 200 and r.json()["expiresIn"] == 43200
    claims = jwt.decode(r.json()["token"], JWT_SECRET, algorithms=["HS256"], audience="vicbless-admin")
    assert claims["exp"] - claims["iat"] == 43200 and claims["sub"] == "vic"


def test_lockout_after_five_failures_then_correct_password_is_refused(client, admin_setup):
    for _ in range(5):
        assert client.post("/api/admin/login", json={"password": "bad"}).status_code == 401
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 429 and r.json()["error"]["code"] == "too_many_attempts"


def test_success_resets_the_counter(client, admin_setup):
    for _ in range(4):
        client.post("/api/admin/login", json={"password": "bad"})
    assert client.post("/api/admin/login", json={"password": ADMIN_PASSWORD}).status_code == 200
    for _ in range(4):
        assert client.post("/api/admin/login", json={"password": "bad"}).status_code == 401


ADMIN_ROUTES = [
    ("get", f"/api/admin/schedule?date={D}"),
    ("delete", f"/api/admin/bookings/{D}.0720.abcdef12"),
    ("post", "/api/admin/blocks"),
    ("delete", f"/api/admin/blocks/{D}.0720.abcdef12"),
]


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_need_a_token(client, admin_setup, method, path):
    r = getattr(client, method)(path) if method != "post" else client.post(path, json={})
    assert r.status_code == 401


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_reject_bad_tokens(client, admin_setup, method, path):
    expired = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "iat": int(time.time()) - 90000, "exp": int(time.time()) - 10},
        JWT_SECRET,
        algorithm="HS256",
    )
    wrong_key = security.issue_token("z" * 40)
    none_alg = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "exp": int(time.time()) + 999}, key=None, algorithm="none"
    )
    good = security.issue_token(JWT_SECRET)
    wrong_audience = jwt.encode(
        {"iss": "vicbless", "aud": "other", "sub": "vic", "iat": 1, "exp": int(time.time()) + 999}, JWT_SECRET, algorithm="HS256"
    )
    for token in (expired, wrong_key, none_alg, wrong_audience, good[:-3] + "abc", "garbage"):
        headers = {"Authorization": f"Bearer {token}"}
        r = client.request(method.upper(), path, headers=headers, json={} if method == "post" else None)
        assert r.status_code == 401, token


def test_non_bearer_scheme_rejected(client, admin_setup):
    token = security.issue_token(JWT_SECRET)
    r = client.get(f"/api/admin/schedule?date={D}", headers={"Authorization": f"Basic {token}"})
    assert r.status_code == 401


def test_schedule_shows_booking_with_contact_details(client, auth):
    client.post("/api/bookings", json=booking_body(email="m@example.com", notes="Short on the sides"))
    day = schedule_of(client, auth)
    [item] = day["items"]
    assert item["name"] == "Marcus Jones" and item["email"] == "m@example.com" and item["notes"] == "Short on the sides"
    assert item["source"] == "online" and item["code"].startswith("VB-") and item["start"] == 720 and item["dateKey"] == D
    assert day["blocks"] == []


def test_cancel_frees_the_time_and_emails_the_customer(client, auth, sent):
    client.post("/api/bookings", json=booking_body(email="m@example.com"))
    sent.clear()
    [item] = schedule_of(client, auth)["items"]
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 200
    assert schedule_of(client, auth)["items"] == []
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D]["busy"] == []
    assert [m.to for m in sent] == ["m@example.com"] and "cancelled" in sent[0].subject
    assert client.post("/api/bookings", json=booking_body(name="New Person", phone="5550107777")).status_code == 201


def test_cancel_unknown_or_malformed_id_is_404(client, auth):
    for bad in (f"{D}.0720.abcdef12", "nonsense", "..%2F..", f"{D}.9999.abcdef12"):
        r = client.delete(f"/api/admin/bookings/{bad}", headers=auth)
        assert r.status_code == 404, bad


def test_cancel_twice_second_is_404(client, auth):
    client.post("/api/bookings", json=booking_body())
    [item] = schedule_of(client, auth)["items"]
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 200
    assert client.delete(f"/api/admin/bookings/{item['id']}", headers=auth).status_code == 404


def test_part_day_block_hides_times(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 790, "note": "Lunch"})
    assert r.status_code == 201
    block = r.json()
    assert block["whole"] is False and block["note"] == "Lunch" and block["start"] == 720 and block["end"] == 790
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D] == {"busy": [720, 755], "dayOff": False, "slotMinutes": 35}
    assert client.post("/api/bookings", json=booking_body()).status_code == 409
    assert schedule_of(client, auth)["blocks"][0]["id"] == block["id"]
    assert client.delete(f"/api/admin/blocks/{block['id']}", headers=auth).status_code == 200
    assert client.post("/api/bookings", json=booking_body()).status_code == 201


def test_whole_day_off_shows_closed(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "whole": True})
    assert r.status_code == 201 and r.json()["start"] == 720 and r.json()["end"] == 1080
    day = client.get(f"/api/availability?from={D}&to={D}").json()[D]
    assert day["dayOff"] is True and len(day["busy"]) == 10
    assert client.post("/api/bookings", json=booking_body()).status_code == 409


def test_whole_saturday_covers_both_windows(client, auth):
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": "2026-10-17", "whole": True})
    assert r.status_code == 201
    day = client.get("/api/availability?from=2026-10-17&to=2026-10-17").json()["2026-10-17"]
    assert 540 in day["busy"] and 755 in day["busy"] and 720 not in day["busy"]


def test_block_over_a_booking_is_conflict_and_changes_nothing(client, auth):
    client.post("/api/bookings", json=booking_body(start=755))  # 12:35
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 900})
    assert r.status_code == 409 and r.json()["error"]["code"] == "conflict"
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D]["busy"] == [755]
    assert schedule_of(client, auth)["blocks"] == []


def test_overlapping_blocks_conflict(client, auth):
    assert client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 720, "end": 790}).status_code == 201
    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": D, "start": 755, "end": 825})
    assert r.status_code == 409


@pytest.mark.parametrize(
    "body,status",
    [
        ({"dateKey": "2026-10-14", "whole": True}, 422),  # closed day
        ({"dateKey": "2026-10-09", "whole": True}, 422),  # past
        ({"dateKey": "2027-12-31", "whole": True}, 422),  # too far
        ({"dateKey": D, "start": 800, "end": 700}, 422),
        ({"dateKey": D, "start": 0, "end": 60}, 422),  # outside hours
        ({"dateKey": "bad", "whole": True}, 422),
    ],
)
def test_block_validation(client, auth, body, status):
    assert client.post("/api/admin/blocks", headers=auth, json=body).status_code == status


def test_block_can_be_a_year_ahead(client, auth):
    # 2027-10-12 is a Tuesday and exactly 365 days from the fixed "today"
    assert client.post("/api/admin/blocks", headers=auth, json={"dateKey": "2027-10-12", "whole": True}).status_code == 201


def test_remove_unknown_block_404(client, auth):
    assert client.delete(f"/api/admin/blocks/{D}.0720.abcdef12", headers=auth).status_code == 404


@pytest.mark.parametrize("header", [None, "", "Bearer", "Bearer   ", "Basic abc", "Token abc", "abc"])
def test_check_bearer_rejects_headers_that_are_not_a_bearer_token(admin_setup, header):
    from app.core.errors import Unauthorized
    from app.services import auth as auth_service

    with pytest.raises(Unauthorized):
        auth_service.check_bearer(header)


def test_check_bearer_accepts_a_valid_token_in_any_letter_case(admin_setup):
    from app.services import auth as auth_service

    token = security.issue_token(JWT_SECRET)
    auth_service.check_bearer(f"Bearer {token}")
    auth_service.check_bearer(f"bearer {token}")
VICBLESS_EOF
cat > "$STAGE/24" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/25" <<'VICBLESS_EOF'
import pytest

from tests.helpers.api import book, busy
from tests.helpers.aws import put_param
from tests.helpers.constants import TUESDAY

D = TUESDAY


def test_health(client):
    put_param("app-version", "1.0.7+abc1234", secure=False)
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "environment": "dev", "version": "1.0.7+abc1234"}


def test_health_without_version_parameter(client):
    assert client.get("/api/health").json()["version"] == "unknown"


@pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json", "/api/docs", "/api/redoc", "/api/openapi.json"])
def test_docs_are_off(client, path):
    assert client.get(path).status_code == 404


def test_unknown_route_has_json_error(client):
    r = client.get("/api/nope")
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"


def test_book_then_availability_shows_it(client):
    r = book(client)
    assert r.status_code == 201
    body = r.json()
    assert body["code"].startswith("VB-") and len(body["code"]) == 9
    assert "id" not in body and "phone" not in body
    assert busy(client) == [720]


def test_availability_covers_every_day_in_range(client):
    days = client.get("/api/availability?from=2026-10-12&to=2026-10-14").json()
    assert sorted(days) == ["2026-10-12", "2026-10-13", "2026-10-14"]
    assert days["2026-10-14"] == {"busy": [], "dayOff": False, "slotMinutes": 35}


def test_second_booking_same_time_is_409_slot_taken(client):
    assert book(client).status_code == 201
    r = book(client, name="Someone Else", phone="5550109999")
    assert r.status_code == 409 and r.json()["error"]["code"] == "slot_taken"


def test_retry_of_same_request_returns_same_booking(client, sent):
    first = book(client, email="a@example.com")
    second = book(client, email="a@example.com")
    assert first.status_code == 201 and second.status_code == 200
    assert first.json()["code"] == second.json()["code"]
    assert len(sent) == 2  # owner + customer once, no second round for the retry


def test_neighbouring_blocks_do_not_collide(client):
    assert book(client, start=12 * 60 + 35).status_code == 201
    r = book(client, start=12 * 60, name="Other Person", phone="5550108888")
    assert r.status_code == 201
    assert busy(client) == [720, 755]


def test_client_cannot_choose_the_length(client):
    book(client, serviceId="buzz-beard", minutes=500)
    assert busy(client) == [720]


@pytest.mark.parametrize(
    "over,status,code",
    [
        ({"dateKey": "2026-10-14"}, 422, "invalid_slot"),  # closed Wednesday
        ({"start": 12 * 60 + 5}, 422, "invalid_slot"),  # off the grid
        ({"start": 17 * 60 + 50}, 422, "invalid_slot"),  # runs past closing
        ({"dateKey": "2026-10-10", "start": 9 * 60}, 409, "slot_unavailable"),  # past
        ({"dateKey": "2026-10-26"}, 409, "slot_unavailable"),  # beyond the booking window
        ({"dateKey": "2026-10-12", "start": 10 * 60}, 422, "invalid_slot"),  # before opening
    ],
)
def test_slot_rules(client, over, status, code):
    r = book(client, **over)
    assert r.status_code == status and r.json()["error"]["code"] == code


@pytest.mark.parametrize(
    "over",
    [
        {"name": "A"},
        {"name": "   "},
        {"name": "x" * 101},
        {"phone": "12345"},
        {"phone": "1" * 16},
        {"email": "not-an-email"},
        {"notes": "x" * 501},
        {"serviceId": "free-haircut"},
        {"staffId": "someone"},
        {"dateKey": "2026-13-45"},
        {"dateKey": "tomorrow"},
        {"start": "noon"},
        {"start": True},
        {"start": 2000},
    ],
)
def test_validation(client, over):
    r = book(client, **over)
    assert r.status_code == 422 and r.json()["error"]["code"] == "validation_error", r.text


def test_missing_fields_and_bad_json(client):
    assert client.post("/api/bookings", json={}).status_code == 422
    assert client.post("/api/bookings", content="{nope", headers={"content-type": "application/json"}).status_code == 422


def test_phone_is_normalized_and_extra_fields_ignored(client, auth):
    r = book(client, phone="+1 (555) 010-1234", isAdmin=True)
    assert r.status_code == 201
    items = client.get(f"/api/admin/schedule?date={D}", headers=auth).json()["items"]
    assert items[0]["phone"] == "5550101234"


def test_name_cleaned(client, auth):
    book(client, name="  Marcus \t\n  Jones\x00 ")
    assert client.get(f"/api/admin/schedule?date={D}", headers=auth).json()["items"][0]["name"] == "Marcus Jones"


def test_phone_cap_of_three_upcoming(client):
    plan = [("2026-10-13", 12 * 60), ("2026-10-15", 11 * 60), ("2026-10-16", 11 * 60)]
    for day, start in plan:
        assert book(client, dateKey=day, start=start).status_code == 201, day
    r = book(client, dateKey="2026-10-20", start=12 * 60)
    assert r.status_code == 429 and r.json()["error"]["code"] == "too_many_bookings"
    # a retry of one of the three is still answered with that booking
    assert book(client, dateKey="2026-10-13", start=12 * 60).status_code == 200


def test_availability_range_rules(client):
    assert client.get("/api/availability?from=2026-10-12").status_code == 422
    assert client.get("/api/availability?from=2026-10-14&to=2026-10-12").status_code == 422
    assert client.get("/api/availability?from=2026-10-01&to=2026-12-31").status_code == 422
    assert client.get("/api/availability?from=2026-10-01&to=2026-10-31").status_code == 200


def test_security_headers_and_request_id(client):
    r = client.get("/api/health")
    assert r.headers["cache-control"] == "no-store"
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["x-request-id"]


def test_oversized_body_rejected(client):
    r = client.post("/api/bookings", content="x" * 20000, headers={"content-type": "application/json"})
    assert r.status_code == 413


def test_unexpected_error_is_json_500_without_details(client, monkeypatch):
    from app.database import schedule as schedule_db

    def boom(*a, **k):
        raise RuntimeError("secret internals")

    monkeypatch.setattr(schedule_db, "availability", boom)
    r = client.get("/api/availability?from=2026-10-12&to=2026-10-13")
    assert r.status_code == 500 and "secret" not in r.text
    assert r.json()["error"]["code"] == "server_error"
    assert r.headers["cache-control"] == "no-store"


def test_cors(monkeypatch):
    from fastapi.testclient import TestClient

    from app.main import create_app

    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", "https://vicbless.com, https://www.vicbless.com")
    c = TestClient(create_app())
    ok = c.get("/api/health", headers={"Origin": "https://vicbless.com"})
    assert ok.headers["access-control-allow-origin"] == "https://vicbless.com"
    assert "access-control-allow-credentials" not in ok.headers
    other = c.get("/api/health", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in other.headers
    pre = c.options(
        "/api/bookings",
        headers={
            "Origin": "https://vicbless.com",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )
    assert pre.status_code == 200
VICBLESS_EOF
cat > "$STAGE/26" <<'VICBLESS_EOF'
import threading
from datetime import date

import pytest

from app.core.errors import Conflict, NotFound, SlotTaken
from app.database import blocks as blocks_db
from app.database import bookings as bookings_db
from app.database import login_attempts
from app.database import schedule as schedule_db
from app.domain import shop
from tests.helpers.aws import raw_table
from tests.helpers.builders import make_booking as make
from tests.helpers.builders import taken_blocks as claims

TUE = date(2026, 10, 13)


def test_two_blocks_are_claimed_for_a_70_minute_booking():
    make(minutes=70)
    assert claims() == [720, 755]


def test_overlap_with_a_multi_block_booking_is_refused_and_writes_nothing():
    make(start=720, minutes=70)
    with pytest.raises(SlotTaken):
        make(start=755, phone="5550102222")
    assert claims() == [720, 755]
    bookings, _ = schedule_db.day_schedule(TUE)
    assert len(bookings) == 1


def test_all_or_nothing_when_the_second_block_is_taken():
    make(start=755)
    with pytest.raises(SlotTaken):
        make(start=720, minutes=70, phone="5550102222")
    assert claims() == [755]  # the 12:00 claim was NOT left behind
    assert len(schedule_db.day_schedule(TUE)[0]) == 1


def test_cancel_releases_every_block():
    b = make(minutes=70)
    bookings_db.cancel_booking(b.id)
    assert claims() == []
    make(start=755, phone="5550102222")  # now free


def test_cancel_does_not_touch_other_bookings():
    a = make(start=720)
    make(start=755, phone="5550102222")
    bookings_db.cancel_booking(a.id)
    assert claims() == [755]


def test_cancel_missing_is_not_found():
    with pytest.raises(NotFound):
        bookings_db.cancel_booking("2026-10-13.0720.abcdef12")


def test_items_carry_a_ttl_and_the_sparse_index_keys():
    b = make()
    table = raw_table()
    item = table.get_item(Key={"pk": "STAFF#vic", "sk": f"2026-10-13#BOOKING#1200#{b.id}"})["Item"]
    claim = table.get_item(Key={"pk": "STAFF#vic", "sk": "2026-10-13#CLAIM#1200"})["Item"]
    assert int(item["expiresAt"]) == int(claim["expiresAt"]) > 1_790_000_000
    assert item["gsi1pk"] == "PHONE#5550101234" and "gsi1pk" not in claim


def test_phone_count_only_counts_from_the_given_day():
    make(phone="5550101234")
    make(start=755, phone="5550101234")
    make(start=720, day=date(2026, 10, 15), phone="5550101234")
    assert bookings_db.upcoming_for_phone("5550101234", TUE) == 3
    assert bookings_db.upcoming_for_phone("5550101234", date(2026, 10, 14)) == 1
    assert bookings_db.upcoming_for_phone("5559999999", TUE) == 0


def test_block_and_booking_conflict_both_ways():
    blocks_db.create_block(day=TUE, claims=[720, 755], start=720, end=790, note="", whole=False)
    with pytest.raises(SlotTaken):
        make(start=755)
    b = make(start=790, phone="5550102222")
    with pytest.raises(Conflict):
        blocks_db.create_block(day=TUE, claims=[790], start=790, end=825, note="", whole=False)
    assert b


def test_availability_ranges_do_not_leak_between_days():
    make(day=TUE)
    make(start=660, day=date(2026, 10, 15))
    out = schedule_db.availability(TUE, date(2026, 10, 15), shop.DEFAULT_SETTINGS)
    assert out["2026-10-13"]["busy"] == [720] and out["2026-10-14"]["busy"] == [] and out["2026-10-15"]["busy"] == [660]


def test_concurrent_attempts_only_one_wins(atomic_transactions):
    # Six people try for the same time at the same moment: the database must pick exactly one.
    results = []
    gate = threading.Barrier(6)

    def attempt(i):
        gate.wait()
        try:
            make(phone=f"555010{i:04d}")
            results.append("won")
        except SlotTaken:
            results.append("lost")

    threads = [threading.Thread(target=attempt, args=(i,)) for i in range(6)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results.count("won") == 1 and results.count("lost") == 5
    assert len(schedule_db.day_schedule(TUE)[0]) == 1


def test_stale_availability_cannot_cause_a_double_booking():
    """Simulates two customers who both saw the time as free: only the first write succeeds."""
    assert 720 not in claims()
    make(phone="5550101111")
    with pytest.raises(SlotTaken):
        make(phone="5550102222")


def test_login_counter_expires_by_time():
    for _ in range(5):
        login_attempts.record_login_failure("1.2.3.4", now=1000)
    assert login_attempts.login_locked("1.2.3.4", now=1500)
    assert not login_attempts.login_locked("1.2.3.4", now=1000 + login_attempts.LOGIN_WINDOW_SECONDS + 1)
    assert not login_attempts.login_locked("5.6.7.8", now=1500)
    login_attempts.record_login_failure("1.2.3.4", now=1000 + login_attempts.LOGIN_WINDOW_SECONDS + 5)  # starts a fresh window
    assert not login_attempts.login_locked("1.2.3.4", now=2000 + login_attempts.LOGIN_WINDOW_SECONDS)
VICBLESS_EOF
cat > "$STAGE/27" <<'VICBLESS_EOF'
"""Vic moving a booking to another time: PATCH /api/admin/bookings/{id}."""

from datetime import date, datetime

import pytest

from app.core.errors import InvalidSlot, SlotTaken
from app.database import bookings as bookings_db
from app.domain import shop
from tests.helpers.api import book, busy, schedule_of
from tests.helpers.builders import make_booking, taken_blocks, taken_units
from tests.helpers.constants import NOW, SATURDAY, TUESDAY, WEDNESDAY

THURSDAY = "2026-10-15"  # open 11:00 am to 7:00 pm
FAR_TUESDAY = "2026-11-10"  # four weeks out: beyond what customers can book, fine for Vic


def move(client, auth, booking_id, dateKey=THURSDAY, start=660):
    return client.patch(f"/api/admin/bookings/{booking_id}", json={"dateKey": dateKey, "start": start}, headers=auth)


def first_booking(client, auth, day=TUESDAY):
    return schedule_of(client, auth, day)["items"][0]


def test_move_changes_day_and_time_and_keeps_the_customers_code(client, auth):
    book(client, email="m@example.com")
    old = first_booking(client, auth)

    r = move(client, auth, old["id"])
    assert r.status_code == 200, r.text
    new = r.json()
    assert (new["dateKey"], new["start"]) == (THURSDAY, 660)
    assert new["code"] == old["code"] and new["name"] == old["name"] and new["notes"] == old["notes"]
    assert new["id"] != old["id"]  # the id contains the day and time, so a moved booking gets a new one

    assert schedule_of(client, auth, TUESDAY)["items"] == []
    assert schedule_of(client, auth, THURSDAY)["items"][0]["id"] == new["id"]


def test_move_frees_the_old_time_and_takes_the_new_one(client, auth):
    book(client)
    old = first_booking(client, auth)
    assert busy(client, TUESDAY) == [720]
    move(client, auth, old["id"])
    assert busy(client, TUESDAY) == []
    assert busy(client, THURSDAY) == [660]
    # the freed time can be booked by someone else straight away
    assert book(client, name="New Person", phone="5550107777").status_code == 201


def test_the_old_id_stops_working_and_the_new_id_can_be_cancelled(client, auth):
    book(client)
    old = first_booking(client, auth)
    new = move(client, auth, old["id"]).json()
    assert client.delete(f"/api/admin/bookings/{old['id']}", headers=auth).status_code == 404
    assert move(client, auth, old["id"]).status_code == 404
    assert client.delete(f"/api/admin/bookings/{new['id']}", headers=auth).status_code == 200
    assert busy(client, THURSDAY) == []


def test_vic_can_move_further_ahead_than_customers_can_book(client, auth):
    book(client)
    old = first_booking(client, auth)
    assert book(client, dateKey=FAR_TUESDAY, name="Late Comer", phone="5550108888").status_code in (409, 422)  # customers can't
    r = move(client, auth, old["id"], FAR_TUESDAY, 720)
    assert r.status_code == 200 and r.json()["dateKey"] == FAR_TUESDAY


def test_moving_onto_a_taken_time_is_refused_and_nothing_changes(client, auth):
    book(client)
    book(client, dateKey=THURSDAY, start=660, name="Other Person", phone="5550106666")
    mine = first_booking(client, auth)
    r = move(client, auth, mine["id"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "slot_taken"
    assert first_booking(client, auth)["id"] == mine["id"]  # still exactly where it was
    assert busy(client, TUESDAY) == [720]
    assert busy(client, THURSDAY) == [660]


def test_moving_into_time_vic_blocked_off_is_refused(client, auth):
    book(client)
    client.post("/api/admin/blocks", json={"dateKey": THURSDAY, "start": 660, "end": 695, "note": "Lunch"}, headers=auth)
    mine = first_booking(client, auth)
    assert move(client, auth, mine["id"]).status_code == 409
    assert busy(client, TUESDAY) == [720]


def test_moving_onto_a_whole_day_off_is_refused(client, auth):
    book(client)
    client.post("/api/admin/blocks", json={"dateKey": THURSDAY, "whole": True}, headers=auth)
    assert move(client, auth, first_booking(client, auth)["id"]).status_code == 409


@pytest.mark.parametrize(
    "day, start",
    [
        (WEDNESDAY, 720),  # shop closed
        (THURSDAY, 665),  # not on the 35 minute grid
        (THURSDAY, 600),  # before opening
        (THURSDAY, 1130),  # would run past closing
        ("2026-10-11", 720),  # in the past
        ("2027-11-01", 720),  # more than a year ahead
        (SATURDAY, 725),  # Saturday's second window starts at 12:35, so 12:05 is off the grid
    ],
)
def test_moving_to_a_time_that_is_not_real_is_422(client, auth, day, start):
    book(client)
    r = move(client, auth, first_booking(client, auth)["id"], day, start)
    assert r.status_code == 422, r.text
    assert busy(client, TUESDAY) == [720]


def test_moving_to_the_same_time_is_422(client, auth):
    book(client)
    r = move(client, auth, first_booking(client, auth)["id"], TUESDAY, 720)
    assert r.status_code == 422 and "already at that time" in r.json()["error"]["message"]


def test_bad_bodies_are_422_and_unknown_ids_are_404(client, auth):
    book(client)
    booking_id = first_booking(client, auth)["id"]
    for body in ({}, {"dateKey": THURSDAY}, {"dateKey": "nope", "start": 660}, {"dateKey": THURSDAY, "start": "660"}):
        assert client.patch(f"/api/admin/bookings/{booking_id}", json=body, headers=auth).status_code == 422, body
    assert move(client, auth, "2026-10-13.1300.abcdef12").status_code == 404
    assert move(client, auth, "nonsense").status_code == 404


def test_moving_needs_vic_to_be_signed_in(client, admin_setup):
    r = client.patch("/api/admin/bookings/2026-10-13.1200.abcdef12", json={"dateKey": THURSDAY, "start": 660})
    assert r.status_code == 401


def test_the_customer_is_emailed_the_old_and_new_time(client, auth, sent):
    book(client, email="m@example.com")
    sent.clear()
    move(client, auth, first_booking(client, auth)["id"])
    [mail] = sent
    assert mail.to == "m@example.com" and "moved" in mail.subject.lower()
    assert "Thursday, October 15 at 11:00 am" in mail.text and "Tuesday, October 13 at 12:00 pm" in mail.text
    assert "VB-" in mail.text


def test_no_email_is_sent_when_the_customer_left_none(client, auth, sent):
    book(client)
    sent.clear()
    move(client, auth, first_booking(client, auth)["id"])
    assert sent == []


def test_a_failed_email_does_not_undo_the_move(client, auth, sent, monkeypatch):
    book(client, email="m@example.com")

    from app.services import notifications

    class Broken:
        def send(self, message):
            raise RuntimeError("email provider down")

    monkeypatch.setattr(notifications, "get_sender", lambda: Broken())
    r = move(client, auth, first_booking(client, auth)["id"])
    assert r.status_code == 200 and busy(client, THURSDAY) == [660]


def test_moving_does_not_change_how_many_upcoming_bookings_a_phone_has(client, auth):
    for start in (720, 755, 790):
        assert book(client, start=start).status_code == 201
    assert book(client, start=825).status_code == 429  # the cap of 3
    move(client, auth, schedule_of(client, auth)["items"][0]["id"])
    assert book(client, start=825).status_code == 429  # still 3, not 2 and not 4


# --- the database layer: long bookings that overlap their own old time ------------------------------------


def test_a_long_booking_moved_by_one_block_keeps_the_shared_block():
    booking = make_booking(start=720, minutes=70)  # holds 12:00 and 12:35
    assert taken_blocks() == [720, 755] and len(taken_units()) == 14  # 70 minutes = fourteen 5 minute units
    moved = bookings_db.move_booking(booking, day=booking.day, start=755, minutes=70)  # now 12:35 to 1:45
    assert taken_blocks() == [755, 790] and taken_units() == list(range(755, 825, 5))
    assert moved.id != booking.id and moved.code == booking.code
    assert bookings_db.get_booking(moved.id) is not None and bookings_db.get_booking(booking.id) is None
    # the shared block now belongs to the NEW booking, so cancelling it releases everything (a stale owner would block this)
    bookings_db.cancel_booking(moved.id)
    assert taken_blocks() == []


def test_a_refused_move_changes_nothing_even_when_the_blocks_overlap_the_old_time():
    booking = make_booking(start=720, minutes=70)
    make_booking(start=790, phone="5550102222")  # someone else holds 1:10 pm
    with pytest.raises(SlotTaken):
        bookings_db.move_booking(booking, day=booking.day, start=755, minutes=70)  # would run into 1:10 pm
    assert taken_blocks() == [720, 755, 790]
    assert bookings_db.get_booking(booking.id) is not None


def test_moving_a_booking_that_was_just_cancelled_is_not_found():
    from app.core.errors import NotFound

    booking = make_booking()
    bookings_db.cancel_booking(booking.id)
    with pytest.raises(NotFound):
        bookings_db.move_booking(booking, day=booking.day, start=755, minutes=35)
    assert taken_blocks() == []  # the move must not have created anything


def test_moved_items_carry_the_new_ttl_and_phone_index_keys():
    from tests.helpers.aws import raw_table

    booking = make_booking(phone="5550101234")
    moved = bookings_db.move_booking(booking, day=date(2026, 10, 15), start=660, minutes=35)
    items = [i for i in raw_table().scan()["Items"] if i["sk"].split("#")[1] == "BOOKING"]
    assert [i["id"] for i in items] == [moved.id]
    assert items[0]["gsi1sk"] == "2026-10-15#1100" and items[0]["gsi1pk"] == "PHONE#5550101234"
    assert int(items[0]["expiresAt"]) > int(datetime(2026, 10, 15).timestamp())


# --- the shop rule on its own, with a clock we control ----------------------------------------------------


def test_a_time_earlier_today_has_passed_but_a_time_a_few_minutes_away_is_fine_for_vic():
    now = datetime(2026, 10, 12, 14, 50, tzinfo=shop.TIMEZONE)  # a Monday; the grid is 12:00, 12:35 ... 2:55 pm, 3:30 pm
    today = date(2026, 10, 12)
    shop.check_movable(today, 14 * 60 + 55, 35, now)  # 5 minutes away: customers need 30 minutes notice, Vic doesn't
    with pytest.raises(InvalidSlot):
        shop.check_movable(today, 14 * 60 + 20, 35, now)  # already over
    with pytest.raises(InvalidSlot):
        shop.check_movable(today, 14 * 60 + 55, 35, now.replace(minute=55))  # starting right now counts as passed


def test_the_year_ahead_limit_is_inclusive():
    from datetime import timedelta

    last = NOW.date() + timedelta(days=shop.MAX_BLOCK_DAYS_AHEAD)
    day_ok = last
    while not shop.is_open(day_ok):
        day_ok -= timedelta(days=1)
    shop.check_movable(day_ok, shop.grid_starts(day_ok, 35)[0], 35, NOW)
    day_bad = last + timedelta(days=1)
    while not shop.is_open(day_bad):
        day_bad += timedelta(days=1)
    with pytest.raises(InvalidSlot):
        shop.check_movable(day_bad, shop.grid_starts(day_bad, 35)[0], 35, NOW)
VICBLESS_EOF
cat > "$STAGE/28" <<'VICBLESS_EOF'
"""The helper script Vic's password is set up with. It runs once, by hand, so a break would only show up on launch day."""

import re
import runpy
import shlex
import sys
from pathlib import Path

import pytest

from app.core import security

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hash_password.py"


def run_script(monkeypatch, capsys, answers, env="dev"):
    """Runs hash_password.py as if typed at a terminal, answering its two password prompts."""
    typed = iter(answers)
    monkeypatch.setattr("getpass.getpass", lambda prompt="": next(typed))
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--env", env])
    code = None
    try:
        runpy.run_path(str(SCRIPT), run_name="__main__")
    except SystemExit as done:
        code = done.code
    return code, capsys.readouterr()


def stored_values(output):
    """{'pepper': ..., 'jwt-secret': ..., 'admin-password-hash': ...} read back out of the printed aws commands."""
    found = {}
    for line in output.splitlines():
        m = re.search(r"--name /vicbless/dev/(pepper|jwt-secret|admin-password-hash) .*--value=(.*)$", line)
        if m:
            found[m.group(1)] = shlex.split(m.group(2))[0]
    return found


def test_the_printed_hash_logs_vic_in_with_the_printed_pepper(monkeypatch, capsys):
    code, out = run_script(monkeypatch, capsys, ["a long dashboard password", "a long dashboard password"])
    assert code == 0, out.err
    values = stored_values(out.out)
    assert set(values) == {"pepper", "jwt-secret", "admin-password-hash"}
    assert security.verify_password("a long dashboard password", values["admin-password-hash"], values["pepper"])
    assert not security.verify_password("a different password!", values["admin-password-hash"], values["pepper"])
    assert values["admin-password-hash"].startswith("pbkdf2_sha256$600000$")  # the real strength, not the fast test one


def test_every_run_makes_a_fresh_pepper_and_session_secret(monkeypatch, capsys):
    _, first = run_script(monkeypatch, capsys, ["a long dashboard password"] * 2)
    _, second = run_script(monkeypatch, capsys, ["a long dashboard password"] * 2)
    a, b = stored_values(first.out), stored_values(second.out)
    assert a["pepper"] != b["pepper"] and a["jwt-secret"] != b["jwt-secret"]


@pytest.mark.parametrize("answers", [["short", "short"], ["a long dashboard password", "a different long password"]])
def test_a_short_or_mistyped_password_prints_nothing_to_store(monkeypatch, capsys, answers):
    code, out = run_script(monkeypatch, capsys, answers)
    assert code == 1 and "put-parameter" not in out.out


# --- migrate_unit_claims.py (the one-time upgrade of bookings made before the settings update) -------------

from datetime import date  # noqa: E402

TUESDAY_DATE = date(2026, 10, 13)
MIGRATE = Path(__file__).resolve().parents[1] / "scripts" / "migrate_unit_claims.py"


def load_migrate():
    import importlib.util

    spec = importlib.util.spec_from_file_location("migrate_unit_claims", MIGRATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def old_style_booking(day, start, suffix="aaaa1111"):
    """Writes a booking exactly as the OLD site did: one claim per 35 minute block, and no `units` marker."""
    from app.database import keys as k
    from tests.helpers.aws import raw_table

    booking_id = f"{day.isoformat()}.{start // 60:02d}{start % 60:02d}.{suffix}"
    t = raw_table()
    t.put_item(Item={
        "pk": k.PK, "sk": k.booking_sk(day, start, booking_id), "kind": "booking", "id": booking_id, "code": "OLD123",
        "date": day.isoformat(), "start": start, "minutes": 35, "serviceId": "mens-cut", "name": "Old Timer",
        "phone": "5550101111", "blocks": [start], "expiresAt": k.expires(day),
    })  # fmt: skip
    t.put_item(Item={"pk": k.PK, "sk": k.claim_sk(day, start), "kind": "claim", "ref": booking_id, "expiresAt": k.expires(day)})
    return booking_id


def test_migration_adds_the_missing_units_and_is_safe_to_repeat():
    from tests.helpers.aws import raw_table
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    old_style_booking(TUESDAY_DATE, 755)
    assert len(taken_units(TUESDAY_DATE)) == 1

    assert migrate.migrate(apply=False) == {"upgraded": 1, "conflicts": 0, "already_ok": 0}
    assert len(taken_units(TUESDAY_DATE)) == 1  # the dry run changed nothing

    assert migrate.migrate(apply=True)["upgraded"] == 1
    assert len(taken_units(TUESDAY_DATE)) == 7  # 35 minutes = seven 5 minute units
    assert migrate.migrate(apply=True) == {"upgraded": 0, "conflicts": 0, "already_ok": 0}  # second run: nothing left
    item = [i for i in raw_table().scan()["Items"] if i.get("kind") == "booking"][0]
    assert item["units"] is True and len(item["blocks"]) == 7


def test_after_migration_a_cancel_releases_every_unit(client, auth):
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    booking_id = old_style_booking(TUESDAY_DATE, 755)
    migrate.migrate(apply=True)
    assert client.delete(f"/api/admin/bookings/{booking_id}", headers=auth).status_code == 200
    assert len(taken_units(TUESDAY_DATE)) == 0


def test_an_old_block_off_is_upgraded_to_cover_its_whole_range():
    from app.database import keys as k
    from tests.helpers.aws import raw_table
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    day = TUESDAY_DATE
    t = raw_table()
    t.put_item(Item={"pk": k.PK, "sk": k.block_sk(day, 720, "blk"), "kind": "block", "id": "blk", "date": day.isoformat(),
                     "start": 720, "end": 790, "note": "", "whole": False, "blocks": [720, 755], "expiresAt": k.expires(day)})  # fmt: skip
    for u in (720, 755):
        t.put_item(Item={"pk": k.PK, "sk": k.claim_sk(day, u), "kind": "claim", "ref": "blk", "expiresAt": k.expires(day)})
    migrate.migrate(apply=True)
    assert len(taken_units(day)) == 14  # 12:00 to 1:10, in 5 minute units


def test_a_unit_held_by_something_else_is_reported_and_left_alone(capsys):
    from app.database import keys as k
    from tests.helpers.aws import raw_table

    migrate = load_migrate()
    old_style_booking(TUESDAY_DATE, 755)
    raw_table().put_item(Item={"pk": k.PK, "sk": k.claim_sk(TUESDAY_DATE, 765), "kind": "claim", "ref": "someone-else", "expiresAt": 1})
    assert migrate.migrate(apply=True) == {"upgraded": 0, "conflicts": 1, "already_ok": 0}
    assert "CONFLICT" in capsys.readouterr().err


def test_the_script_asks_for_an_environment(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", [str(MIGRATE)])
    with pytest.raises(SystemExit) as stop:
        runpy.run_path(str(MIGRATE), run_name="__main__")
    assert stop.value.code == 2
VICBLESS_EOF
cat > "$STAGE/29" <<'VICBLESS_EOF'
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
    assert client.get("/api/settings").json() == saved  # customers see the same thing at once


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
cat > "$STAGE/30" <<'VICBLESS_EOF'
from datetime import date, datetime

import pytest

from app.core.errors import InvalidSlot, SlotUnavailable
from app.domain import shop
from tests.helpers.constants import NOW

TUE = date(2026, 10, 13)
WED = date(2026, 10, 14)
SAT = date(2026, 10, 17)
SUN = date(2026, 10, 18)
at = shop.at


def test_weekday_mapping():
    # 2026-10-12 is a Monday; each day of that week
    expected_open = {12: True, 13: True, 14: False, 15: True, 16: True, 17: True, 18: False}
    for day, is_open in expected_open.items():
        assert shop.is_open(date(2026, 10, day)) is is_open


def test_tuesday_grid_runs_from_opening_in_35_minute_steps():
    grid = shop.grid_starts(TUE, 35)
    assert grid[0] == at(12) and grid[1] == at(12, 35)
    assert len(grid) == 10
    assert grid[-1] + 35 <= at(18)


def test_thursday_friday_have_13_blocks():
    assert len(shop.grid_starts(date(2026, 10, 15), 35)) == 13
    assert len(shop.grid_starts(date(2026, 10, 16), 35)) == 13


def test_saturday_has_two_windows_and_a_gap():
    grid = shop.grid_starts(SAT, 35)
    assert grid[0] == at(9) and at(12, 35) in grid
    assert at(12) not in grid
    for s in grid:
        assert (at(9) <= s and s + 35 <= at(12)) or (at(12, 35) <= s and s + 35 <= at(17))


def test_closed_days_have_no_grid():
    assert shop.grid_starts(WED, 35) == [] and shop.grid_starts(SUN, 35) == []


def test_the_grid_follows_the_slot_length():
    # Monday and Tuesday at 45 minutes: 12:00, 12:45, 1:30 ... eight appointments, the last ending exactly at 6:00 pm
    grid = shop.grid_starts(TUE, 45)
    assert grid == [at(12) + 45 * k for k in range(8)] and grid[-1] + 45 == at(18)
    assert len(shop.grid_starts(TUE, 25)) == 14 and len(shop.grid_starts(TUE, 120)) == 3


def test_the_real_defaults_make_monday_and_tuesday_45_minutes():
    from tests.fixtures.settings import REAL_DEFAULTS

    mon, tue = date(2026, 10, 12), date(2026, 10, 13)
    assert REAL_DEFAULTS.slot_for(mon) == 45 and REAL_DEFAULTS.slot_for(tue) == 45
    for day in (14, 15, 16, 17, 18):
        assert REAL_DEFAULTS.slot_for(date(2026, 10, day)) == 35  # every other day is unchanged
    assert [s.id for s in REAL_DEFAULTS.services] == ["mens-cut", "mens-design", "mens-beard-eyebrow", "buzz-beard", "kids-design"]
    assert REAL_DEFAULTS.service("mens-cut").price == 55 and REAL_DEFAULTS.service("nope") is None


def test_occupied_units_are_five_minute_steps():
    assert shop.occupied_starts(at(12), 45) == [at(12) + 5 * k for k in range(9)]
    assert shop.occupied_starts(at(12, 35), 35) == [at(12, 35) + 5 * k for k in range(7)]
    # two appointments share a unit only if they really overlap
    assert not set(shop.occupied_starts(at(12), 35)) & set(shop.occupied_starts(at(12, 35), 35))
    assert set(shop.occupied_starts(at(12), 45)) & set(shop.occupied_starts(at(12, 35), 35))


def test_fits_matches_grid_and_closing():
    assert shop.fits(TUE, at(12), 35)
    assert not shop.fits(TUE, at(12, 10), 35)  # off the grid
    assert not shop.fits(TUE, at(17, 50), 35)  # would run past closing
    assert not shop.fits(WED, at(12), 35)
    assert not shop.fits(SAT, at(12), 35)  # inside Saturday's gap
    assert shop.fits(TUE, at(12, 45), 45) and not shop.fits(TUE, at(12, 35), 45)  # each day's slot length is its own grid


def test_an_appointment_must_stay_inside_one_window():
    assert shop.fits(SAT, at(11, 15), 45)  # 9:00, 9:45, 10:30, 11:15: the last one ends at noon sharp
    assert not shop.fits(SAT, at(11, 30), 50)  # a 50 minute appointment there would cross noon
    assert shop.fits(SAT, at(11, 20), 35)  # the last 35 minute start in the morning ends at 11:55, five minutes before noon


@pytest.mark.parametrize(
    "when,start,error",
    [
        (date(2026, 10, 13), at(12), None),
        (date(2026, 10, 14), at(12), InvalidSlot),  # closed Wednesday
        (date(2026, 10, 13), at(12, 5), InvalidSlot),  # off grid
        (date(2026, 10, 10), at(9), SlotUnavailable),  # past Saturday
        (date(2026, 10, 26), at(12), SlotUnavailable),  # 14 days ahead is outside 0..13
        (date(2026, 10, 25), at(12), None),  # last day in the window (a Sunday... closed)
    ],
)
def test_check_bookable(when, start, error):
    if when == date(2026, 10, 25):
        error = InvalidSlot  # Sunday is closed, so structure fails first
    if error is None:
        shop.check_bookable(when, start, 35, NOW)
    else:
        with pytest.raises(error):
            shop.check_bookable(when, start, 35, NOW)


def test_last_bookable_day_is_13_days_out():
    # Monday 2026-10-12 + 13 = Sunday the 25th (closed); Saturday the 24th is inside the window
    shop.check_bookable(date(2026, 10, 24), at(9), 35, NOW)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 26), at(12), 35, NOW)


def test_lead_time_today():
    now = datetime(2026, 10, 12, 12, 5, tzinfo=shop.TIMEZONE)  # Monday 12:05
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12), 35, now)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12, 35), 35, now)  # 12:35 is exactly now + 30, so too soon
    shop.check_bookable(date(2026, 10, 12), at(13, 10), 35, now)  # 13:10 is fine


def test_today_uses_shop_timezone_not_utc():
    # 11 pm Monday in New York is already Tuesday in UTC; "today" must still be Monday
    late = datetime(2026, 10, 12, 23, 0, tzinfo=shop.TIMEZONE)
    assert shop.today(late) == date(2026, 10, 12)
    utc = late.astimezone(__import__("datetime").timezone.utc)
    assert shop.today(utc) == date(2026, 10, 12)


def test_dst_day_still_gives_normal_minutes():
    # Daylight saving ends 2026-11-01 (a Sunday); Monday after is a normal day
    now = datetime(2026, 11, 2, 9, 0, tzinfo=shop.TIMEZONE)
    shop.check_bookable(date(2026, 11, 2), at(12), 35, now)


def test_block_range_and_whole_day():
    assert shop.block_units(TUE, at(12), at(12, 35) + 35) == list(range(at(12), at(12, 35) + 35, 5))
    assert shop.block_units(TUE, at(12), at(12)) == []
    assert shop.block_units(TUE, at(11), at(12, 10)) == [at(12), at(12, 5)]  # only the part inside opening hours
    assert shop.block_units(TUE, at(12, 3), at(12, 8)) == [at(12), at(12, 5)]  # widened to whole 5 minute units
    with pytest.raises(InvalidSlot):
        shop.check_blockable(WED, NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2026, 10, 9), NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2027, 10, 20), NOW)
    shop.check_blockable(date(2026, 10, 13), NOW)


def test_labels():
    assert shop.label(at(12, 35)) == "12:35 pm"
    assert shop.label(at(9)) == "9:00 am"
    assert shop.hhmm(at(7, 20)) == "0720"


def test_a_whole_saturday_skips_the_lunch_gap():
    units = shop.block_units(SAT, at(9), at(17))
    assert at(12) not in units and at(12, 30) not in units and at(12, 35) in units
    assert len(units) == (at(12) - at(9)) // 5 + (at(17) - at(12, 35)) // 5


def test_busy_slots_are_the_grid_slots_that_overlap_something_taken():
    # a 35 minute booking at 12:35 (units 12:35-13:05) sits across two 45 minute slots (12:00-12:45 and 12:45-13:30)
    taken = set(shop.occupied_starts(at(12, 35), 35))
    assert shop.busy_slots(TUE, 45, taken) == [at(12), at(12, 45)]
    assert shop.busy_slots(TUE, 35, taken) == [at(12, 35)]
    assert shop.busy_slots(TUE, 45, set()) == []
    assert shop.busy_slots(WED, 45, taken) == []  # a closed day has no grid
VICBLESS_EOF
cat > "$STAGE/31" <<'VICBLESS_EOF'
import { useEffect, useState } from 'react'
import './admin.css'
import SiteMenu from '../components/SiteMenu.jsx'
import { copyrightLine } from '../lib/format.js'
import Greeting from './Greeting.jsx'
import Schedule from './Schedule.jsx'
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
  const [view, setView] = useState('schedule') // 'schedule' | 'settings' (Menu > Settings > Shop settings)

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
    <main className="admin">
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

      {view === 'settings' ? <SettingsPanel onClose={() => setView('schedule')} /> : <Schedule />}

      <footer className="admin-foot">{copyrightLine()}</footer>
    </main>
  )
}
VICBLESS_EOF
cat > "$STAGE/32" <<'VICBLESS_EOF'
import { useMemo, useState } from 'react'
import { HOURS } from '../config.js'
import { fmtTime, fromKey } from '../lib/availability.js'
import { dayGrid, describeRange, findConflicts, rangeFromChoice, wholeDayRange } from './blocks.js'
import { slotFor } from '../lib/shopSettings.js'
import { useShopSettings } from '../lib/useShopSettings.js'
import { addBlock } from './adminApi.js'

// "Block off time": part of the day or the whole day, with an optional note (Lunch, Phone booking...).
// It will not let Vic block over a booking or over time that is already blocked, and says which.
export default function BlockOff({ dateKey, items, blocks, onSaved, onClose }) {
  const shop = useShopSettings()
  const date = useMemo(() => fromKey(dateKey), [dateKey])
  const SLOT_MINUTES = slotFor(shop, date) // how long an appointment is on this day
  const grid = useMemo(() => dayGrid({ date, hours: HOURS, slotMinutes: SLOT_MINUTES }), [date, SLOT_MINUTES])

  const [mode, setMode] = useState('part')
  const [from, setFrom] = useState(grid[0])
  const [until, setUntil] = useState(grid[0])
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const choice =
    mode === 'whole'
      ? wholeDayRange({ date, hours: HOURS })
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
cat > "$STAGE/33" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS } from '../config.js'
import { getAvailability } from '../lib/api.js'
import { fmtTime, fromKey, keyOf, slotStarts } from '../lib/availability.js'
import { findService, slotFor } from '../lib/shopSettings.js'
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
    return moveOptions({
      date,
      hours: HOURS,
      slotMinutes: slot,
      minutes: slot,
      busy: day.busy,
      own: sameDay ? ownStarts(item, slot, slotStarts(date, HOURS, slot)) : [],
      current: sameDay ? item.start : null,
      nowMinutes: dateKey === keyOf(now) ? now.getHours() * 60 + now.getMinutes() : null,
    })
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
cat > "$STAGE/34" <<'VICBLESS_EOF'
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
  const confirming = ctl.isCancelling(item)
  const moving = ctl.isMoving(item)
  return (
    <article className="admin-card">
      <h3>
        {item.name}
        {item.source === 'sample' && <span className="admin-sample-badge">sample</span>}
      </h3>
      <p className="admin-meta">
        {serviceName}, {item.minutes} min
      </p>
      {item.phone &&
        (tel ? (
          <a className="phone-link" href={tel}>
            {formatPhone(item.phone)}
          </a>
        ) : (
          <span>{formatPhone(item.phone)}</span>
        ))}
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
          Cancel {item.name}'s {fmtTime(item.start)} {serviceName}? The time opens up for other customers. If they left an
          email, they are told it was cancelled.
        </ConfirmBox>
      )}

      {moving && <MoveBooking item={item} onClose={ctl.closeMove} onMoved={ctl.doMoved} />}

      {!confirming && !moving && (
        <div className="admin-card-actions">
          <button type="button" className="admin-box-btn" onClick={() => ctl.askMove(item)} aria-label={`Change ${item.name}'s ${fmtTime(item.start)} booking time`}>
            Change time
          </button>
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
    } catch {
      setActionError('That did not work. Nothing was changed. Try again.')
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
cat > "$STAGE/35" <<'VICBLESS_EOF'
import { useEffect, useId, useMemo, useState } from 'react'
import { HOURS, MAX_SERVICES, SLOT_MAX, SLOT_MIN, SLOT_STEP } from '../config.js'
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
                    Up
                  </button>
                  <button type="button" className="admin-box-btn" disabled={i === draft.services.length - 1} onClick={() => move(i, 1)} aria-label={`Move ${s.name || 'this service'} down`}>
                    Down
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
cat > "$STAGE/36" <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > "$STAGE/37" <<'VICBLESS_EOF'
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
export const removeBlock = (id) => layer.removeBlock(id)
export { SIGNED_OUT_EVENT } from './realAdminApi.js'
VICBLESS_EOF
cat > "$STAGE/38" <<'VICBLESS_EOF'
import { fmtTime, slotStarts } from '../lib/availability.js'

// The rules behind "Block off time". Pure, so they are easy to test.
// A block is { dateKey, start, end, note, whole }: it covers every time block that starts at or
// after `start` and before `end` (minutes after midnight).

// The day's time blocks in order, across all opening windows (so Saturday's break is not in it).
export function dayGrid({ date, hours, slotMinutes = 35 }) {
  return slotStarts(date, hours, slotMinutes)
}

// Turns "from this block until the end of that block" into a range, or says what is wrong.
export function rangeFromChoice({ grid, fromStart, untilStart, slotMinutes = 35 }) {
  const a = grid.indexOf(fromStart)
  const b = grid.indexOf(untilStart)
  if (a === -1 || b === -1) return { error: 'Pick a start and an end.' }
  if (b < a) return { error: 'The end has to be after the start.' }
  return { start: grid[a], end: grid[b] + slotMinutes }
}

// From opening to closing, for a day off. null when the shop is closed that day.
export function wholeDayRange({ date, hours }) {
  const windows = hours[date.getDay()]
  if (!windows) return null
  return { start: windows[0][0], end: windows[windows.length - 1][1] }
}

export function startsInRange(grid, { start, end }) {
  return grid.filter((s) => s >= start && s < end)
}

// What a new block would run into: bookings inside it, and blocked time that is already there.
// Anything that shares even a minute with the range counts, whatever appointment length it was made with
// (a booking made on an older 35 minute schedule can sit across the edge of today's 45 minute times).
export function findConflicts({ range, items, blocks }) {
  const touches = (start, end) => start < range.end && range.start < end
  return {
    bookings: items.filter((item) => touches(item.start, item.start + item.minutes)),
    blocks: blocks.filter((b) => touches(b.start, b.end)),
  }
}

export const describeRange = (start, end) => `${fmtTime(start)} to ${fmtTime(end)}`
VICBLESS_EOF
cat > "$STAGE/39" <<'VICBLESS_EOF'
import { describe, it, expect } from 'vitest'
import { dayGrid, describeRange, findConflicts, rangeFromChoice, startsInRange, wholeDayRange } from './blocks.js'

const at = (h, m = 0) => h * 60 + m
const HOURS = {
  0: null,
  1: [[at(12), at(18)]],
  2: [[at(12), at(18)]],
  3: null,
  4: [[at(11), at(19)]],
  5: [[at(11), at(19)]],
  6: [[at(9), at(12)], [at(12, 35), at(17)]],
}
const TUESDAY = new Date(2026, 9, 6)
const WEDNESDAY = new Date(2026, 9, 7)
const SATURDAY = new Date(2026, 9, 10)
const grid = (date) => dayGrid({ date, hours: HOURS })

describe('dayGrid', () => {
  it('lists the day in order, with no break on Saturday and nothing on a closed day', () => {
    expect(grid(TUESDAY)).toHaveLength(10)
    expect(grid(TUESDAY)[0]).toBe(at(12))
    const sat = grid(SATURDAY)
    expect(sat).toHaveLength(12)
    expect(sat).not.toContain(at(12))
    expect([...sat].sort((a, b) => a - b)).toEqual(sat)
    expect(grid(WEDNESDAY)).toEqual([])
  })
})

describe('rangeFromChoice', () => {
  const g = grid(TUESDAY)

  it('one block is from its start to its end', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 35), untilStart: at(12, 35) })).toEqual({ start: at(12, 35), end: at(13, 10) })
  })

  it('several blocks run from the first start to the last end', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 35), untilStart: at(13, 45) })).toEqual({ start: at(12, 35), end: at(14, 20) })
  })

  it('an end before the start is refused with a clear message', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(14, 20), untilStart: at(12) }).error).toBe('The end has to be after the start.')
  })

  it('a time that is not on the grid is refused', () => {
    expect(rangeFromChoice({ grid: g, fromStart: at(12, 5), untilStart: at(12, 35) }).error).toBeTruthy()
    expect(rangeFromChoice({ grid: [], fromStart: 1, untilStart: 1 }).error).toBeTruthy()
  })
})

describe('wholeDayRange', () => {
  it('is opening to closing', () => {
    expect(wholeDayRange({ date: TUESDAY, hours: HOURS })).toEqual({ start: at(12), end: at(18) })
  })
  it('covers both windows on Saturday', () => {
    expect(wholeDayRange({ date: SATURDAY, hours: HOURS })).toEqual({ start: at(9), end: at(17) })
  })
  it('is null when closed', () => {
    expect(wholeDayRange({ date: WEDNESDAY, hours: HOURS })).toBeNull()
  })
  it('covers every block of the day', () => {
    for (const date of [TUESDAY, SATURDAY]) {
      const g = grid(date)
      expect(startsInRange(g, wholeDayRange({ date, hours: HOURS }))).toEqual(g)
    }
  })
})

describe('findConflicts', () => {
  const g = grid(TUESDAY)
  const booking = (start, minutes = 35, name = 'A') => ({ start, minutes, name })
  const none = { bookings: [], blocks: [] }

  it('finds nothing on an empty day', () => {
    expect(findConflicts({ range: { start: at(12), end: at(14) }, grid: g, items: [], blocks: [] })).toEqual(none)
  })

  it('finds a booking inside the range, and ignores one outside it', () => {
    const inside = booking(at(12, 35), 35, 'Inside'), outside = booking(at(16, 40), 35, 'Outside')
    const c = findConflicts({ range: { start: at(12), end: at(14) }, grid: g, items: [inside, outside], blocks: [] })
    expect(c.bookings).toEqual([inside])
  })

  it('the edges are exact: a booking right after the range is not a conflict, the first block is', () => {
    const range = { start: at(12), end: at(12, 35) } // exactly one block
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 35))], blocks: [] }).bookings).toEqual([])
    expect(findConflicts({ range, grid: g, items: [booking(at(12))], blocks: [] }).bookings).toHaveLength(1)
  })

  it('a longer booking that reaches into the range counts', () => {
    const long = booking(at(12), 70, 'Long') // takes two blocks
    const range = { start: at(12, 35), end: at(13, 10) }
    expect(findConflicts({ range, grid: g, items: [long], blocks: [] }).bookings).toEqual([long])
  })

  it('finds blocked time that is already there', () => {
    const existing = { id: 'b1', start: at(13, 10), end: at(14, 20) }
    const c = findConflicts({ range: { start: at(12), end: at(13, 45) }, grid: g, items: [], blocks: [existing] })
    expect(c.blocks).toEqual([existing])
    expect(findConflicts({ range: { start: at(12), end: at(13, 10) }, grid: g, items: [], blocks: [existing] }).blocks).toEqual([])
  })

  it('a day off conflicts with any booking that day', () => {
    const range = wholeDayRange({ date: TUESDAY, hours: HOURS })
    expect(findConflicts({ range, grid: g, items: [booking(at(17, 15))], blocks: [] }).bookings).toHaveLength(1)
    expect(findConflicts({ range, grid: g, items: [], blocks: [] })).toEqual(none)
  })

  it('counts a booking from another appointment length that only overlaps the edge', () => {
    const range = { start: at(12), end: at(12, 45) } // one 45 minute block
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 35), 35)], blocks: [] }).bookings).toHaveLength(1)
    expect(findConflicts({ range, grid: g, items: [booking(at(12, 45), 35)], blocks: [] }).bookings).toHaveLength(0)
  })

  it('works across Saturday\'s break', () => {
    const sat = grid(SATURDAY)
    const range = { start: at(11, 20), end: at(13, 10) } // last morning block into the afternoon
    expect(startsInRange(sat, range)).toEqual([at(11, 20), at(12, 35)])
    expect(findConflicts({ range, grid: sat, items: [booking(at(12, 35))], blocks: [] }).bookings).toHaveLength(1)
  })
})

describe('describeRange', () => {
  it('reads like a person would say it', () => {
    expect(describeRange(at(12, 35), at(14, 20))).toBe('12:35 pm to 2:20 pm')
  })
})
VICBLESS_EOF
cat > "$STAGE/40" <<'VICBLESS_EOF'
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
  })
  if (!parsed) throw new Error('Those settings are not valid.')
  const saved = toApi(parsed)
  writeShopSettings(saved)
  return saved
}
VICBLESS_EOF
cat > "$STAGE/41" <<'VICBLESS_EOF'
import { blocksFor, keyOf, startsForDay } from '../lib/availability.js'

// Vic can move a booking to any open time from today up to a year ahead (the API enforces the same).
export const MOVE_DAYS_AHEAD = 365

// The earliest and latest day the "new day" field accepts, as YYYY-MM-DD.
export function moveDateRange(today = new Date()) {
  const last = new Date(today.getFullYear(), today.getMonth(), today.getDate() + MOVE_DAYS_AHEAD)
  return { min: keyOf(today), max: keyOf(last) }
}

// The appointment starts on the day's grid that overlap this booking. They are "its own" times: moving a booking
// by a little must not be blocked by itself. `grid` is the day's appointment starts (see slotStarts).
// e.g. a 35 minute booking at 12:35, on a day that is now 45 minutes (12:00, 12:45): it overlaps both.
export function ownStarts(item, slotMinutes, grid) {
  const end = item.start + item.minutes
  return grid.filter((s) => s < end && s + slotMinutes > item.start)
}

// Every start time on the chosen day, each marked so the screen can show it properly:
//   free      can be picked
//   taken     someone else's booking, or time Vic blocked off (greyed out)
//   current   where this booking is now (when the chosen day is its own day)
//   past      already over today
// `busy` is the day's taken blocks. `own` are this booking's own blocks, which do not count against it:
// moving a long booking one block later must not be blocked by itself.
export function moveOptions({ date, hours, slotMinutes, minutes, busy = [], own = [], current = null, nowMinutes = null }) {
  const taken = new Set(busy)
  for (const s of own) taken.delete(s)
  const count = blocksFor(minutes, slotMinutes)

  return startsForDay({ date, minutes, hours, slotMinutes }).map((start) => {
    if (current !== null && start === current) return { start, state: 'current' }
    if (nowMinutes !== null && start <= nowMinutes) return { start, state: 'past' }
    for (let k = 0; k < count; k++) {
      if (taken.has(start + k * slotMinutes)) return { start, state: 'taken' }
    }
    return { start, state: 'free' }
  })
}
VICBLESS_EOF
cat > "$STAGE/42" <<'VICBLESS_EOF'
import { describe, expect, it } from 'vitest'
import { HOURS } from '../config.js'
import { moveDateRange, moveOptions, ownStarts } from './moveTimes.js'

const TUESDAY = new Date(2026, 9, 13) // Oct 13 2026: open 12:00 pm to 6:00 pm
const base = { date: TUESDAY, hours: HOURS, slotMinutes: 35, minutes: 35 }
const states = (options) => Object.fromEntries(options.map((o) => [o.start, o.state]))

describe('moveOptions', () => {
  it('lists the whole day and marks taken times', () => {
    const options = moveOptions({ ...base, busy: [755] })
    expect(options[0]).toEqual({ start: 720, state: 'free' })
    expect(states(options)[755]).toBe('taken')
    expect(options.length).toBeGreaterThan(5)
  })

  it('marks where the booking is now, on its own day', () => {
    expect(states(moveOptions({ ...base, busy: [720], own: [720], current: 720 }))[720]).toBe('current')
  })

  it('does not let a long booking block itself when it moves one block later', () => {
    // a 70 minute booking holds 12:00 and 12:35; moving it to 12:35 needs 12:35 and 1:10
    const s = states(moveOptions({ ...base, minutes: 70, busy: [720, 755], own: [720, 755], current: 720 }))
    expect(s[755]).toBe('free')
    expect(s[720]).toBe('current')
  })

  it('refuses a long booking when the second block is taken', () => {
    const s = states(moveOptions({ ...base, minutes: 70, busy: [790] }))
    expect(s[755]).toBe('taken')
    expect(s[720]).toBe('free')
  })

  it('marks times that already passed today, including the current minute', () => {
    const s = states(moveOptions({ ...base, nowMinutes: 755 }))
    expect(s[720]).toBe('past')
    expect(s[755]).toBe('past')
    expect(s[790]).toBe('free')
  })

  it('has no times on a closed day', () => {
    expect(moveOptions({ ...base, date: new Date(2026, 9, 14) })).toEqual([]) // Wednesday
  })
})

describe('ownStarts', () => {
  const grid35 = [720, 755, 790, 825]
  const grid45 = [720, 765, 810, 855]

  it('lists the grid times a booking overlaps', () => {
    expect(ownStarts({ start: 720, minutes: 35 }, 35, grid35)).toEqual([720])
    expect(ownStarts({ start: 720, minutes: 70 }, 35, grid35)).toEqual([720, 755])
    expect(ownStarts({ start: 755, minutes: 35 }, 35, grid35)).toEqual([755])
  })

  it('also finds the times of a different appointment length', () => {
    // a 35 minute booking at 12:35 to 1:10 touches both 12:00-12:45 and 12:45-1:30
    expect(ownStarts({ start: 755, minutes: 35 }, 45, grid45)).toEqual([720, 765])
  })
})

describe('moveDateRange', () => {
  it('runs from today to a year ahead', () => {
    expect(moveDateRange(new Date(2026, 9, 12))).toEqual({ min: '2026-10-12', max: '2027-10-12' })
  })
})
VICBLESS_EOF
cat > "$STAGE/43" <<'VICBLESS_EOF'
// The real admin data layer: the same functions as mockAdminApi.js, backed by the API.
//
//   signIn(password)          POST   /api/admin/login            -> a 12 hour token, kept in this browser
//   getDay(dateKey)           GET    /api/admin/schedule?date=
//   cancelBooking(item)       DELETE /api/admin/bookings/{id}    (the customer is emailed if they left an email)
//   moveBooking(item, to)     PATCH  /api/admin/bookings/{id}    (the booking comes back with a NEW id)
//   addBlock(block)           POST   /api/admin/blocks
//   removeBlock(id)           DELETE /api/admin/blocks/{id}
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
VICBLESS_EOF
cat > "$STAGE/44" <<'VICBLESS_EOF'
import EmailLink from './EmailLink.jsx'
import Reveal from './Reveal.jsx'
import { BUSINESS, CTA_TEXT, HOURS } from '../config.js'
import { fmtTime } from '../lib/availability.js'
import { priceLabel } from '../lib/format.js'
import { useShopSettings } from '../lib/useShopSettings.js'

// Monday first, the way people read a week.
const DAYS = [
  [1, 'Monday'],
  [2, 'Tuesday'],
  [3, 'Wednesday'],
  [4, 'Thursday'],
  [5, 'Friday'],
  [6, 'Saturday'],
  [0, 'Sunday'],
]

export default function ShopInfo() {
  // The services and prices are Vic's own (he edits them in his dashboard).
  const { services } = useShopSettings()
  return (
    <section className="info" aria-label="Services and hours">
      <div className="info-grid">
        <div>
          <Reveal as="h2">Services</Reveal>
          <ul className="menu">
            {services.map((s, i) => (
              <Reveal as="li" key={s.id} delay={i * 80}>
                <div className="menu-row">
                  <span className="menu-name">{s.name}</span>
                  <span className="menu-leader" />
                  <span className="menu-price">{priceLabel(s)}</span>
                </div>
                {s.note && <p className="menu-meta">{s.note}</p>}
                <a className="svc-cta" href={`#/book?service=${s.id}`}>
                  {CTA_TEXT}
                </a>
              </Reveal>
            ))}
          </ul>
        </div>

        <div>
          <Reveal as="h2">Hours</Reveal>
          <Reveal as="ul" className="hours" delay={80}>
            {DAYS.map(([i, name]) => {
              const windows = HOURS[i]
              return (
                <li key={i}>
                  <span>{name}</span>
                  <span className={windows ? '' : 'closed'}>
                    {windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'}
                  </span>
                </li>
              )
            })}
          </Reveal>

          <Reveal as="h2">Vic's Shop Location</Reveal>
          <Reveal as="address" delay={80}>
            {BUSINESS.address.map((line) => (
              <span key={line}>
                {line}
                <br />
              </span>
            ))}
            <EmailLink />
          </Reveal>
        </div>
      </div>

      <Reveal className="info-cta">
        <a className="btn btn-primary" href="#/book">
          {CTA_TEXT}
        </a>
      </Reveal>
    </section>
  )
}
VICBLESS_EOF
cat > "$STAGE/45" <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import { SOCIAL } from '../config.js'
import { useSettings } from '../lib/useSettings.js'
import { InstagramIcon, TikTokIcon } from './Socials.jsx'

const BarsIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M4 7h16M4 12h16M4 17h16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const CloseIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" focusable="false">
    <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
)

const Chevron = () => (
  <svg className="chev" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
)

// A whole row you tap to flip a setting on or off.
function Switch({ id, label, hint, checked, onToggle }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-labelledby={`${id}-label`}
      aria-describedby={`${id}-hint`}
      className="setting"
      onClick={onToggle}
    >
      <span className="setting-text">
        <span id={`${id}-label`} className="setting-label">
          {label}
        </span>
        <span id={`${id}-hint`} className="setting-hint">
          {hint}
        </span>
      </span>
      <span className="switch-state" aria-hidden="true">
        {checked ? 'On' : 'Off'}
      </span>
      <span className="switch-track" aria-hidden="true" />
    </button>
  )
}

// `children` are extra rows shown at the bottom of the menu (the dashboard adds View site and Sign out).
// `settingsExtra({ close })` adds rows to the Settings dropdown; only the dashboard passes it, so customers never see them.
export default function SiteMenu({ children, settingsExtra }) {
  const [open, setOpen] = useState(false)
  const [section, setSection] = useState(null) // 'socials' | 'settings' | null, one open at a time
  const wrapRef = useRef(null)
  const buttonRef = useRef(null)
  const { motion, theme, setMotion, setTheme } = useSettings()

  // Escape closes the menu (and returns focus to the button), a tap outside closes it too.
  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape') {
        setOpen(false)
        buttonRef.current?.focus()
      }
    }
    const onPointerDown = (e) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPointerDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPointerDown)
    }
  }, [open])

  // Closing the menu collapses the dropdowns, so it always opens fresh.
  useEffect(() => {
    if (!open) setSection(null)
  }, [open])

  const toggleSection = (name) => setSection((current) => (current === name ? null : name))

  return (
    <div className="site-menu" ref={wrapRef}>
      <button
        ref={buttonRef}
        type="button"
        className="menu-toggle"
        aria-label="Menu"
        aria-expanded={open}
        aria-controls="site-menu-panel"
        onClick={() => setOpen((o) => !o)}
      >
        {open ? <CloseIcon /> : <BarsIcon />}
      </button>

      <div id="site-menu-panel" className="menu-panel" hidden={!open}>
        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'socials'}
            aria-controls="menu-socials"
            onClick={() => toggleSection('socials')}
          >
            Socials
            <Chevron />
          </button>
          <div id="menu-socials" className="menu-sub" hidden={section !== 'socials'}>
            <a className="menu-link" href={SOCIAL.tiktok} target="_blank" rel="noopener noreferrer">
              <TikTokIcon />
              TikTok
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
            <a className="menu-link" href={SOCIAL.instagram} target="_blank" rel="noopener noreferrer">
              <InstagramIcon />
              Instagram
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </div>
        </div>

        <div className="menu-group">
          <button
            type="button"
            className="menu-head"
            aria-expanded={section === 'settings'}
            aria-controls="menu-settings"
            onClick={() => toggleSection('settings')}
          >
            Settings
            <Chevron />
          </button>
          <div id="menu-settings" className="menu-sub" hidden={section !== 'settings'}>
            <Switch
              id="set-motion"
              label="Motion"
              hint="Parallax, scroll effects and animations"
              checked={motion === 'on'}
              onToggle={() => setMotion(motion === 'on' ? 'off' : 'on')}
            />
            <Switch
              id="set-theme"
              label="Dark mode"
              hint="Switch off for light mode"
              checked={theme === 'dark'}
              onToggle={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
            />
            {settingsExtra && settingsExtra({ close: () => setOpen(false) })}
          </div>
        </div>

        {children && <div className="menu-extra">{children}</div>}
      </div>
    </div>
  )
}
VICBLESS_EOF
cat > "$STAGE/46" <<'VICBLESS_EOF'
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
cat > "$STAGE/47" <<'VICBLESS_EOF'
// The customer-facing data layer. The pages import from HERE and never know which layer answers.
//
//   real  -> realApi.js, the backend (production builds)
//   mock  -> mockApi.js, fake data kept in the browser (npm run dev and the tests)
//
// See mode.js for how the choice is made. Both layers export the same functions with the same shapes.

import * as mock from './mockApi.js'
import { API_MODE } from './mode.js'
import * as real from './realApi.js'

const layer = API_MODE === 'real' ? real : mock

export { SlotTakenError } from './errors.js'
export const getAvailability = (dateKeys) => layer.getAvailability(dateKeys)
export const getBusy = (dateKeys) => layer.getBusy(dateKeys)
export const getShopSettings = () => layer.getShopSettings()
export const createBooking = (payload) => layer.createBooking(payload)
VICBLESS_EOF
cat > "$STAGE/48" <<'VICBLESS_EOF'
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
cat > "$STAGE/49" <<'VICBLESS_EOF'
// MOCK storage shared by the customer-facing mock (lib/api.js) and the admin mock.
// It exists so that cancelling or blocking time in the dashboard changes what customers see.
// It goes away when the real backend exists.

import { HOURS } from '../config.js'
import { fromKey, slotStarts } from './availability.js'
import { DEFAULT_SHOP_SETTINGS, fromApi, slotFor } from './shopSettings.js'

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

// True when the times [aStart, aEnd) and [bStart, bEnd) share any minute.
export const overlaps = (aStart, aEnd, bStart, bEnd) => aStart < bEnd && bStart < aEnd

// The appointment starts on `dateKey` that touch blocked-off time.
export function blockedStartsFor(dateKey) {
  const blocks = readBlocks().filter((b) => b.dateKey === dateKey)
  const out = new Set()
  if (blocks.length === 0) return out
  const slot = slotMinutesOn(dateKey)
  for (const s of slotStarts(fromKey(dateKey), HOURS, slot)) {
    if (blocks.some((b) => overlaps(s, s + slot, b.start, b.end))) out.add(s)
  }
  return out
}

// True when Vic has taken the whole day off. Customers see such a day as Closed, not Full.
export function isDayOff(dateKey) {
  return readBlocks().some((b) => b.dateKey === dateKey && b.whole)
}
VICBLESS_EOF
cat > "$STAGE/50" <<'VICBLESS_EOF'
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
cat > "$STAGE/51" <<'VICBLESS_EOF'
// Vic's shop settings: the services with their prices, and how long an appointment is on each weekday.
//
// The real values live in the database (Vic edits them in his dashboard). This file holds the pure helpers that
// turn what the API sends into what the screens use, check what Vic typed, and a tiny shared store so every page
// sees the same settings. Nothing here talks to the network except loadShopSettings().
//
// Shape used by the screens ("settings"):
//   { services: [{ id, name, price, from, note }], slotMinutes: { 0: 35, 1: 45, ... 6: 35 } }   0 = Sunday
// The API uses weekday names instead of numbers ({ mon: 45 }); fromApi / toApi convert.

import { MAX_SERVICES, SERVICES, SLOT_MAX, SLOT_MIN, SLOT_MINUTES_BY_DAY, SLOT_STEP } from '../config.js'

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
})

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
  return { services, slotMinutes }
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
  }
}

export function newDraftService() {
  draftCounter += 1
  return { key: `new-${draftCounter}`, id: '', name: '', price: '', from: false, note: '' }
}

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
  return bad ? { ok: false, errors } : { ok: true, settings: { services, slotMinutes } }
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
cat > "$STAGE/52" <<'VICBLESS_EOF'
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
cat > "$STAGE/53" <<'VICBLESS_EOF'
import { useEffect, useSyncExternalStore } from 'react'
import { getShopSettings } from './api.js'
import { getShopSettingsNow, loadShopSettings, subscribeShopSettings } from './shopSettings.js'

// The shop's services and appointment lengths, for any screen. Starts with the shop's starting values, loads Vic's
// real ones once, and updates every screen using it when they change (for example after he saves in the dashboard).
export function useShopSettings() {
  const settings = useSyncExternalStore(subscribeShopSettings, getShopSettingsNow, getShopSettingsNow)
  useEffect(() => {
    loadShopSettings(getShopSettings)
  }, [])
  return settings
}
VICBLESS_EOF
cat > "$STAGE/54" <<'VICBLESS_EOF'
import { useEffect, useMemo, useState } from 'react'
import EmailLink from '../components/EmailLink.jsx'
import Reveal from '../components/Reveal.jsx'
import { DAYS_AHEAD, HOURS, LIMITS, STAFF, SUCCESS_HEADLINE } from '../config.js'
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
  const [form, setForm] = useState({ name: '', phone: '', email: '', notes: '' })
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
    setForm((f) => ({ ...f, [e.target.name]: e.target.value }))
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
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"a45d878f911dae606e5423b0f1c4840e45aaf87406d9fadee7935f21adaa5c20\", \"new\": 0}, {\"path\": \"backend/app/core/config.py\", \"base\": \"525c8c28592c4a2510b1d51d79232e24cd22c4ad5a44688eec8fe22bb2c02517\", \"new\": 1}, {\"path\": \"backend/app/core/errors.py\", \"base\": \"9758dad81a199133d229fee6f8689d66d33a84358967d319d8aa62df5183bb24\", \"new\": 2}, {\"path\": \"backend/app/core/web.py\", \"base\": \"d4fd57edf875944102d8fc46e7973e01d66c9fb20aaf95cd474814072c936868\", \"new\": 3}, {\"path\": \"backend/app/database/blocks.py\", \"base\": \"f9bf1c88e237b65c1beb2f9cc359dfc563e740a82f4deacb28ee1419af59c188\", \"new\": 4}, {\"path\": \"backend/app/database/bookings.py\", \"base\": \"2898c33f9c552f6e19f9797186c1e9dac26ac7d3d22747559a14ac0136c5373c\", \"new\": 5}, {\"path\": \"backend/app/database/keys.py\", \"base\": \"06db11a850a7b9479d0c8741c2b6cbee58b6c451094248794b6a84bd7c1c9dc1\", \"new\": 6}, {\"path\": \"backend/app/database/schedule.py\", \"base\": \"173f942133da164e21c6265f6056447c1ba31e6934a1410386b4ac657815f3cc\", \"new\": 7}, {\"path\": \"backend/app/database/settings.py\", \"base\": null, \"new\": 8}, {\"path\": \"backend/app/database/transactions.py\", \"base\": \"df4e1870fc573788b61fd2924bfe78adcd0d4833ffa1b57806ea6a6f52ff8705\", \"new\": 9}, {\"path\": \"backend/app/domain/models.py\", \"base\": \"8bfb04916288b125712a7a64dcd56cc67efeccdd50406d830c31063946724584\", \"new\": 10}, {\"path\": \"backend/app/domain/shop.py\", \"base\": \"141c98b4232af9fb8327f8bf996250689c59c32efde71c3219819c1071b28b85\", \"new\": 11}, {\"path\": \"backend/app/emailing/templates.py\", \"base\": \"0f6afe01d071aaf70d987e48f9a4da1fe3b2fbfdd26ca50a3c5a38edd1ccf8c0\", \"new\": 12}, {\"path\": \"backend/app/routes/admin.py\", \"base\": \"93eb891ce890b75d46a92efffd19e35dd7b997f36d22716040f3c52edfc95516\", \"new\": 13}, {\"path\": \"backend/app/routes/public.py\", \"base\": \"ec5215df084d96b0c0613379fa81148213aedbb446f19a954490059fa6ea17d6\", \"new\": 14}, {\"path\": \"backend/app/schemas/requests.py\", \"base\": \"7afe2111e34eb1ca0527bf41bffd4f43bb0fc83949ca7cd5b71abc4c86a2f561\", \"new\": 15}, {\"path\": \"backend/app/services/blocks.py\", \"base\": \"13f558e8f553867ca224ed0f37671bd58d3168e7220d7d8998ec90e6cd011adf\", \"new\": 16}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"cb824a9c3095b7f30c1bb1f6f9cb734256b2ab66a092414da3f1bd43c8017d2c\", \"new\": 17}, {\"path\": \"backend/app/services/settings.py\", \"base\": null, \"new\": 18}, {\"path\": \"backend/scripts/migrate_unit_claims.py\", \"base\": null, \"new\": 19}, {\"path\": \"backend/tests/conftest.py\", \"base\": \"807458ddf2f67b5b36a3a06a580fb50981fc2d4afaff6bcf7e78a9e79668e607\", \"new\": 20}, {\"path\": \"backend/tests/fixtures/settings.py\", \"base\": null, \"new\": 21}, {\"path\": \"backend/tests/helpers/builders.py\", \"base\": \"7aadd9a77129ce8f8baf6c71beb444553f8b6e4dd63757e32aab6f382f0c17b8\", \"new\": 22}, {\"path\": \"backend/tests/test_admin_api.py\", \"base\": \"3c42f8d5a70b76aa52dbde73a6c54e6e5c6648140507a7ffed0265e5cf70d6db\", \"new\": 23}, {\"path\": \"backend/tests/test_contract.py\", \"base\": \"5eb4e01d549aede02375303efbc4493c2c8f9476ff1e8bafe2d2165adf1f100d\", \"new\": 24}, {\"path\": \"backend/tests/test_public_api.py\", \"base\": \"e71966645556b2507166a5b75b2fcd36023fab552d58f66b90ecb87c327f2ae6\", \"new\": 25}, {\"path\": \"backend/tests/test_repository.py\", \"base\": \"11d33133fc9dda7c1513ae15ff132f6588fa0b4b5498ff47f086a5efc1ca0529\", \"new\": 26}, {\"path\": \"backend/tests/test_reschedule.py\", \"base\": \"c6953f4efbb6397dae57ca73f97ef337ee39b38077b3ddc62131cd958d590723\", \"new\": 27}, {\"path\": \"backend/tests/test_scripts.py\", \"base\": \"d1ea9dfdccb704c6231be23106116b12ad4e8a2ab393c196173c5193223447a7\", \"new\": 28}, {\"path\": \"backend/tests/test_settings.py\", \"base\": null, \"new\": 29}, {\"path\": \"backend/tests/test_shop.py\", \"base\": \"d517a4a755edc0766648e2c8f0eda3214e70f60446744109eee5f06e7e6ebba0\", \"new\": 30}, {\"path\": \"frontend/src/admin/Admin.jsx\", \"base\": \"cc6d6e493f2bd814a5219b3259536dc9f4d05c31fef26e0f4040537aab2de14f\", \"new\": 31}, {\"path\": \"frontend/src/admin/BlockOff.jsx\", \"base\": \"5eb118e33360e3d8b1b6697e096a89cf6e5fa245d09362c56f8a3bf6fad151e7\", \"new\": 32}, {\"path\": \"frontend/src/admin/MoveBooking.jsx\", \"base\": \"b588fe5e3f3390538e322a70158599e66502b6910179545881842cd451ae2178\", \"new\": 33}, {\"path\": \"frontend/src/admin/Schedule.jsx\", \"base\": \"c1cf339e5c626518c112785cc2c93bfd12bf0b93e6dbf0d3813e4d43c5dfdaf4\", \"new\": 34}, {\"path\": \"frontend/src/admin/SettingsPanel.jsx\", \"base\": null, \"new\": 35}, {\"path\": \"frontend/src/admin/admin.css\", \"base\": \"ac7911360da7432cb23f57e981e061c93aa3c0b642e0420c7c009a487051cfe8\", \"new\": 36}, {\"path\": \"frontend/src/admin/adminApi.js\", \"base\": \"3f378f2e5f36fbbca52a09eff4331ef18e50d612be61ec31fcad6a238206faa5\", \"new\": 37}, {\"path\": \"frontend/src/admin/blocks.js\", \"base\": \"82a90f5bbb4b705d958773d69f425aafc6e9f25533f220a9c3ddc35daca461bd\", \"new\": 38}, {\"path\": \"frontend/src/admin/blocks.test.js\", \"base\": \"52971bd8a386d50c38f82c219b941cc7baa025f477362d0738fa66aca98b4208\", \"new\": 39}, {\"path\": \"frontend/src/admin/mockAdminApi.js\", \"base\": \"434477a3cdd6090ea563fc3ab674c45b4428337316b5ab083adc5f33c7354a0a\", \"new\": 40}, {\"path\": \"frontend/src/admin/moveTimes.js\", \"base\": \"12724b5697424ea98e2c376fe7e981af5a6b813d2c02c697a66488c0dae47bd0\", \"new\": 41}, {\"path\": \"frontend/src/admin/moveTimes.test.js\", \"base\": \"30a3395060273b8b952cb8200efaaa8045cdeb8ba118a198e0418a09b183f6c7\", \"new\": 42}, {\"path\": \"frontend/src/admin/realAdminApi.js\", \"base\": \"bb23d04421fdae28e8d746c78e6b14d2ff30d86a03df92902d211bab84585f2a\", \"new\": 43}, {\"path\": \"frontend/src/components/ShopInfo.jsx\", \"base\": \"04c497d2d62de7adf572bb8f71e3803a056cd2cd75492e960611de27c43aa11f\", \"new\": 44}, {\"path\": \"frontend/src/components/SiteMenu.jsx\", \"base\": \"447ee133c7d099ad4774d3f09e97ca21106a90be0adb7713a618a7c4dfcf37ca\", \"new\": 45}, {\"path\": \"frontend/src/config.js\", \"base\": \"aff6e4eea57db2f063ac3e0c4868c71c8e300adc0f9fa68156b2c88b9c3b977c\", \"new\": 46}, {\"path\": \"frontend/src/lib/api.js\", \"base\": \"a6ad492de467cd1e2afd6d528484a43395f3d5a1d19957a34e373952bf657eb4\", \"new\": 47}, {\"path\": \"frontend/src/lib/mockApi.js\", \"base\": \"072a82985a0a7c3ee5ea3f5ac5b3dff9b18643899ace04c2c3f748bb5fa40fed\", \"new\": 48}, {\"path\": \"frontend/src/lib/mockStore.js\", \"base\": \"a309c1643bf529ca0e14666f8009e91182f3734449e554698ebb6b882ba147c7\", \"new\": 49}, {\"path\": \"frontend/src/lib/realApi.js\", \"base\": \"bb80f2b1f6d0658a9fe25e99786cb4896e77d508578749e0107d397a1ac4eea1\", \"new\": 50}, {\"path\": \"frontend/src/lib/shopSettings.js\", \"base\": null, \"new\": 51}, {\"path\": \"frontend/src/lib/shopSettings.test.js\", \"base\": null, \"new\": 52}, {\"path\": \"frontend/src/lib/useShopSettings.js\", \"base\": null, \"new\": 53}, {\"path\": \"frontend/src/pages/Book.jsx\", \"base\": \"fd6c7b23d1dedb5010e80e2f50e3935967f5cb7c7ce98889e5fb586a27a8e9b9\", \"new\": 54}]")

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
echo "Deploy order: backend first, then the migration per environment, then the frontend."
echo "Migration: AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev --apply"
