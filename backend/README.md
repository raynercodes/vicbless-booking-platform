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
