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
