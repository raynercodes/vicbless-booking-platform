#!/usr/bin/env bash
# Vicbless backend: FastAPI on Lambda + DynamoDB, with the Resend email bridge.
# Run from the repo ROOT (the folder with .git, frontend/ and backend/):  bash add-vicbless-backend.sh
#
# It writes the backend, the SAM template (infra/template.yaml) and the tests, fixes .github/workflows/deploy-backend.yml
# if you already have it, installs the packages into backend/.venv, and runs the tests.
# It never runs git and never touches AWS. It refuses to overwrite an existing backend unless you run:  FORCE=1 bash add-vicbless-backend.sh
set -euo pipefail

if [ ! -d .git ] || [ ! -f frontend/src/config.js ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and frontend/)."
  exit 1
fi
if { [ -e backend/app ] || [ -e infra/template.yaml ]; } && [ "${FORCE:-}" != "1" ]; then
  echo "backend/app or infra/template.yaml already exists. Nothing written."
  echo "To replace them with this version on purpose, run:  FORCE=1 bash add-vicbless-backend.sh"
  exit 1
fi

if ! grep -q "export const LIMITS" frontend/src/config.js; then
  echo "frontend/src/config.js has no LIMITS yet. Run update-vicbless-notes-counter.sh from inside frontend/ first,"
  echo "then run this again. (The backend tests check that the site and the API use the same input limits.)"
  exit 1
fi
if [ "${FORCE:-}" = "1" ]; then
  # Replace the previous version cleanly. The old flat layout (app/config.py, app/service.py...) must not be left behind.
  rm -rf backend/app backend/tests backend/scripts backend/.pytest_cache
fi
mkdir -p backend/app/{core,domain,schemas,database,services,routes,emailing} backend/tests/fixtures backend/tests/helpers backend/scripts infra
cat > backend/README.md <<'VICBLESS_EOF'
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
    domain/        the shop itself: shop.py (hours, services, the 35 minute grid, booking rules) and models.py (Booking, Block, ids)
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
- the shop's hours, services or 35-minute rule: `domain/shop.py` (and `frontend/src/config.js`, a test checks they match)
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
Each 35 minute block of each day is one DynamoDB item that can only be created once. A booking writes
its blocks and itself in a single transaction that fails as a whole if any block already exists.
The availability list is only for display; the transaction is the real guard.

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
cat > backend/app/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/core/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/core/aws.py <<'VICBLESS_EOF'
"""AWS clients. Created on first use so tests can start their fake AWS first."""

from __future__ import annotations

import threading

_clients: dict[str, object] = {}
_lock = threading.Lock()


def _get(kind: str):
    """Creates an AWS client the first time it is asked for, then reuses it (building one is slow).

    Lambda keeps the process warm between requests, so this module-level cache is what makes the
    second request faster than the first. Tests call reset_clients() so each test gets a fresh fake AWS.
    """
    import boto3  # imported here so just importing this file stays fast

    with _lock:
        if kind not in _clients:
            if kind == "dynamodb":
                _clients[kind] = boto3.resource("dynamodb")
            else:
                _clients[kind] = boto3.client(kind)
        return _clients[kind]


def dynamodb_resource():
    return _get("dynamodb")


def ssm_client():
    return _get("ssm")


def reset_clients() -> None:
    with _lock:
        _clients.clear()
VICBLESS_EOF
cat > backend/app/core/config.py <<'VICBLESS_EOF'
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


def reset_caches() -> None:
    """Forget cached clients and parameters. Tests call this between cases."""
    aws.reset_clients()
    params.reset()
VICBLESS_EOF
cat > backend/app/core/errors.py <<'VICBLESS_EOF'
"""Errors the API turns into the JSON shape { "error": { "code", "message" } }.

Each error carries three things the site needs:
  status   the HTTP status code
  code     a short stable word the frontend can branch on (for example "slot_taken")
  message  a sentence that is safe to show a customer or Vic as it is, so keep them friendly and plain
Raise one of these from anywhere in the app; core/web.py turns it into the response.
"""


class ApiError(Exception):
    status = 400
    code = "bad_request"

    def __init__(self, message: str | None = None, *, code: str | None = None):
        super().__init__(message or self.default_message)
        self.message = message or self.default_message
        if code:
            self.code = code

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
    default_message = "This phone number already has the most upcoming bookings we allow. Please call or text Vic to change one."


class TooManyAttempts(ApiError):
    status = 429
    code = "too_many_attempts"
    default_message = "Too many tries. Please wait about 15 minutes, then try again."


class NotConfigured(ApiError):
    status = 503
    code = "not_configured"
    default_message = "This part of the service isn't set up yet."
VICBLESS_EOF
cat > backend/app/core/logs.py <<'VICBLESS_EOF'
"""Structured JSON logs for CloudWatch. Never log names, phone numbers or emails."""

from __future__ import annotations

import contextvars
import json
import logging
import sys

request_id: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

_logger = logging.getLogger("vicbless")


def setup() -> None:
    if _logger.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(handler)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False


def log(event: str, level: int = logging.INFO, **fields) -> None:
    setup()
    _logger.log(level, json.dumps({"event": event, "requestId": request_id.get(), **fields}, default=str))
VICBLESS_EOF
cat > backend/app/core/security.py <<'VICBLESS_EOF'
"""Admin sign-in: password hashing and session tokens.

Password: HMAC with a secret pepper first (so a stolen database row alone cannot be cracked), then
PBKDF2-HMAC-SHA256 with 600,000 rounds (the current OWASP number). That many rounds is CPU work,
which is why the Lambda has 1024 MB (more memory means more CPU).
Stored as:  pbkdf2_sha256$600000$<salt base64>$<hash base64>

Session: a signed token (JWT, HS256) that lasts 12 hours. The site sends it in the Authorization header.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import time

import jwt

from .errors import NotConfigured, Unauthorized

ITERATIONS = 600_000
ALGORITHM = "pbkdf2_sha256"
SESSION_SECONDS = 12 * 60 * 60
ISSUER = "vicbless"
AUDIENCE = "vicbless-admin"
SUBJECT = "vic"
MIN_SECRET_LENGTH = 32


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()


def _prehash(password: str, pepper: str) -> bytes:
    """Mixes the secret pepper into the password first (HMAC), so the stored hash can't be cracked without it."""
    return hmac.new(pepper.encode(), password.encode(), hashlib.sha256).digest()


def hash_password(password: str, pepper: str, *, iterations: int = ITERATIONS, salt: bytes | None = None) -> str:
    salt = salt or os.urandom(16)  # a fresh random salt per hash, so two identical passwords never look alike
    digest = hashlib.pbkdf2_hmac("sha256", _prehash(password, pepper), salt, iterations)
    return f"{ALGORITHM}${iterations}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, stored: str, pepper: str) -> bool:
    # A malformed stored value just means "wrong password"; it must never crash the sign-in.
    try:
        algorithm, rounds, salt_b64, hash_b64 = stored.split("$")
        iterations = int(rounds)
        salt = base64.b64decode(salt_b64, validate=True)
        expected = base64.b64decode(hash_b64, validate=True)
    except (ValueError, TypeError):
        return False
    # The rounds cap stops a corrupted value from making the server compute for minutes.
    if algorithm != ALGORITHM or not 1 <= iterations <= 5_000_000:
        return False
    # Recompute with the stored salt and rounds, then compare in constant time (compare_digest) so the
    # time taken doesn't leak how many characters matched.
    actual = hashlib.pbkdf2_hmac("sha256", _prehash(password, pepper), salt, iterations)
    return hmac.compare_digest(actual, expected)


def issue_token(secret: str, *, now: float | None = None) -> str:
    if len(secret or "") < MIN_SECRET_LENGTH:
        raise NotConfigured("Sign-in isn't set up yet.")
    # Claims: who issued it (iss), who it is for (aud), whose it is (sub), when (iat), and when it dies (exp).
    issued = int(time.time() if now is None else now)
    claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": SUBJECT, "iat": issued, "exp": issued + SESSION_SECONDS}
    return jwt.encode(claims, secret, algorithm="HS256")


def check_token(token: str, secret: str) -> None:
    """Returns None if the token is valid; raises Unauthorized if not."""
    if len(secret or "") < MIN_SECRET_LENGTH:
        raise NotConfigured("Sign-in isn't set up yet.")
    # PyJWT checks the signature AND every claim below. algorithms=["HS256"] is fixed, so a forged
    # token that claims "alg: none" is refused.
    try:
        jwt.decode(
            token,
            secret,
            algorithms=["HS256"],
            audience=AUDIENCE,
            issuer=ISSUER,
            subject=SUBJECT,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )
    except jwt.PyJWTError:
        raise Unauthorized("Your session ended. Please sign in again.") from None
VICBLESS_EOF
cat > backend/app/core/web.py <<'VICBLESS_EOF'
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
        return error_response(exc.status, exc.code, exc.message)

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
            allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
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
cat > backend/app/database/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/database/blocks.py <<'VICBLESS_EOF'
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
    # Same trick as a booking: claim every covered block in one transaction. If a booking or another
    # block-off already holds one of them, nothing is written and Vic gets a Conflict.
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
        "expiresAt": keys.expires(day),
    }
    transaction = [
        {
            "Put": {
                "TableName": table.table_name(),
                "Item": item,
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }
    ] + [transactions.claim_put(day, s, block_id) for s in claims]
    try:
        transactions.write_all_or_nothing(transaction)
    except SlotTaken:
        raise Conflict() from None
    return block_from(item)


def delete_block(block_id: str) -> Block:
    block = get_block(block_id)
    if not block:
        raise NotFound("That blocked time was not found. It may already be removed.")
    transaction = [
        {
            "Delete": {
                "TableName": table.table_name(),
                "Key": {"pk": PK, "sk": keys.block_sk(block.day, block.claims[0], block.id)},
                "ConditionExpression": "attribute_exists(pk)",
            }
        }
    ] + [transactions.claim_delete(block.day, s, block.id) for s in block.claims]
    try:
        table.client().transact_write_items(TransactItems=transaction)
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "TransactionCanceledException":
            if get_block(block_id) is None:
                raise NotFound("That blocked time was not found. It may already be removed.") from None
        raise
    return block
VICBLESS_EOF
cat > backend/app/database/bookings.py <<'VICBLESS_EOF'
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
    *, booking_id: str, day: date, start: int, service_id: str, minutes: int, name: str, phone: str,
    email: str, notes: str, code: str, created: str,
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
        "name": name,
        "phone": phone,
        "email": email,
        "notes": notes,
        "createdAt": created,
        "blocks": shop.occupied_starts(start, minutes),
        "gsi1pk": f"PHONE#{phone}",  # sparse index: lets us count a phone number's upcoming bookings
        "gsi1sk": f"{day.isoformat()}#{shop.hhmm(start)}",
        "expiresAt": keys.expires(day),
    }


def create_booking(
    *, day: date, start: int, service_id: str, minutes: int, name: str, phone: str, email: str, notes: str, code: str
) -> Booking:
    booking_id = new_id(day, start)
    claims = shop.occupied_starts(start, minutes)  # the 35 minute blocks this booking will hold
    created = datetime.now(timezone.utc).isoformat(timespec="seconds")
    item = _booking_item(
        booking_id=booking_id, day=day, start=start, service_id=service_id, minutes=minutes, name=name,
        phone=phone, email=email, notes=notes, code=code, created=created,
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


def move_booking(booking: Booking, *, day: date, start: int) -> Booking:
    """Moves a booking to a new day/time in ONE transaction, so it is never in two places or in none.

    The booking id contains its day and time, so a moved booking gets a NEW id (the customer's code stays
    the same). The transaction:
      - deletes the old booking item and creates the new one
      - releases the old blocks nobody needs any more, and claims the new ones (refused if any is taken)
      - for a block that is in BOTH (moving a long booking a little), hands it over in place
    If anything fails, nothing changes: the booking stays exactly where it was.
    """
    new_booking_id = new_id(day, start)
    old_blocks = {(booking.day, s) for s in booking.claims}
    new_blocks = {(day, s) for s in shop.occupied_starts(start, booking.minutes)}

    item = _booking_item(
        booking_id=new_booking_id, day=day, start=start, service_id=booking.service_id, minutes=booking.minutes,
        name=booking.name, phone=booking.phone, email=booking.email, notes=booking.notes, code=booking.code,
        created=booking.created_at,
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
cat > backend/app/database/keys.py <<'VICBLESS_EOF'
"""How items are named in the table. All of Vic's items share one partition; the sort key sorts by day.

    2026-10-12#CLAIM#1200                 one per taken 35 minute block
    2026-10-12#BOOKING#1200#<booking id>  the booking itself
    2026-10-12#BLOCK#1200#<block id>      time Vic blocked off
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
cat > backend/app/database/login_attempts.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/app/database/schedule.py <<'VICBLESS_EOF'
"""Reading a day or a range of days: what is taken, and the schedule Vic sees."""

from __future__ import annotations

from datetime import date, timedelta

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


def availability(first: date, last: date) -> dict[str, dict]:
    """{ 'YYYY-MM-DD': { busy: [block starts], dayOff: bool } } for every day in the range.

    `busy` lists the taken blocks (bookings and block-offs alike, so the site greys them out the same way).
    `dayOff` is true when Vic took the whole day off, so the site can say "Closed" instead of "Full".
    """
    # Start every day empty, so days with nothing booked still appear in the answer.
    days: dict[str, dict] = {}
    d = first
    while d <= last:
        days[d.isoformat()] = {"busy": [], "dayOff": False}
        d += timedelta(days=1)
    items = query_range(f"{first.isoformat()}#", f"{last.isoformat()}#~", projection=True)
    for item in items:
        day_key, kind, *rest = item["sk"].split("#")
        entry = days.get(day_key)
        if entry is None:
            continue
        if kind == "CLAIM":
            entry["busy"].append(keys.minutes_of(rest[0]))
        elif kind == "BLOCK" and item.get("whole"):
            entry["dayOff"] = True
    for entry in days.values():
        entry["busy"].sort()
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
cat > backend/app/database/table.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/app/database/transactions.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/app/domain/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/domain/models.py <<'VICBLESS_EOF'
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

    @property
    def claims(self) -> list[int]:
        """The block starts this booking holds in the database."""
        return shop.occupied_starts(self.start, self.minutes)

    def admin_view(self) -> dict:
        """What Vic's dashboard shows, contact details included."""
        return {
            "id": self.id,
            "dateKey": self.day.isoformat(),
            "source": "online",
            "start": self.start,
            "minutes": self.minutes,
            "serviceId": self.service_id,
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
    """Time Vic blocked off (lunch, a day off). `claims` are the 35 minute blocks it covers."""

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
cat > backend/app/domain/shop.py <<'VICBLESS_EOF'
"""The shop's rules: hours, services, the 35 minute grid, and what counts as a bookable time.

Pure functions with an injectable clock. Nothing here touches AWS, so every rule is easy to test.
This mirrors frontend/src/config.js and frontend/src/lib/availability.js. A test compares the two,
so the site and the API cannot quietly drift apart.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from ..core.errors import InvalidSlot, SlotUnavailable

# Vic's shop runs on this clock no matter where the server is. (Lambda's own clock is UTC.)
TIMEZONE = ZoneInfo("America/New_York")
STAFF_ID = "vic"
SLOT_MINUTES = 35  # Vic books in 35 minute blocks; every service takes one block (a longer one would take several)
DAYS_AHEAD = 14  # today plus the next 13 days, same as the booking page
LEAD_MINUTES = 30  # a time today must start more than this many minutes from now
MAX_BLOCK_DAYS_AHEAD = 365  # how far ahead Vic can block off time
MAX_RANGE_DAYS = 31  # the longest availability range one request may ask for


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


@dataclass(frozen=True)
class Service:
    """One thing a customer can book. `minutes` is the real length; the API never trusts the site for it."""

    id: str
    name: str
    minutes: int


SERVICES: dict[str, Service] = {
    s.id: s
    for s in (
        Service("mens-cut", "Men's haircut", 35),
        Service("mens-design", "Men's haircut with design", 35),
        Service("mens-beard-eyebrow", "Men's haircut with beard and eyebrow", 35),
        Service("buzz-beard", "Head buzzed/shave and beard", 30),
        Service("kids-design", "Kids cut (12 and under) with design", 30),
    )
}


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


def grid_starts(day: date) -> list[int]:
    """Every block start of the day, across all opening windows (Saturday's break is not in it).

    Each window runs its own 35 minute grid from its opening time, and a block must end by closing.
    """
    out: list[int] = []
    for open_, close in windows_for(day):
        s = open_
        while s + SLOT_MINUTES <= close:
            out.append(s)
            s += SLOT_MINUTES
    return out


def blocks_for(minutes: int) -> int:
    """How many 35 minute blocks a service takes (always at least one)."""
    return max(1, -(-minutes // SLOT_MINUTES))


def occupied_starts(start: int, minutes: int) -> list[int]:
    """The block starts a booking holds. These become the "claims" in the database."""
    return [start + k * SLOT_MINUTES for k in range(blocks_for(minutes))]


def booking_window(now: datetime) -> tuple[date, date]:
    """The first and last day customers may book: today through 13 days from now."""
    first = today(now)
    return first, first + timedelta(days=DAYS_AHEAD - 1)


def fits(day: date, start: int, minutes: int) -> bool:
    """True if a service starting at `start` is on the grid and finishes inside one opening window.

    Same rule as the booking page: start + minutes <= closing time, and every block it covers is a
    real block of the day.
    """
    for open_, close in windows_for(day):
        if open_ <= start and start + minutes <= close and (start - open_) % SLOT_MINUTES == 0:
            valid = set(grid_starts(day))
            return all(s in valid for s in occupied_starts(start, minutes))
    return False


def check_bookable(day: date, start: int, minutes: int, now: datetime) -> None:
    """Raise InvalidSlot (can never work) or SlotUnavailable (not right now). Returns None if OK."""
    # 1. Structure: is this a real block of a real opening day? If not, no amount of waiting will fix it.
    if not fits(day, start, minutes):
        raise InvalidSlot()
    # 2. Timing: a real time can still be too early, too late, or too far away.
    first, last = booking_window(now)
    if day < first or day > last:
        raise SlotUnavailable()
    # Today only: Vic needs notice, so a time must start more than 30 minutes from now.
    if day == first and start <= minutes_of_day(now) + LEAD_MINUTES:
        raise SlotUnavailable()


def check_movable(day: date, start: int, minutes: int, now: datetime) -> None:
    """Rules for Vic moving a booking. Looser than for customers: no 14 day limit and no 30 minute notice.

    It still has to be a real block of an open day, it can't be in the past, and it can't be more than a year out.
    Raises InvalidSlot. (Whether the time is free is decided by the database, not here.)
    """
    if not fits(day, start, minutes):
        raise InvalidSlot()
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can move a booking to any open time from now up to a year ahead.")
    if day == first and start <= minutes_of_day(now):
        raise InvalidSlot("That time has already passed today. Pick a later one.")


def block_starts_in_range(day: date, start: int, end: int) -> list[int]:
    """The grid blocks a block-off covers: every block that starts at or after `start` and before `end`."""
    return [s for s in grid_starts(day) if start <= s < end]


def check_blockable(day: date, now: datetime) -> None:
    """Vic can only block an open day, from today up to a year ahead. Raises InvalidSlot otherwise."""
    if not is_open(day):
        raise InvalidSlot("The shop is already closed that day, so there is nothing to block.")
    first = today(now)
    if day < first or day > first + timedelta(days=MAX_BLOCK_DAYS_AHEAD):
        raise InvalidSlot("You can block time from today up to a year ahead.")
VICBLESS_EOF
cat > backend/app/emailing/__init__.py <<'VICBLESS_EOF'
"""Sending email. The rest of the app only knows about EmailSender and EmailMessage.

Today the provider is Resend (emailing/resend.py), a bridge while AWS SES waits for production access.
When SES is ready: add emailing/ses.py with the same `send` method, add it to get_sender() below,
set EMAIL_PROVIDER=ses, then delete resend.py and its line here. Nothing else changes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..core import config
from ..core.logs import log


@dataclass(frozen=True)
class EmailMessage:
    """One email, independent of which provider sends it. `reply_to` is who a reply should go to."""

    to: str
    subject: str
    text: str
    html: str
    reply_to: str = ""


class EmailSender(Protocol):
    """Anything with a send() method counts as a provider (Resend now, SES later). Nothing else is required."""

    def send(self, message: EmailMessage) -> None: ...


class NullSender:
    """Used when no provider is set up. Logs that an email would have gone out, and sends nothing."""

    def send(self, message: EmailMessage) -> None:
        log("email_skipped", reason="no_provider")


def get_sender() -> EmailSender:
    """Picks the provider named by the EMAIL_PROVIDER setting. If its keys aren't set up yet, emails are skipped
    (and logged) rather than breaking bookings. That is what lets the app run before Resend is configured.
    """
    provider = config.get_settings().email_provider
    if provider == "resend":
        from .resend import ResendSender

        key = config.params.get("resend-api-key")
        sender = config.params.get("email-from")
        if key and sender:
            return ResendSender(api_key=key, sender=sender)
        log("email_not_configured", provider="resend")
        return NullSender()
    return NullSender()
VICBLESS_EOF
cat > backend/app/emailing/resend.py <<'VICBLESS_EOF'
"""Resend bridge. Delete this file when AWS SES is approved (see emailing/__init__.py).

Uses only the standard library, so it adds nothing to the Lambda package.
API: POST https://api.resend.com/emails  (docs: resend.com/docs/api-reference/emails/send-email)
Fields: from, to, subject, html, text, reply_to. Rate limit: 10 requests/second, answered with 429.
Until a domain is verified in Resend, it only delivers from onboarding@resend.dev to the account owner's own address.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

from ..core.logs import log
from . import EmailMessage

API_URL = "https://api.resend.com/emails"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 5


class EmailSendError(Exception):
    """Raised when Resend could not deliver. The caller (services/notifications.py) logs it and carries on."""

    pass


class ResendSender:
    def __init__(self, api_key: str, sender: str):
        self.api_key = api_key
        self.sender = sender

    def _payload(self, message: EmailMessage) -> dict:
        """Our EmailMessage -> the JSON body Resend expects."""
        payload = {
            "from": self.sender,
            "to": [message.to],
            "subject": message.subject,
            "html": message.html,
            "text": message.text,
        }
        if message.reply_to:
            payload["reply_to"] = [message.reply_to]
        return payload

    def _request(self, message: EmailMessage) -> urllib.request.Request:
        """The full HTTP request. The API key travels only in the Authorization header, and is never logged."""
        return urllib.request.Request(
            API_URL,
            data=json.dumps(self._payload(message)).encode(),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
            },
        )

    def send(self, message: EmailMessage) -> None:
        """Send one email. Retries once if Resend says to slow down. Raises EmailSendError on failure."""
        # At most two tries: Resend allows 10 requests/second, and one booking sends two emails back to back.
        for attempt in (1, 2):
            try:
                with urllib.request.urlopen(self._request(message), timeout=TIMEOUT_SECONDS) as response:
                    response.read()
                return
            except urllib.error.HTTPError as err:
                if err.code == 429 and attempt == 1:
                    try:
                        wait = float(err.headers.get("retry-after", "1"))
                    except (TypeError, ValueError):
                        wait = 1.0
                    time.sleep(min(max(wait, 0.2), 1.5))
                    continue
                log("email_failed", provider="resend", status=err.code)
                raise EmailSendError(f"Resend answered {err.code}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as err:
                log("email_failed", provider="resend", reason=type(err).__name__)
                raise EmailSendError("Could not reach Resend") from None
VICBLESS_EOF
cat > backend/app/emailing/templates.py <<'VICBLESS_EOF'
"""The three emails. Everything a customer typed is HTML-escaped; subjects have line breaks removed."""

from __future__ import annotations

from html import escape

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
    service = shop.SERVICES.get(booking.service_id)
    return service.name if service else booking.service_id


def _page(title: str, rows: list[tuple[str, str]], footer: str) -> str:
    body = "".join(
        f'<tr><td style="padding:4px 16px 4px 0;color:#666">{escape(k)}</td><td style="padding:4px 0">{v}</td></tr>'
        for k, v in rows
    )
    return (
        '<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#111">'
        f'<h2 style="margin:0 0 12px">{escape(title)}</h2>'
        f'<table style="border-collapse:collapse">{body}</table>'
        f'<p style="margin-top:16px;color:#444">{escape(footer)}</p></div>'
    )


def customer_confirmation(booking: Booking, owner_email: str) -> EmailMessage:
    when = _when(booking)
    rows = [
        ("When", escape(when)),
        ("Service", escape(_service_name(booking))),
        ("Barber", "Vic"),
        ("Your code", f"<strong>{escape(booking.code)}</strong>"),
    ]
    footer = "Pay at the shop. Need to change something? Reply to this email or tell Vic."
    text = f"You're booked with Vic.\n\nWhen: {when}\nService: {_service_name(booking)}\nYour code: {booking.code}\n\n{footer}\n"
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
        f"Notes: {booking.notes or 'none'}\nCode: {booking.code}\n"
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
        text=f"Your appointment with Vic on {when} was cancelled.\n\n{footer}\n",
        html=_page("Your appointment was cancelled", [("Was booked for", escape(when))], footer),
        reply_to=owner_email,
    )


def customer_rescheduled(before: Booking, after: Booking, owner_email: str) -> EmailMessage:
    """Sent to the customer when Vic moves their appointment. Shows the old and the new time."""
    old_when, new_when = _when(before), _when(after)
    footer = "If this time doesn't work for you, reply to this email or call Vic."
    rows = [
        ("New time", f"<strong>{escape(new_when)}</strong>"),
        ("Was", escape(old_when)),
        ("Service", escape(_service_name(after))),
        ("Your code", escape(after.code)),
    ]
    text = (
        f"Vic moved your appointment.\n\nNew time: {new_when}\nWas: {old_when}\n"
        f"Service: {_service_name(after)}\nYour code: {after.code}\n\n{footer}\n"
    )
    return EmailMessage(
        to=after.email,
        subject=_subject(f"Your appointment was moved: {new_when}"),
        text=text,
        html=_page("Your appointment was moved", rows, footer),
        reply_to=owner_email,
    )
VICBLESS_EOF
cat > backend/app/handler.py <<'VICBLESS_EOF'
"""AWS Lambda entry point: API Gateway (HTTP API) -> Mangum -> FastAPI."""

from mangum import Mangum

from .main import app

lambda_handler = Mangum(app, lifespan="off")
VICBLESS_EOF
cat > backend/app/main.py <<'VICBLESS_EOF'
"""Builds the app. Every route lives under /api. There is no /docs, /redoc or openapi.json in any environment.

Where things live (each layer only talks to the ones below it):
    routes/     the URLs: read the request, call a service, shape the answer
    services/   what happens: booking, blocking, signing in, emailing
    database/   everything that touches DynamoDB
    domain/     the shop's rules (shop.py) and its things (models.py), no web or AWS
    schemas/    what the site is allowed to send
    core/       settings, secrets, security, logging, errors, web plumbing
    emailing/   email providers (Resend today, SES later)
"""

from fastapi import FastAPI

from .core.web import add_error_handlers, add_middleware
from .routes import admin, public


def create_app() -> FastAPI:
    app = FastAPI(title="Vicbless", docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(public.router, prefix="/api")
    app.include_router(admin.login_router, prefix="/api/admin")
    app.include_router(admin.router, prefix="/api/admin")
    add_error_handlers(app)
    add_middleware(app)
    return app


app = create_app()
VICBLESS_EOF
cat > backend/app/routes/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/routes/admin.py <<'VICBLESS_EOF'
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
from ..schemas.requests import BlockIn, LoginIn, MoveIn, date_from_query
from ..services import auth, blocks, bookings, notifications
from ..services import schedule as schedule_service
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
cat > backend/app/routes/deps.py <<'VICBLESS_EOF'
"""The web-only glue the routes share.

Why this is not part of services/: these two functions read things off a web Request (a header, the
caller's address). Services are not allowed to import FastAPI (a test enforces it), so the part that
needs a Request stays here and stays tiny. The real work, checking a session token, lives in
services/auth.py.
"""

from __future__ import annotations

from fastapi import Request

from ..services import auth


def require_admin(request: Request) -> None:
    """Runs before the body is read, so a stranger gets 401 whatever they send."""
    auth.check_bearer(request.headers.get("authorization"))


def source_address(request: Request) -> str:
    """The caller's network address as API Gateway reports it (used only for the sign-in lockout)."""
    return request.client.host if request.client else "unknown"
VICBLESS_EOF
cat > backend/app/routes/public.py <<'VICBLESS_EOF'
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
cat > backend/app/schemas/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/schemas/requests.py <<'VICBLESS_EOF'
"""What the site is allowed to send us.

Every request body is checked and cleaned here, BEFORE any business logic runs:
  - anything not listed in a model is ignored (for example the `minutes` the site sends: the API
    looks the real length up from the service, so a customer can never choose how long a cut takes)
  - text is stripped of hidden control characters and extra spaces
  - the error messages are written for customers and for Vic, not for programmers. The site shows
    them as they are, so they must read like a person wrote them.

The limits below are mirrored in frontend/src/config.js (LIMITS). A test compares the two.
"""

from __future__ import annotations

import re
import unicodedata
from datetime import date

from pydantic import BaseModel, ConfigDict, StrictInt, field_validator

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
        if v not in shop.SERVICES:
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
VICBLESS_EOF
cat > backend/app/services/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/app/services/auth.py <<'VICBLESS_EOF'
"""Vic signing in, and checking that a request really comes from a signed-in Vic.

There is exactly one account (Vic), so there is no username: just a password. Three secrets live in
AWS (see core/config.py): the password HASH (never the password itself), a "pepper" that makes the
hash useless if the database leaks, and the secret that signs session tokens.
"""

from __future__ import annotations

from ..core import config, security
from ..core.errors import NotConfigured, TooManyAttempts, Unauthorized
from ..core.logs import log
from ..database import login_attempts

NOT_SET_UP = "Sign-in isn't set up yet."


def login(password: str, source: str) -> dict:
    """Checks the password and returns a session token.

    `source` is the caller's network address. After 5 wrong passwords from one address in 15 minutes
    that address is locked out. It is per address on purpose: a global lockout would let a stranger
    keep Vic out of his own dashboard just by guessing wrongly on purpose.
    """
    if login_attempts.login_locked(source):
        raise TooManyAttempts()  # checked first, so a locked-out caller can't keep guessing
    stored = config.params.get("admin-password-hash")
    pepper = config.params.get("pepper")
    secret = config.params.get("jwt-secret")
    if not (stored and pepper and secret):
        raise NotConfigured(NOT_SET_UP)
    if not security.verify_password(password, stored, pepper):
        login_attempts.record_login_failure(source)
        log("login_failed")  # never logs the password or who tried it
        raise Unauthorized("That password isn't right. Check it and try again.")
    login_attempts.clear_login_failures(source)  # a good sign-in wipes the failure count
    log("login_ok")
    return {"token": security.issue_token(secret), "expiresIn": security.SESSION_SECONDS}


def check_bearer(authorization: str | None) -> None:
    """Accepts the raw Authorization header ("Bearer <token>") and raises Unauthorized unless it is a valid session.

    Takes a plain string, not a web request, so this layer stays free of FastAPI.
    """
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized()
    secret = config.params.get("jwt-secret")
    if not secret:
        raise NotConfigured(NOT_SET_UP)
    security.check_token(token.strip(), secret)
VICBLESS_EOF
cat > backend/app/services/blocks.py <<'VICBLESS_EOF'
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
    # Turn the range into the individual 35-minute blocks it covers.
    claims = shop.block_starts_in_range(day, start, end)
    if not claims:
        raise InvalidSlot("Pick times that fall inside opening hours.")
    # The database refuses (Conflict) if any of those blocks already holds a booking or another block-off.
    return blocks_db.create_block(day=day, claims=claims, start=start, end=end, note=data.note or "", whole=data.whole)


def remove_block(block_id: str) -> Block:
    """Opens blocked-off time back up."""
    return blocks_db.delete_block(block_id)
VICBLESS_EOF
cat > backend/app/services/bookings.py <<'VICBLESS_EOF'
"""Booking rules in action: what happens when a customer asks for a time.

This layer decides WHAT should happen and in which order. It calls the shop rules (domain/shop.py)
to ask "is this a valid time?" and the database layer to actually store it. It knows nothing about
web requests or DynamoDB details, which is what keeps it easy to read and easy to test.
"""

from __future__ import annotations

from datetime import date, datetime

from ..core.errors import NotFound, SlotTaken, TooManyBookings, ValidationFailed
from ..database import bookings as bookings_db
from ..database import schedule
from ..domain import shop
from ..domain.models import Booking, new_code
from ..schemas.requests import BookingIn, MoveIn, parse_date_key

# Anti-spam: one phone number can hold at most this many upcoming bookings at a time.
MAX_UPCOMING_PER_PHONE = 3


def get_availability(first: date, last: date) -> dict[str, dict]:
    """Which times are taken, day by day, for the booking page's grid. Works for up to 31 days at once."""
    if last < first:
        raise ValidationFailed("The end date can't be before the start date.")
    if (last - first).days + 1 > shop.MAX_RANGE_DAYS:
        raise ValidationFailed(f"Please ask for {shop.MAX_RANGE_DAYS} days or fewer at a time.")
    return schedule.availability(first, last)


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
      1. is it a time Vic could ever take, and is it open right now?  (shop rules, no database)
      2. does this phone number already hold too many upcoming bookings?  (anti-spam)
      3. try to claim the time. The database refuses if anyone got there first.
    """
    day = parse_date_key(data.dateKey)
    minutes = shop.SERVICES[data.serviceId].minutes  # the length comes from the service, never from the client
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
            "Please call or text Vic if you need to change one."
        )
    try:
        booking = bookings_db.create_booking(
            day=day,
            start=data.start,
            service_id=data.serviceId,
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
    shop.check_movable(day, data.start, before.minutes, now)
    after = bookings_db.move_booking(before, day=day, start=data.start)  # raises SlotTaken if the time is not free
    return before, after
VICBLESS_EOF
cat > backend/app/services/notifications.py <<'VICBLESS_EOF'
"""Sends the emails around a booking. Best effort: a failed email is logged and never fails the booking."""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates


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


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (only if they left an email)."""
    _send_all([lambda owner: templates.customer_cancellation(booking, owner) if booking.email else None])


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (only if they left an email)."""
    _send_all([lambda owner: templates.customer_rescheduled(before, after, owner) if after.email else None])
VICBLESS_EOF
cat > backend/app/services/schedule.py <<'VICBLESS_EOF'
"""The schedule Vic sees for one day."""

from __future__ import annotations

from datetime import date

from ..database import schedule as schedule_db


def day_for_admin(day: date) -> dict:
    """One day for the dashboard: the bookings (with contact details) and the blocked-off times."""
    bookings, blocks = schedule_db.day_schedule(day)
    return {
        "dateKey": day.isoformat(),
        "items": [b.admin_view() for b in bookings],
        "blocks": [b.admin_view() for b in blocks],
    }
VICBLESS_EOF
cat > backend/pytest.ini <<'VICBLESS_EOF'
[pytest]
pythonpath = .
testpaths = tests
filterwarnings =
    ignore::DeprecationWarning
VICBLESS_EOF
cat > backend/requirements-dev.txt <<'VICBLESS_EOF'
-r requirements.txt
pytest==9.1.1
httpx2==2.13.1
moto[dynamodb,ssm]==5.2.3
boto3==1.43.111
cfn-lint==1.57.2
PyYAML==6.0.3
VICBLESS_EOF
cat > backend/requirements.txt <<'VICBLESS_EOF'
fastapi==0.143.0
mangum==0.22.0
pydantic==2.14.0
PyJWT==2.15.1
tzdata==2026.5
VICBLESS_EOF
cat > backend/scripts/hash_password.py <<'VICBLESS_EOF'
#!/usr/bin/env python3
"""Make Vic's sign-in secrets and print the commands that store them in AWS.

    python backend/scripts/hash_password.py --env dev

It asks for Vic's password (typing is hidden), makes a fresh pepper and session secret, hashes the
password with 600,000 rounds, and prints the `aws ssm put-parameter` commands. Nothing is sent anywhere
and nothing is saved to disk. Run the printed commands yourself, then clear your terminal history.
If you re-run it, run ALL the printed commands again: the three values belong together.
"""

import argparse
import getpass
import secrets
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core import security  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()

    password = getpass.getpass("Vic's dashboard password: ")
    if len(password) < 12:
        print("Use at least 12 characters. A few random words works well.", file=sys.stderr)
        return 1
    if getpass.getpass("Type it again: ") != password:
        print("Those did not match.", file=sys.stderr)
        return 1

    pepper = secrets.token_urlsafe(32)
    jwt_secret = secrets.token_urlsafe(48)
    stored = security.hash_password(password, pepper)
    assert security.verify_password(password, stored, pepper)

    print(f"\nRun these {args.env.upper()} commands with your AWS credentials:\n")
    for name, value in (("pepper", pepper), ("jwt-secret", jwt_secret), ("admin-password-hash", stored)):
        print(
            f"aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/{name} "
            f"--type SecureString --overwrite --value={shlex.quote(value)}"
        )
    print(
        f"""
Also set these (once), with your own values:

aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/owner-email --type String --overwrite --value='vic@example.com'
aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/email-from --type String --overwrite --value='Vicbless <onboarding@resend.dev>'
aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/resend-api-key --type SecureString --overwrite --value='re_...'
"""
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
VICBLESS_EOF
cat > backend/tests/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/tests/conftest.py <<'VICBLESS_EOF'
"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock     run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails

Shared test data and shortcuts live in tests/helpers/ (builders, api shortcuts, constants).
"""

from tests.fixtures.api import admin_setup, auth, client  # noqa: F401
from tests.fixtures.aws import atomic_transactions, aws  # noqa: F401
from tests.fixtures.clock import fixed_clock  # noqa: F401
from tests.fixtures.email import sent  # noqa: F401
VICBLESS_EOF
cat > backend/tests/fixtures/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/tests/fixtures/api.py <<'VICBLESS_EOF'
"""The API client, and a signed-in Vic."""

import pytest
from fastapi.testclient import TestClient

from app.core import security
from tests.helpers.aws import put_param
from tests.helpers.constants import ADMIN_PASSWORD, JWT_SECRET, PEPPER


@pytest.fixture
def client():
    """A client that calls the real app in-process (no network). The app is built fresh per test."""
    from app.main import create_app

    return TestClient(create_app())


@pytest.fixture
def admin_setup():
    """Stores Vic's sign-in secrets in the fake Parameter Store, the way hash_password.py + the AWS CLI would."""
    put_param("pepper", PEPPER)
    put_param("jwt-secret", JWT_SECRET)
    put_param("admin-password-hash", security.hash_password(ADMIN_PASSWORD, PEPPER, iterations=1000))


@pytest.fixture
def auth(client, admin_setup):
    """Headers for a signed-in Vic: {"Authorization": "Bearer <token>"}. Signs in for real through the API."""
    response = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['token']}"}
VICBLESS_EOF
cat > backend/tests/fixtures/aws.py <<'VICBLESS_EOF'
"""A fake AWS for every test (moto), with the table built from the real template."""

import boto3
import pytest
from moto import mock_aws

from app.core import config
from tests.helpers.constants import ENVIRONMENT, TEST_TABLE
from tests.helpers.template import table_definition


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
        "EMAIL_PROVIDER": "resend",
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("CORS_ALLOWED_ORIGINS", raising=False)
    config.reset_caches()
    with mock_aws():
        boto3.client("dynamodb").create_table(**table_definition(TEST_TABLE))
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
cat > backend/tests/fixtures/clock.py <<'VICBLESS_EOF'
"""A frozen clock."""

import pytest

from app.domain import shop
from tests.helpers.constants import NOW


@pytest.fixture(autouse=True)
def fixed_clock(monkeypatch):
    """Makes "now" Monday 12 Oct 2026, 10:00 am for every test. Individual tests can pass their own `now`."""
    monkeypatch.setattr(shop, "now_local", lambda: NOW)
VICBLESS_EOF
cat > backend/tests/fixtures/email.py <<'VICBLESS_EOF'
"""Catching emails instead of sending them."""

import pytest

from app.services import notifications
from tests.helpers.aws import put_param


@pytest.fixture
def sent(monkeypatch):
    """A list that fills with every email the app tries to send. Also sets Vic's address, so owner emails go somewhere."""
    box = []

    class Recorder:
        def send(self, message):
            box.append(message)

    monkeypatch.setattr(notifications, "get_sender", lambda: Recorder())
    put_param("owner-email", "vic@example.com", secure=False)
    return box
VICBLESS_EOF
cat > backend/tests/helpers/__init__.py <<'VICBLESS_EOF'

VICBLESS_EOF
cat > backend/tests/helpers/api.py <<'VICBLESS_EOF'
"""Shortcuts for calling the API in tests, so each test reads like the story it tells."""

from .builders import booking_body
from .constants import TUESDAY


def book(client, **over):
    """POST a booking. book(client, start=755) books 12:35 instead of 12:00."""
    return client.post("/api/bookings", json=booking_body(**over))


def busy(client, day: str = TUESDAY) -> list[int]:
    """The taken block starts for one day, as a customer's browser would see them."""
    return client.get(f"/api/availability?from={day}&to={day}").json()[day]["busy"]


def schedule_of(client, auth, day: str = TUESDAY) -> dict:
    """Vic's view of one day (needs the `auth` fixture)."""
    response = client.get(f"/api/admin/schedule?date={day}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()
VICBLESS_EOF
cat > backend/tests/helpers/aws.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/tests/helpers/builders.py <<'VICBLESS_EOF'
"""Builds test data. Each builder has sensible defaults, so a test only spells out what it is about."""

from datetime import date

from app.database import bookings as bookings_db
from app.database import schedule as schedule_db
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
    """The taken block starts for one day, as the database reports them."""
    return schedule_db.availability(day, day)[day.isoformat()]["busy"]
VICBLESS_EOF
cat > backend/tests/helpers/constants.py <<'VICBLESS_EOF'
"""Fixed values the tests share, so every test talks about the same "today", password and table."""

from datetime import datetime

from app.domain import shop

# The tests pretend it is Monday 12 Oct 2026, 10:00 am in the shop's timezone. A fixed "now" means a
# test about "tomorrow" or "14 days ahead" gives the same answer next year as it does today.
NOW = datetime(2026, 10, 12, 10, 0, tzinfo=shop.TIMEZONE)

TEST_TABLE = "vicbless-test"
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
cat > backend/tests/helpers/template.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/tests/test_admin_api.py <<'VICBLESS_EOF'
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
    assert client.get(f"/api/availability?from={D}&to={D}").json()[D] == {"busy": [720, 755], "dayOff": False}
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
cat > backend/tests/test_contract.py <<'VICBLESS_EOF'
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


def test_slot_minutes_and_days_ahead():
    text = source()
    assert int(re.search(r"export const SLOT_MINUTES = (\d+)", text).group(1)) == shop.SLOT_MINUTES
    assert int(re.search(r"export const DAYS_AHEAD = (\d+)", text).group(1)) == shop.DAYS_AHEAD


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


def test_services_match():
    body = block(source(), "export const SERVICES = [", "\n]")
    found = {sid: int(minutes) for sid, minutes in re.findall(r"id:\s*'([^']+)'.*?minutes:\s*(\d+)", body, re.S)}
    assert found, "No services found in the frontend config"
    assert found == {s.id: s.minutes for s in shop.SERVICES.values()}


def test_input_limits_match():
    """The booking form's character limits (and the 0/500 counter) must be the same numbers the API enforces."""
    from app.schemas import requests

    match = re.search(r"export const LIMITS = \{\s*name:\s*(\d+),\s*notes:\s*(\d+)\s*\}", source())
    assert match, "frontend/src/config.js has no LIMITS yet. Run update-vicbless-notes-counter.sh (from inside frontend/) first."
    assert (int(match.group(1)), int(match.group(2))) == (requests.NAME_MAX, requests.NOTES_MAX)
VICBLESS_EOF
cat > backend/tests/test_email.py <<'VICBLESS_EOF'
import io
import json
import urllib.error

import pytest

from app.emailing import EmailMessage, NullSender, get_sender, resend, templates
from app.services import notifications as notify
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_body, booking_model


def test_templates_escape_what_customers_type():
    evil = booking_model(name="<script>alert(1)</script>", notes="<img src=x onerror=alert(1)>", email='a"b@example.com')
    msg = templates.owner_notification(evil, "vic@example.com")
    assert "<script>" not in msg.html and "&lt;script&gt;" in msg.html
    assert "<img" not in msg.html
    assert 'href="mailto:a&quot;b@example.com"' in msg.html


def test_subject_has_no_line_breaks():
    msg = templates.owner_notification(booking_model(name="Bad\r\nBcc: x@evil.com"), "vic@example.com")
    assert "\n" not in msg.subject and "\r" not in msg.subject


def test_customer_confirmation_content():
    msg = templates.customer_confirmation(booking_model(), "vic@example.com")
    assert msg.to == "m@example.com" and msg.reply_to == "vic@example.com"
    assert "Tuesday, October 13 at 12:00 pm" in msg.text and "VB-ABC234" in msg.html and "Men's haircut" in msg.text


def test_owner_notification_replies_go_to_the_customer():
    msg = templates.owner_notification(booking_model(), "vic@example.com")
    assert msg.to == "vic@example.com" and msg.reply_to == "m@example.com"
    assert templates.owner_notification(booking_model(email=""), "vic@example.com").reply_to == ""


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return b'{"id":"1"}'


def message():
    return EmailMessage(to="c@example.com", subject="Hi", text="t", html="<p>t</p>", reply_to="vic@example.com")


def test_resend_request_shape(monkeypatch):
    seen = {}

    def fake(req, timeout):
        seen.update(
            url=req.full_url,
            method=req.get_method(),
            headers=dict(req.header_items()),
            body=json.loads(req.data),
            timeout=timeout,
        )
        return FakeResponse()

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    resend.ResendSender("re_key", "Vicbless <onboarding@resend.dev>").send(message())
    assert seen["url"] == "https://api.resend.com/emails" and seen["method"] == "POST"
    assert seen["headers"]["Authorization"] == "Bearer re_key" and seen["headers"]["User-agent"].startswith("vicbless")
    assert seen["body"] == {
        "from": "Vicbless <onboarding@resend.dev>",
        "to": ["c@example.com"],
        "subject": "Hi",
        "html": "<p>t</p>",
        "text": "t",
        "reply_to": ["vic@example.com"],
    }
    assert seen["timeout"] <= 10


def http_error(code):
    return urllib.error.HTTPError("u", code, "x", {"retry-after": "0"}, io.BytesIO(b"{}"))


def test_resend_retries_once_on_429(monkeypatch):
    calls = []

    def fake(req, timeout):
        calls.append(1)
        if len(calls) == 1:
            raise http_error(429)
        return FakeResponse()

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    monkeypatch.setattr(resend.time, "sleep", lambda s: None)
    resend.ResendSender("k", "f").send(message())
    assert len(calls) == 2


@pytest.mark.parametrize("failure", [http_error(403), http_error(500), urllib.error.URLError("down"), TimeoutError()])
def test_resend_failures_raise_our_error(monkeypatch, failure):
    def fake(req, timeout):
        raise failure

    monkeypatch.setattr(resend.urllib.request, "urlopen", fake)
    with pytest.raises(resend.EmailSendError):
        resend.ResendSender("k", "f").send(message())


def test_factory_without_config_is_null():
    assert isinstance(get_sender(), NullSender)


def test_factory_with_config_is_resend():
    put_param("resend-api-key", "re_key")
    put_param("email-from", "Vicbless <onboarding@resend.dev>", secure=False)
    assert isinstance(get_sender(), resend.ResendSender)


def test_unknown_provider_is_null(monkeypatch):
    monkeypatch.setenv("EMAIL_PROVIDER", "ses")
    assert isinstance(get_sender(), NullSender)


def test_failed_email_never_fails_the_booking(client, monkeypatch):
    class Broken:
        def send(self, m):
            raise RuntimeError("provider down")

    monkeypatch.setattr(notify, "get_sender", lambda: Broken())
    put_param("owner-email", "vic@example.com", secure=False)
    r = client.post("/api/bookings", json=booking_body(email="m@example.com"))
    assert r.status_code == 201


def test_owner_always_notified_customer_only_with_email(client, sent):
    client.post("/api/bookings", json=booking_body())
    assert [m.to for m in sent] == ["vic@example.com"]
    sent.clear()
    client.post("/api/bookings", json=booking_body(start=755, email="m@example.com", phone="5550102222", name="Other One"))
    assert sorted(m.to for m in sent) == ["m@example.com", "vic@example.com"]


def test_no_owner_email_configured_still_confirms_customer(client, monkeypatch):
    box = []

    class Recorder:
        def send(self, m):
            box.append(m)

    monkeypatch.setattr(notify, "get_sender", lambda: Recorder())
    client.post("/api/bookings", json=booking_body(email="m@example.com"))
    assert [m.to for m in box] == ["m@example.com"]
VICBLESS_EOF
cat > backend/tests/test_handler.py <<'VICBLESS_EOF'
import json

from app.handler import lambda_handler


def http_api_event(method, path, body=None, headers=None):
    return {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"content-type": "application/json", **(headers or {})},
        "requestContext": {
            "accountId": "123",
            "apiId": "abc",
            "domainName": "abc.execute-api.us-east-1.amazonaws.com",
            "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "203.0.113.9", "userAgent": "test"},
            "requestId": "r1",
            "stage": "$default",
            "time": "12/Oct/2026:10:00:00 +0000",
            "timeEpoch": 1,
        },
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
    }


def test_health_through_the_lambda_entry_point():
    resp = lambda_handler(http_api_event("GET", "/api/health"), None)
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["status"] == "ok"
    assert resp["headers"]["cache-control"] == "no-store"


def test_docs_404_through_the_lambda_entry_point():
    for path in ("/api/docs", "/docs", "/api/openapi.json"):
        assert lambda_handler(http_api_event("GET", path), None)["statusCode"] == 404


def test_source_ip_reaches_the_app_for_the_lockout(admin_setup):
    for _ in range(5):
        lambda_handler(http_api_event("POST", "/api/admin/login", {"password": "bad"}), None)
    resp = lambda_handler(http_api_event("POST", "/api/admin/login", {"password": "bad"}), None)
    assert resp["statusCode"] == 429
VICBLESS_EOF
cat > backend/tests/test_messages.py <<'VICBLESS_EOF'
"""The words people read. Every error the site can show must be a plain sentence a customer or Vic understands."""

import pytest

from app.schemas import requests
from tests.helpers.api import book
from tests.helpers.constants import ADMIN_PASSWORD, TUESDAY

JARGON = ("Value error", "Input should", "validation error", "pydantic", "Traceback", "NoneType", "KeyError")


def message_of(response) -> str:
    return response.json()["error"]["message"]


def test_bad_email_says_what_a_good_one_looks_like(client):
    r = book(client, email="not-an-email")
    assert r.status_code == 422
    assert message_of(r) == "That email doesn't look right. Use something like name@example.com, or leave it blank."
    assert r.json()["error"]["field"] == "email"


@pytest.mark.parametrize(
    "over,expected",
    [
        ({"name": "A"}, "Please enter your name, between 2 and 50 characters."),
        ({"name": "x" * 51}, "Please enter your name, between 2 and 50 characters."),
        ({"phone": "12345"}, "Please enter a mobile number with at least 10 digits so Vic can reach you."),
        ({"notes": "x" * 501}, "Notes can be up to 500 characters. Please shorten yours a little."),
        ({"serviceId": "free-cut"}, "Please pick a service from the list."),
        ({"dateKey": "2026-02-31"}, "That date isn't valid. Please pick a day from the calendar."),
        ({"start": 5000}, "Please pick a time from the list."),
    ],
)
def test_field_messages_are_friendly(client, over, expected):
    r = book(client, **over)
    assert r.status_code == 422 and message_of(r) == expected


@pytest.mark.parametrize("over", [{"start": "noon"}, {"start": True}, {"serviceId": 5}, {"phone": None}])
def test_even_type_mistakes_have_no_programmer_wording(client, over):
    r = book(client, **over)
    assert r.status_code == 422
    assert not any(word.lower() in message_of(r).lower() for word in JARGON)
    assert message_of(r) == "Some of the details aren't valid. Please check them and try again."


def test_missing_body_has_no_jargon(client):
    r = client.post("/api/bookings", json={})
    assert r.status_code == 422 and not any(w.lower() in message_of(r).lower() for w in JARGON)


def test_wrong_password_message(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": "nope"})
    assert r.status_code == 401
    assert message_of(r) == "That password isn't right. Check it and try again."


def test_empty_password_message(client, admin_setup):
    r = client.post("/api/admin/login", json={"password": ""})
    assert r.status_code == 422 and message_of(r) == "Please enter your password."


def test_lockout_message_says_how_long(client, admin_setup):
    for _ in range(5):
        client.post("/api/admin/login", json={"password": "bad"})
    r = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert r.status_code == 429 and message_of(r) == "Too many tries. Please wait about 15 minutes, then try again."


def test_sign_in_not_set_up_message(client):
    r = client.post("/api/admin/login", json={"password": "x"})
    assert r.status_code == 503 and message_of(r) == "Sign-in isn't set up yet."


def test_signed_out_and_expired_messages(client, admin_setup):
    r = client.get(f"/api/admin/schedule?date={TUESDAY}")
    assert r.status_code == 401 and message_of(r) == "Please sign in to continue."
    r = client.get(f"/api/admin/schedule?date={TUESDAY}", headers={"Authorization": "Bearer garbage"})
    assert message_of(r) == "Your session ended. Please sign in again."


def test_phone_cap_message_mentions_the_limit(client):
    plan = [("2026-10-13", 12 * 60), ("2026-10-15", 11 * 60), ("2026-10-16", 11 * 60)]
    for day, start in plan:
        book(client, dateKey=day, start=start)
    r = book(client, dateKey="2026-10-20", start=12 * 60)
    assert r.status_code == 429 and "3 upcoming bookings" in message_of(r) and "call or text Vic" in message_of(r)


def test_slot_taken_message(client):
    book(client)
    r = book(client, name="Someone Else", phone="5550109999")
    assert message_of(r) == "Sorry, that time was just taken. Please pick another."


def test_name_limit_boundaries(client):
    assert book(client, name="x" * 50).status_code == 201
    assert requests.NAME_MAX == 50 and requests.NAME_MIN == 2


def test_notes_limit_boundaries(client):
    assert book(client, notes="n" * 500).status_code == 201
    assert book(client, start=755, phone="5550102222", notes="n" * 501).status_code == 422


def test_windows_line_breaks_count_once_like_the_browser(client, auth):
    # The browser counts "\r\n" in a textarea as ONE character. This note is exactly 500 to the browser
    # (250 letters + 249 line breaks + 1 more letter). If the API counted \r\n as two it would wrongly refuse it.
    notes = ("a\r\n" * 250)[:-2] + "b"
    assert len(notes) > 500  # 750 raw characters
    assert book(client, notes=notes).status_code == 201
    stored = client.get(f"/api/admin/schedule?date={TUESDAY}", headers=auth).json()["items"][0]["notes"]
    assert "\r" not in stored and len(stored) == 500
    # and one more character is over the limit, as it is for the browser
    assert book(client, start=755, phone="5550102222", notes=notes + "c").status_code == 422


def test_every_error_message_in_the_code_is_a_plain_sentence():
    """No message may end without punctuation, shout, or use words only programmers say."""
    import inspect

    from app.core import errors

    for _, cls in inspect.getmembers(errors, inspect.isclass):
        message = getattr(cls, "default_message", "")
        assert message.endswith((".", "!", "?")), f"{cls.__name__}: {message!r}"
        assert not any(word.lower() in message.lower() for word in JARGON), cls.__name__
VICBLESS_EOF
cat > backend/tests/test_public_api.py <<'VICBLESS_EOF'
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
    assert days["2026-10-14"] == {"busy": [], "dayOff": False}


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
cat > backend/tests/test_repository.py <<'VICBLESS_EOF'
import threading
from datetime import date

import pytest

from app.core.errors import Conflict, NotFound, SlotTaken
from app.database import blocks as blocks_db
from app.database import bookings as bookings_db
from app.database import login_attempts
from app.database import schedule as schedule_db
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
    out = schedule_db.availability(TUE, date(2026, 10, 15))
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
cat > backend/tests/test_reschedule.py <<'VICBLESS_EOF'
"""Vic moving a booking to another time: PATCH /api/admin/bookings/{id}."""

from datetime import date, datetime

import pytest

from app.core.errors import InvalidSlot, SlotTaken
from app.database import bookings as bookings_db
from app.domain import shop
from tests.helpers.api import book, busy, schedule_of
from tests.helpers.builders import make_booking, taken_blocks
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
    assert taken_blocks() == [720, 755]
    moved = bookings_db.move_booking(booking, day=booking.day, start=755)  # now 12:35 and 1:10
    assert taken_blocks() == [755, 790]
    assert moved.id != booking.id and moved.code == booking.code
    assert bookings_db.get_booking(moved.id) is not None and bookings_db.get_booking(booking.id) is None
    # the shared block now belongs to the NEW booking, so cancelling it releases everything (a stale owner would block this)
    bookings_db.cancel_booking(moved.id)
    assert taken_blocks() == []


def test_a_refused_move_changes_nothing_even_when_the_blocks_overlap_the_old_time():
    booking = make_booking(start=720, minutes=70)
    make_booking(start=790, phone="5550102222")  # someone else holds 1:10 pm
    with pytest.raises(SlotTaken):
        bookings_db.move_booking(booking, day=booking.day, start=755)  # would need 12:35 and 1:10
    assert taken_blocks() == [720, 755, 790]
    assert bookings_db.get_booking(booking.id) is not None


def test_moving_a_booking_that_was_just_cancelled_is_not_found():
    from app.core.errors import NotFound

    booking = make_booking()
    bookings_db.cancel_booking(booking.id)
    with pytest.raises(NotFound):
        bookings_db.move_booking(booking, day=booking.day, start=755)
    assert taken_blocks() == []  # the move must not have created anything


def test_moved_items_carry_the_new_ttl_and_phone_index_keys():
    from tests.helpers.aws import raw_table

    booking = make_booking(phone="5550101234")
    moved = bookings_db.move_booking(booking, day=date(2026, 10, 15), start=660)
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
    shop.check_movable(day_ok, shop.grid_starts(day_ok)[0], 35, NOW)
    day_bad = last + timedelta(days=1)
    while not shop.is_open(day_bad):
        day_bad += timedelta(days=1)
    with pytest.raises(InvalidSlot):
        shop.check_movable(day_bad, shop.grid_starts(day_bad)[0], 35, NOW)
VICBLESS_EOF
cat > backend/tests/test_scripts.py <<'VICBLESS_EOF'
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
VICBLESS_EOF
cat > backend/tests/test_security.py <<'VICBLESS_EOF'
import time

import jwt
import pytest

from app.core import security
from app.core.errors import NotConfigured, Unauthorized

SECRET = "s" * 40


def test_hash_format_and_default_rounds():
    assert security.ITERATIONS == 600_000
    h = security.hash_password("pw", "pepper")
    algo, rounds, salt, digest = h.split("$")
    assert (algo, rounds) == ("pbkdf2_sha256", "600000") and salt and digest


def test_verify_roundtrip_with_default_rounds():
    h = security.hash_password("pw", "pepper")
    assert security.verify_password("pw", h, "pepper")
    assert not security.verify_password("wrong", h, "pepper")


def test_pepper_matters():
    h = security.hash_password("pw", "pepper", iterations=1000)
    assert not security.verify_password("pw", h, "other-pepper")


def test_salt_is_random():
    assert security.hash_password("pw", "p", iterations=10) != security.hash_password("pw", "p", iterations=10)


@pytest.mark.parametrize(
    "stored",
    [
        "",
        "garbage",
        "a$b$c",
        "pbkdf2_sha256$x$y$z",
        "md5$1000$AAAA$AAAA",
        "pbkdf2_sha256$0$AAAA$AAAA",
        "pbkdf2_sha256$99999999$AAAA$AAAA",
    ],
)
def test_malformed_hashes_are_just_false(stored):
    assert security.verify_password("pw", stored, "pepper") is False


def test_token_roundtrip_and_expiry():
    token = security.issue_token(SECRET)
    security.check_token(token, SECRET)
    old = security.issue_token(SECRET, now=time.time() - 13 * 3600)
    with pytest.raises(Unauthorized):
        security.check_token(old, SECRET)


def test_token_tamper_and_wrong_secret():
    token = security.issue_token(SECRET)
    with pytest.raises(Unauthorized):
        security.check_token(token, "t" * 40)
    with pytest.raises(Unauthorized):
        security.check_token(token + "x", SECRET)


def test_alg_none_and_wrong_subject_rejected():
    none_token = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "iat": 1, "exp": int(time.time()) + 99}, None, algorithm="none"
    )
    with pytest.raises(Unauthorized):
        security.check_token(none_token, SECRET)
    other = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "bob", "iat": 1, "exp": int(time.time()) + 99},
        SECRET,
        algorithm="HS256",
    )
    with pytest.raises(Unauthorized):
        security.check_token(other, SECRET)


def test_short_secret_is_not_configured():
    with pytest.raises(NotConfigured):
        security.issue_token("short")
    with pytest.raises(NotConfigured):
        security.check_token("x", "")
VICBLESS_EOF
cat > backend/tests/test_shop.py <<'VICBLESS_EOF'
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
    grid = shop.grid_starts(TUE)
    assert grid[0] == at(12) and grid[1] == at(12, 35)
    assert len(grid) == 10
    assert grid[-1] + 35 <= at(18)


def test_thursday_friday_have_13_blocks():
    assert len(shop.grid_starts(date(2026, 10, 15))) == 13
    assert len(shop.grid_starts(date(2026, 10, 16))) == 13


def test_saturday_has_two_windows_and_a_gap():
    grid = shop.grid_starts(SAT)
    assert grid[0] == at(9) and at(12, 35) in grid
    assert at(12) not in grid
    for s in grid:
        assert (at(9) <= s and s + 35 <= at(12)) or (at(12, 35) <= s and s + 35 <= at(17))


def test_closed_days_have_no_grid():
    assert shop.grid_starts(WED) == [] and shop.grid_starts(SUN) == []


def test_blocks_for():
    assert [shop.blocks_for(m) for m in (30, 35, 36, 70, 71)] == [1, 1, 2, 2, 3]


def test_fits_matches_grid_and_closing():
    assert shop.fits(TUE, at(12), 35)
    assert not shop.fits(TUE, at(12, 10), 35)  # off the grid
    assert not shop.fits(TUE, at(17, 50), 35)  # would run past closing
    assert not shop.fits(WED, at(12), 35)
    assert not shop.fits(SAT, at(12), 35)  # inside Saturday's gap


def test_multi_block_must_stay_inside_one_window():
    assert shop.fits(SAT, at(9), 70)
    assert not shop.fits(SAT, at(11, 20), 70)  # second block would cross noon


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
    assert shop.block_starts_in_range(TUE, at(12), at(12, 35) + 35) == [at(12), at(12, 35)]
    assert shop.block_starts_in_range(TUE, at(12), at(12)) == []
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
VICBLESS_EOF
cat > backend/tests/test_structure.py <<'VICBLESS_EOF'
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
    "services": {"core", "domain", "schemas", "database", "emailing"},
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
cat > backend/tests/test_template.py <<'VICBLESS_EOF'
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
    paths = {e["Properties"]["Path"] for e in events.values()}
    assert paths == {"/api", "/api/{proxy+}", "/api/admin/login"}


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
cat > infra/template.yaml <<'VICBLESS_EOF'
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

# --- keep the deploy workflow in step (only if it exists) ---
WF=""
[ -f .github/workflows/deploy-backend.yml ] && WF=.github/workflows/deploy-backend.yml
[ -z "$WF" ] && [ -f .github/workflows-paused/deploy-backend.yml ] && WF=.github/workflows-paused/deploy-backend.yml
if [ -n "$WF" ]; then
  cat > "${TMPDIR:-/tmp}/vicbless_patch_workflow.py" <<'VICBLESS_EOF'
import re, sys
path = sys.argv[1]
s = open(path).read()
orig = s
s = s.replace('/health"', '/api/health"') if '/api/health"' not in s else s
s = re.sub(r'^[ \t]*echo "Docs: \$URL/docs"\n', '', s, flags=re.M)
s = re.sub(r'(--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM)(?! CAPABILITY_AUTO_EXPAND)', r'\1 CAPABILITY_AUTO_EXPAND', s)
if s == orig:
    print("deploy-backend.yml already up to date")
else:
    open(path, "w").write(s)
    print("deploy-backend.yml updated: health URL is /api/health, docs lines removed, CAPABILITY_AUTO_EXPAND added")
VICBLESS_EOF
  python3 "${TMPDIR:-/tmp}/vicbless_patch_workflow.py" "$WF"
  rm -f "${TMPDIR:-/tmp}/vicbless_patch_workflow.py"
else
  echo "No deploy-backend.yml yet. Run add-vicbless-backend-workflow.sh to create it (when you are ready to deploy)."
fi

# --- install and test ---
PY=python3
command -v python3.12 >/dev/null 2>&1 && PY=python3.12
echo "Using $($PY --version). (The Lambda runs 3.12.)"
$PY -m venv backend/.venv
backend/.venv/bin/pip install --quiet --upgrade pip
backend/.venv/bin/pip install --quiet -r backend/requirements-dev.txt
echo ""
echo "Checking the template..."
backend/.venv/bin/cfn-lint infra/template.yaml
echo "Running the tests..."
backend/.venv/bin/pytest backend/tests/ -q -p no:logging

echo ""
echo "Done. The backend is written and every test passed. Now run these yourself:"
echo "  git status          # new: backend/*, infra/template.yaml (backend/.venv is ignored)"
echo "  git add -A"
echo "  git commit -m \"Add booking backend (FastAPI, DynamoDB, Resend bridge)\""
echo "  git push origin dev"
echo ""
echo "Before the first dev deploy you still need (see backend/README.md): artifacts bucket, SSM parameters"
echo "(python backend/scripts/hash_password.py --env dev), and the deploy role's backend permissions."
