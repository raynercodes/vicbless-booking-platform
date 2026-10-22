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
    public = client.get("/api/settings").json()
    assert public.pop("payOnline") is False  # no Stripe keys here
    assert public == saved  # customers see the same thing at once


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
