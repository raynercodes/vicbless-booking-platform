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
