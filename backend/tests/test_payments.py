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
