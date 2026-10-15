#!/usr/bin/env bash
# Vicbless: much more useful CloudWatch logging
# Run from the REPO ROOT:  bash vicbless-more-logging.sh
#
# One log line for every email and text that is considered (sent, skipped and WHY, or failed), plus booking, cancel, move,
# block-off, settings, sign-in rejections, refused requests, reminder sweeps, missing/denied AWS settings, and where a crash happened.
# No names, phone numbers, emails or keys are ever logged. Needs the texts-and-reminders installer applied first.
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
"""Plumbing every request goes through: error JSON, security headers, request ids, body size, CORS.

Nothing in here is about bookings. It makes sure every response, success or failure, looks the same
and carries the same safety headers.
"""

from __future__ import annotations

import logging
import time
import traceback
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
        # Why a request was refused (slot_taken, invalid_slot, unauthorized ...), so CloudWatch shows more than a status number.
        log("api_error", logging.WARNING if exc.status >= 500 else logging.INFO, code=exc.code, status=exc.status, field=exc.field or "")
        return error_response(exc.status, exc.code, exc.message, **extra)

    @app.exception_handler(RequestValidationError)
    async def _invalid(_: Request, exc: RequestValidationError):
        # Only the first problem is reported, so the person fixes one thing at a time.
        first = exc.errors()[0] if exc.errors() else {}
        field = ".".join(str(p) for p in first.get("loc", ()) if p not in ("body", "query"))
        log("validation_failed", field=field, kind=first.get("type", ""))  # which field, never what was typed
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
                    # Where it happened (file:line function, innermost last) but never the error's own text, which could
                    # contain what a customer typed.
                    frames = [f"{f.filename.split('/')[-1]}:{f.lineno} {f.name}" for f in traceback.extract_tb(exc.__traceback__)][-8:]
                    log("unhandled_error", logging.ERROR, errorType=type(exc).__name__, path=request.url.path, frames=frames)
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
cat > "$STAGE/3" <<'VICBLESS_EOF'
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
                    log("email_accepted", provider="resend", status=getattr(response, "status", 200), attempt=attempt)
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
cat > "$STAGE/4" <<'VICBLESS_EOF'
"""AWS Lambda entry point. Two kinds of events arrive here:

  - web requests from API Gateway (HTTP API) -> Mangum -> FastAPI
  - a scheduled event from EventBridge every 15 minutes -> the reminder sweep (services/reminders.py)
"""

from mangum import Mangum

from .core.logs import log
from .main import app
from .services import reminders

_web = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    # A scheduled EventBridge event says source "aws.events". Web requests never do.
    if isinstance(event, dict) and event.get("source") == "aws.events":
        log("scheduled_event", kind="reminders")  # proves the 15 minute timer is firing
        return reminders.send_due()
    return _web(event, context)
VICBLESS_EOF
cat > "$STAGE/5" <<'VICBLESS_EOF'
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
        log("auth_rejected", reason="no_token")
        raise Unauthorized()
    secret = config.params.get("jwt-secret")
    if not secret:
        raise NotConfigured(NOT_SET_UP)
    try:
        security.check_token(token.strip(), secret)
    except Unauthorized:
        log("auth_rejected", reason="bad_or_expired_token")  # a dashboard left open past its 12 hours shows up here
        raise
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
from ..core.errors import NotFound, SlotTaken, TooManyBookings, ValidationFailed
from ..core.logs import log
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
            log("booking_replayed", bookingId=replay.id)
            return replay, False
        log("booking_refused", reason="too_many_upcoming")
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
            log("booking_replayed", bookingId=replay.id)  # the same request arrived twice; the first one stands
            return replay, False
        log("booking_refused", reason="slot_taken", date=data.dateKey, start=data.start)
        raise
    log(
        "booking_created",
        bookingId=booking.id,
        serviceId=booking.service_id,
        minutes=booking.minutes,
        hasEmail=bool(booking.email),
        smsConsent=booking.sms_consent,
    )
    return booking, True


def cancel_booking(booking_id: str) -> Booking:
    """Vic cancels a booking. Frees every block it held, and returns it so the customer can be told."""
    booking = bookings_db.cancel_booking(booking_id)
    log("booking_cancelled", bookingId=booking.id, smsConsent=booking.sms_consent, hasEmail=bool(booking.email))
    return booking


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
    log("booking_moved", fromId=before.id, toId=after.id, minutes=minutes)
    return before, after
VICBLESS_EOF
cat > "$STAGE/8" <<'VICBLESS_EOF'
"""Sends the emails and texts around a booking. Best effort: a failed one is logged and never fails the booking.

Vic is texted at his own number (the `owner-phone` setting) about new bookings. A customer is texted only if they ticked
"text me" when booking, and emailed only if they left an email address.

Every message that is considered leaves ONE line in the logs, so "why did nobody get a text?" can be answered in CloudWatch:
  email_sent / sms_sent       it went to the provider and the provider accepted it (to=owner or customer, kind=what for)
  email_skipped / sms_skipped it was not sent, and reason says why (no_owner_phone, no_consent, bad_number, ...)
  email_error / sms_error     the provider refused it or could not be reached
Names, phone numbers and email addresses are never logged.
"""

from __future__ import annotations

from ..core import config
from ..core.logs import log
from ..domain.models import Booking
from ..emailing import EmailMessage, get_sender, templates
from ..texting import SmsMessage, us_number
from ..texting import get_sender as get_sms_sender
from ..texting import templates as sms_templates


class Skip(Exception):
    """Raised by a builder that has nothing to send. `reason` is what is written to the log."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _send_all(items) -> None:
    """Builds and sends each email on its own. `items` are (kind, to, builder); a builder gets Vic's address and returns the
    message, or raises Skip(reason). One failing never stops the others, and none can fail the booking."""
    try:
        owner = config.params.get("owner-email") or ""
        sender = get_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("email_setup_failed", reason=type(exc).__name__)
        return
    provider = type(sender).__name__
    for kind, to, build in items:
        try:
            message: EmailMessage = build(owner)
            sender.send(message)
            log("email_sent", kind=kind, to=to, provider=provider)
        except Skip as skip:
            log("email_skipped", kind=kind, to=to, reason=skip.reason)
        except Exception as exc:
            log("email_error", kind=kind, to=to, provider=provider, reason=type(exc).__name__)


def _need_owner(owner: str) -> str:
    if not owner:
        raise Skip("no_owner_email")
    return owner


def _need_email(booking: Booking) -> None:
    if not booking.email:
        raise Skip("no_customer_email")


def booking_created(booking: Booking) -> None:
    """Vic always hears about a new booking; the customer gets a confirmation only if they left an email."""
    _send_all(
        [
            ("new_booking", "owner", lambda owner: templates.owner_notification(booking, _need_owner(owner))),
            ("confirmation", "customer", lambda owner: (_need_email(booking), templates.customer_confirmation(booking, owner))[1]),
        ]
    )
    texts_for_created(booking)


def booking_cancelled(booking: Booking) -> None:
    """Tells the customer their appointment was cancelled (by email and/or text, whichever they chose)."""
    _send_all([("cancellation", "customer", lambda owner: (_need_email(booking), templates.customer_cancellation(booking, owner))[1])])
    texts_for_cancelled(booking)


def booking_moved(before: Booking, after: Booking) -> None:
    """Tells the customer their appointment moved (by email and/or text, whichever they chose)."""
    _send_all([("rescheduled", "customer", lambda owner: (_need_email(after), templates.customer_rescheduled(before, after, owner))[1])])
    texts_for_moved(before, after)


def _send_texts(items) -> None:
    """Builds and sends each text on its own. `items` are (kind, to, builder); a builder gets Vic's number and returns
    (number, text), or raises Skip(reason)."""
    try:
        owner = us_number(config.params.get("owner-phone"))
        sender = get_sms_sender()
    except Exception as exc:  # parameter store trouble should not break a booking
        log("sms_setup_failed", reason=type(exc).__name__)
        return
    provider = type(sender).__name__
    for kind, to, build in items:
        try:
            number, body = build(owner)
            sender.send(SmsMessage(to=number, body=body))
            log("sms_sent", kind=kind, to=to, provider=provider)
        except Skip as skip:
            log("sms_skipped", kind=kind, to=to, reason=skip.reason)
        except Exception as exc:
            log("sms_error", kind=kind, to=to, provider=provider, reason=type(exc).__name__)


def _to_owner(owner: str | None, body: str):
    if not owner:
        raise Skip("no_owner_phone")  # the owner-phone setting is missing or not a 10 digit US number
    return owner, body


def _to_customer(booking: Booking, body: str):
    """(number, text) for a customer who agreed to texts and gave a US number. Otherwise Skip says which."""
    if not booking.sms_consent:
        raise Skip("no_consent")
    number = us_number(booking.phone)
    if not number:
        raise Skip("bad_number")
    return number, body


def texts_for_created(booking: Booking) -> None:
    _send_texts(
        [
            ("new_booking", "owner", lambda owner: _to_owner(owner, sms_templates.owner_new_booking(booking))),
            ("confirmation", "customer", lambda owner: _to_customer(booking, sms_templates.customer_confirmation(booking))),
        ]
    )


def texts_for_cancelled(booking: Booking) -> None:
    _send_texts([("cancellation", "customer", lambda owner: _to_customer(booking, sms_templates.customer_cancellation(booking)))])


def texts_for_moved(before: Booking, after: Booking) -> None:
    _send_texts([("rescheduled", "customer", lambda owner: _to_customer(after, sms_templates.customer_rescheduled(before, after)))])


def booking_reminder(booking: Booking) -> None:
    """The reminder before an appointment: an email if they left one, a text if they agreed to texts."""
    _send_all([("reminder", "customer", lambda owner: (_need_email(booking), templates.customer_reminder(booking, owner))[1])])
    _send_texts([("reminder", "customer", lambda owner: _to_customer(booking, sms_templates.customer_reminder(booking)))])
VICBLESS_EOF
cat > "$STAGE/9" <<'VICBLESS_EOF'
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
cat > "$STAGE/10" <<'VICBLESS_EOF'
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
    }
VICBLESS_EOF
cat > "$STAGE/11" <<'VICBLESS_EOF'
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
        log("sms_accepted", provider="textbelt", textId=str(answer.get("textId", ""))[:40], quotaRemaining=remaining)
        if isinstance(remaining, (int, float)) and remaining <= 10:
            log("sms_quota_low", provider="textbelt", remaining=remaining)  # a nudge in the logs to buy more credit
VICBLESS_EOF
cat > "$STAGE/12" <<'VICBLESS_EOF'
"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock, classic_grid   run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails
    texts                catches outgoing texts (and sets Vic's number)
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
VICBLESS_EOF
cat > "$STAGE/13" <<'VICBLESS_EOF'
"""Reading what the app writes to its logs."""

import json
import logging

import pytest

from app.core import logs


@pytest.fixture
def logged():
    """A list of every log line written during the test, each as a dict like {"event": "sms_sent", "kind": ...}."""
    lines: list[dict] = []

    class Collect(logging.Handler):
        def emit(self, record):
            lines.append(json.loads(record.getMessage()))

    logs.setup()
    handler = Collect()
    logging.getLogger("vicbless").addHandler(handler)
    yield lines
    logging.getLogger("vicbless").removeHandler(handler)


def events(lines, name):
    """The log lines with this event name."""
    return [line for line in lines if line["event"] == name]
VICBLESS_EOF
cat > "$STAGE/14" <<'VICBLESS_EOF'
"""The logs answer "what happened?" in CloudWatch, without ever containing what a customer typed."""

import pytest

from app.core import config
from app.services import notifications, reminders
from tests.fixtures.logs import events
from tests.fixtures.sms import OWNER_PHONE
from tests.helpers.api import book, schedule_of
from tests.helpers.aws import put_param
from tests.helpers.builders import booking_body
from tests.helpers.constants import TUESDAY


def reasons(lines, event):
    return sorted((line["to"], line["kind"], line.get("reason")) for line in events(lines, event))


# --- who was texted, and why not ------------------------------------------------------------------------------


def test_a_text_that_goes_out_is_logged(client, texts, logged):
    book(client, smsConsent=True)
    sent = sorted((e["to"], e["kind"]) for e in events(logged, "sms_sent"))
    assert sent == [("customer", "confirmation"), ("owner", "new_booking")]
    assert events(logged, "sms_sent")[0]["provider"] == "Recorder"


def test_a_customer_who_did_not_agree_is_logged_as_no_consent(client, texts, logged):
    book(client)
    assert reasons(logged, "sms_skipped") == [("customer", "confirmation", "no_consent")]


def test_a_missing_owner_phone_is_logged(client, texts, logged):
    put_param("owner-phone", " ", secure=False)
    book(client, smsConsent=True)
    assert ("owner", "new_booking", "no_owner_phone") in reasons(logged, "sms_skipped")


def test_a_number_that_cannot_be_texted_is_logged(client, texts, logged):
    book(client, phone="+44 7700 900123", smsConsent=True)
    assert ("customer", "confirmation", "bad_number") in reasons(logged, "sms_skipped")


def test_no_key_at_all_explains_itself(client, logged):
    put_param("owner-phone", OWNER_PHONE, secure=False)
    book(client, smsConsent=True)
    assert events(logged, "sms_not_configured")  # nothing texted because there is no Textbelt key
    assert events(logged, "param_missing") and "textbelt-key" in {e["name"] for e in events(logged, "param_missing")}


def test_a_provider_that_fails_is_logged_as_an_error(client, logged, monkeypatch):
    from app.texting.textbelt import SmsSendError

    class Broken:
        def send(self, message):
            raise SmsSendError("down")

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Broken())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    assert book(client).status_code == 201
    error = events(logged, "sms_error")[0]
    assert error["kind"] == "new_booking" and error["reason"] == "SmsSendError" and error["provider"] == "Broken"


# --- emails -----------------------------------------------------------------------------------------------------


def test_emails_are_logged_like_texts(client, sent, logged):
    book(client, email="a@example.com")
    assert sorted((e["to"], e["kind"]) for e in events(logged, "email_sent")) == [("customer", "confirmation"), ("owner", "new_booking")]
    logged.clear()
    book(client, start=12 * 60 + 35, phone="5550106666")
    assert ("customer", "confirmation", "no_customer_email") in reasons(logged, "email_skipped")


# --- the story of a booking -----------------------------------------------------------------------------------


def test_a_booking_leaves_a_trail(client, auth, sent, texts, logged):
    assert book(client, smsConsent=True, email="a@example.com").status_code == 201
    created = events(logged, "booking_created")[0]
    assert created["smsConsent"] is True and created["hasEmail"] is True and created["minutes"] == 35
    assert created["bookingId"].startswith("2026-10-13.1200.")
    item = schedule_of(client, auth)["items"][0]
    client.patch(f"/api/admin/bookings/{item['id']}", headers=auth, json={"dateKey": "2026-10-15", "start": 660})
    moved = events(logged, "booking_moved")[0]
    assert moved["fromId"] == item["id"] and moved["toId"].startswith("2026-10-15.")
    client.delete(f"/api/admin/bookings/{moved['toId']}", headers=auth)
    assert events(logged, "booking_cancelled")[0]["bookingId"] == moved["toId"]


def test_a_refused_booking_says_why(client, logged):
    book(client)
    book(client, name="Other Person", phone="5550108888")
    assert any(e["reason"] == "slot_taken" for e in events(logged, "booking_refused"))
    codes = [e["code"] for e in events(logged, "api_error")]
    assert "slot_taken" in codes


def test_a_second_identical_request_is_logged_as_a_replay(client, logged):
    book(client)
    book(client)
    assert events(logged, "booking_replayed")


def test_a_validation_failure_names_the_field_but_not_the_value(client, logged):
    book(client, phone="123", name="Secret Person")
    failure = events(logged, "validation_failed")[0]
    assert failure["field"] == "phone"
    assert "Secret" not in str(logged) and "123" not in str([e for e in logged if e["event"] == "validation_failed"])


def test_blocks_and_settings_are_logged(client, auth, logged):
    from tests.test_settings import settings_body

    r = client.post("/api/admin/blocks", headers=auth, json={"dateKey": TUESDAY, "start": 720, "end": 780})
    client.delete(f"/api/admin/blocks/{r.json()['id']}", headers=auth)
    client.put("/api/admin/settings", headers=auth, json=settings_body())
    assert events(logged, "block_created")[0]["units"] == 12 and events(logged, "block_removed")
    saved = events(logged, "settings_saved")[0]
    assert saved["services"] == 5 and saved["reminderHours"] == [24, 2]


def test_a_rejected_dashboard_call_is_logged(client, auth, logged):  # `auth` sets up the sign-in secrets
    client.get("/api/admin/settings")
    client.get("/api/admin/settings", headers={"Authorization": "Bearer nonsense"})
    assert [e["reason"] for e in events(logged, "auth_rejected")] == ["no_token", "bad_or_expired_token"]


# --- reminders --------------------------------------------------------------------------------------------------


def test_the_sweep_reports_what_it_looked_at(sent, texts, logged):
    from tests.test_reminders import appointment, ny

    appointment()
    reminders.send_due(ny(12, 12, 10))
    sweep = events(logged, "reminders_swept")[0]
    assert sweep["examined"] == 1 and sweep["sent"] == 1 and sweep["reminderHours"] == [24, 2]
    sending = events(logged, "reminder_sending")[0]
    assert sending["tag"] == "24h" and sending["smsConsent"] is True


def test_a_skipped_reminder_says_why(sent, texts, logged):
    from tests.test_reminders import appointment, ny

    appointment(updated=ny(12, 13))
    reminders.send_due(ny(12, 13, 15))
    assert events(logged, "reminder_skipped")[0]["reason"] == "past_when_booked"


def test_the_scheduled_timer_is_logged(logged):
    from app.handler import lambda_handler

    lambda_handler({"source": "aws.events"}, None)
    assert events(logged, "scheduled_event")


# --- surprises ----------------------------------------------------------------------------------------------------


def test_an_unexpected_crash_logs_where_but_not_what(client, logged, monkeypatch):
    from app.services import bookings

    def boom(*args, **kwargs):
        raise RuntimeError("customer typed Secret Person 5550101234")

    monkeypatch.setattr(bookings, "create_booking", boom)
    from app.routes import public

    monkeypatch.setattr(public.bookings, "create_booking", boom)
    assert book(client).status_code == 500
    crash = events(logged, "unhandled_error")[0]
    assert crash["errorType"] == "RuntimeError" and any("boom" in f for f in crash["frames"])
    assert "Secret" not in str(logged) and "5550101234" not in str(logged)


def test_a_parameter_store_failure_is_logged(logged, monkeypatch):
    from app.core import aws

    class Denied:
        def get_parameter(self, **kwargs):
            from botocore.exceptions import ClientError

            raise ClientError({"Error": {"Code": "AccessDeniedException"}}, "GetParameter")

    monkeypatch.setattr(aws, "ssm_client", lambda: Denied())
    config.params.reset()
    with pytest.raises(Exception):
        config.params.get("textbelt-key")
    error = events(logged, "param_error")[0]
    assert error["name"] == "textbelt-key" and error["code"] == "AccessDeniedException"
VICBLESS_EOF
cat > "$STAGE/15" <<'VICBLESS_EOF'
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
    assert "sms_quota_low" in [event for event, _ in seen]
    assert "sms_accepted" in [event for event, _ in seen]


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
export STAGE FORCE="${FORCE:-}"
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"])
force = os.environ.get("FORCE") == "1"
MANIFEST = json.loads("[{\"path\": \"backend/README.md\", \"base\": \"72df08394c614093c70183b15d7980fbb1fd6caeaddbd94b688abca865d7fc9a\", \"new\": 0}, {\"path\": \"backend/app/core/config.py\", \"base\": \"783f52575dc46c234862e1188630fcf28990238d5b05b7feda47300b4bdeb5c7\", \"new\": 1}, {\"path\": \"backend/app/core/web.py\", \"base\": \"f47e2bc34ec451091a5116949d2e6be4bad0c2b6dcf1def920fa2921bc31715c\", \"new\": 2}, {\"path\": \"backend/app/emailing/resend.py\", \"base\": \"5b6490f0764e4babb29d887a023bc95a44745e1cde0b427967bd61a61391435f\", \"new\": 3}, {\"path\": \"backend/app/handler.py\", \"base\": \"babec49951e5d2c1bb4cd723107df2e0964ea5f520b80db25e51a378004cdbbf\", \"new\": 4}, {\"path\": \"backend/app/services/auth.py\", \"base\": \"c6a10a195820578e4ecea7c152125045bda343d66be58cb13228ecb1dffe850b\", \"new\": 5}, {\"path\": \"backend/app/services/blocks.py\", \"base\": \"c61c6930f3a7406810649f6690e1d270e8a379a158ec812055ffb0ce667ffb83\", \"new\": 6}, {\"path\": \"backend/app/services/bookings.py\", \"base\": \"1f79d9229c8823d3bbafbd0bfa51f01655bc6fb17980bb702f8fa9a4bd8d2ff3\", \"new\": 7}, {\"path\": \"backend/app/services/notifications.py\", \"base\": \"63f47b62bd44e8433b7cf2e6b1411ae154a1ed81c6146bba1cc0e7ca167cffc0\", \"new\": 8}, {\"path\": \"backend/app/services/reminders.py\", \"base\": \"9e87f785dcc71aea7d8b6ae9dcb9993714f8d4a1435ffea3c67559f22d204d79\", \"new\": 9}, {\"path\": \"backend/app/services/settings.py\", \"base\": \"45b7ee9cee9a82e26bf9fe5b4efc1d931ea4469d01151622585d9d27de2653be\", \"new\": 10}, {\"path\": \"backend/app/texting/textbelt.py\", \"base\": \"bd2d1f8bc08949371c0e8d66cd8bbe5195c16bd2352ab5aa9c1074c948f128a3\", \"new\": 11}, {\"path\": \"backend/tests/conftest.py\", \"base\": \"a919dcdf3df7f898cfe6cae76094afc5e0f5de5733856a528a031da8bf72e253\", \"new\": 12}, {\"path\": \"backend/tests/fixtures/logs.py\", \"base\": null, \"new\": 13}, {\"path\": \"backend/tests/test_logging.py\", \"base\": null, \"new\": 14}, {\"path\": \"backend/tests/test_texting.py\", \"base\": \"00696945c0748701c91fdb97e4cc9370450166d6b0c9c87da1a5c090e3bc184c\", \"new\": 15}]")

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
echo "Next: commit, push to dev, then see backend/README.md > Reading the logs for CloudWatch queries."
