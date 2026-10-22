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
