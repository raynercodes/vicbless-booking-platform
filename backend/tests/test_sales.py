"""Vic's sales log: lines he adds by hand in the dashboard, listed back for his spreadsheet page."""

import pytest

from app.domain.sales import new_sale_id, parse_sale_id
from tests.helpers.constants import MONDAY, NOW, TUESDAY
from datetime import date

TODAY = MONDAY  # the tests pretend it is Monday 12 Oct 2026


def sale_body(**over) -> dict:
    body = {"serviceId": "mens-cut", "priceMode": "standard", "payment": "shop", "clientName": "Marcus Jones"}
    body.update(over)
    return body


def add(client, auth, **over):
    return client.post("/api/admin/sales", headers=auth, json=sale_body(**over))


def log_of(client, auth) -> list[dict]:
    r = client.get("/api/admin/sales", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()["sales"]


def test_the_log_starts_empty(client, auth):
    assert log_of(client, auth) == []


def test_a_standard_sale_uses_the_listed_price(client, auth):
    r = add(client, auth)
    assert r.status_code == 201, r.text
    [row] = log_of(client, auth)
    assert row["clientName"] == "Marcus Jones" and row["serviceName"] == "Men's haircut" and row["serviceId"] == "mens-cut"
    assert row["amountCents"] == 5500 and row["customPrice"] is False and row["payment"] == "shop"
    assert row["dateKey"] == TODAY and row["id"] == r.json()["id"] and row["createdAt"].startswith("2026-10-12")


def test_after_hours_cuts_can_be_logged_at_its_price(client, auth):
    add(client, auth, serviceId="after-hours", payment="online")
    [row] = log_of(client, auth)
    assert row["serviceName"] == "After Hours Cuts" and row["amountCents"] == 7000 and row["payment"] == "online"


def test_a_custom_price_is_kept_as_typed(client, auth):
    add(client, auth, priceMode="custom", amountCents=6250)
    [row] = log_of(client, auth)
    assert row["amountCents"] == 6250 and row["customPrice"] is True and row["serviceName"] == "Men's haircut"


def test_a_one_off_service_needs_a_typed_price(client, auth):
    assert add(client, auth, serviceId=None, serviceName="Line up only").status_code == 422  # no listed price
    r = add(client, auth, serviceId=None, serviceName="Line up only", priceMode="custom", amountCents=1500)
    assert r.status_code == 201
    [row] = log_of(client, auth)
    assert row["serviceId"] == "" and row["serviceName"] == "Line up only" and row["amountCents"] == 1500


def test_the_screens_own_price_and_name_are_not_trusted(client, auth):
    add(client, auth, serviceName="Something else", amountCents=1)  # a standard sale ignores both
    [row] = log_of(client, auth)
    assert row["serviceName"] == "Men's haircut" and row["amountCents"] == 5500


@pytest.mark.parametrize(
    "bad",
    [
        {"serviceId": "nope"},  # not one of his services
        {"serviceId": None, "serviceName": ""},  # no service at all
        {"priceMode": "custom"},  # no price typed
        {"priceMode": "custom", "amountCents": -1},
        {"priceMode": "custom", "amountCents": 1_000_000},
        {"clientName": ""},
        {"clientName": "x" * 61},
        {"payment": "cash"},
        {"note": "x" * 121},
        {"dateKey": "2026-10-13"},  # tomorrow
        {"dateKey": "2025-10-01"},  # over a year back
        {"dateKey": "not-a-date"},
    ],
)
def test_bad_entries_are_refused(client, auth, bad):
    assert add(client, auth, **bad).status_code == 422
    assert log_of(client, auth) == []


def test_a_sale_can_be_dated_earlier(client, auth):
    add(client, auth, dateKey="2026-10-09", note="walk-in")
    [row] = log_of(client, auth)
    assert row["dateKey"] == "2026-10-09" and row["note"] == "walk-in"


def test_the_log_lists_newest_day_first(client, auth):
    add(client, auth, clientName="Older", dateKey="2026-10-01")
    add(client, auth, clientName="Newest", dateKey=TODAY)
    add(client, auth, clientName="Middle", dateKey="2026-10-08")
    assert [r["clientName"] for r in log_of(client, auth)] == ["Newest", "Middle", "Older"]


def test_a_sale_is_removed_by_its_id(client, auth):
    first = add(client, auth, clientName="Keep").json()
    gone = add(client, auth, clientName="Remove").json()
    r = client.delete(f"/api/admin/sales/{gone['id']}", headers=auth)
    assert r.status_code == 200
    assert [x["id"] for x in log_of(client, auth)] == [first["id"]]
    assert client.delete(f"/api/admin/sales/{gone['id']}", headers=auth).status_code == 404  # already gone
    assert client.delete("/api/admin/sales/not-an-id", headers=auth).status_code == 404


def test_the_log_does_not_disturb_the_schedule(client, auth):
    add(client, auth)
    day = client.get(f"/api/admin/schedule?date={TODAY}", headers=auth).json()
    assert day["items"] == [] and day["blocks"] == []
    assert client.get(f"/api/availability?from={TODAY}&to={TODAY}").json()[TODAY]["busy"] == []


def test_the_log_needs_sign_in(client, admin_setup):
    assert client.get("/api/admin/sales").status_code == 401
    assert client.post("/api/admin/sales", json=sale_body()).status_code == 401
    assert client.delete("/api/admin/sales/2026-10-12.sale.abcdef12").status_code == 401


def test_sale_ids_carry_their_day():
    sid = new_sale_id(date(2026, 10, 12))
    assert parse_sale_id(sid) == date(2026, 10, 12)
    assert parse_sale_id("2026-13-45.sale.abcdef12") is None
    assert parse_sale_id("2026-10-12.sale.XYZ") is None
    assert parse_sale_id("") is None


def test_the_log_lives_in_its_own_table_and_never_expires(client, auth):
    from tests.helpers.aws import raw_sales_table, raw_table

    add(client, auth)
    sales = raw_sales_table().scan()["Items"]
    assert len(sales) == 1 and "expiresAt" not in sales[0] and sales[0]["pk"] == "SALES#vic"
    assert not [i for i in raw_table().scan()["Items"] if "sale" in str(i.get("sk", "")).lower()]  # nothing in the bookings table


# --- editing a line ----------------------------------------------------------------------------------------


def edit(client, auth, sale_id, **over):
    return client.put(f"/api/admin/sales/{sale_id}", headers=auth, json=sale_body(**over))


def test_a_line_can_be_edited_in_place(client, auth):
    first = add(client, auth, clientName="Typo Tim", note="old").json()
    r = edit(client, auth, first["id"], clientName="Tim Fixed", serviceId="mens-design", payment="online", note="new")
    assert r.status_code == 200, r.text
    [row] = log_of(client, auth)
    assert row["id"] == first["id"] and r.json() == row  # the same day keeps the same id
    assert row["clientName"] == "Tim Fixed" and row["serviceName"] == "Men's haircut with design" and row["amountCents"] == 6500
    assert row["payment"] == "online" and row["note"] == "new" and row["createdAt"] == first["createdAt"]


def test_an_edit_can_switch_to_a_custom_price_and_back(client, auth):
    sale = add(client, auth).json()
    edit(client, auth, sale["id"], priceMode="custom", amountCents=6250)
    assert (log_of(client, auth)[0]["amountCents"], log_of(client, auth)[0]["customPrice"]) == (6250, True)
    edit(client, auth, sale["id"])
    assert (log_of(client, auth)[0]["amountCents"], log_of(client, auth)[0]["customPrice"]) == (5500, False)


def test_an_edit_can_change_a_service_into_a_one_off(client, auth):
    sale = add(client, auth).json()
    edit(client, auth, sale["id"], serviceId=None, serviceName="Line up only", priceMode="custom", amountCents=1500)
    [row] = log_of(client, auth)
    assert row["serviceId"] == "" and row["serviceName"] == "Line up only" and row["amountCents"] == 1500


def test_changing_the_day_moves_the_line_and_gives_it_a_new_id(client, auth):
    sale = add(client, auth).json()
    r = edit(client, auth, sale["id"], dateKey="2026-10-09")
    assert r.status_code == 200, r.text
    [row] = log_of(client, auth)  # one line, not two
    assert row["dateKey"] == "2026-10-09" and row["id"] != sale["id"] and row["id"].startswith("2026-10-09.sale.")
    assert r.json()["id"] == row["id"] and row["createdAt"] == sale["createdAt"]
    assert edit(client, auth, sale["id"]).status_code == 404  # the old id is gone


def test_an_edit_that_leaves_the_day_out_keeps_the_lines_own_day(client, auth):
    sale = add(client, auth, dateKey="2026-10-09").json()
    r = edit(client, auth, sale["id"], clientName="Same Day")
    assert r.status_code == 200 and log_of(client, auth)[0]["dateKey"] == "2026-10-09" and r.json()["id"] == sale["id"]


def test_a_bad_edit_changes_nothing(client, auth):
    sale = add(client, auth).json()
    for bad in ({"clientName": ""}, {"dateKey": "2026-10-13"}, {"priceMode": "custom"}, {"serviceId": "nope"}):
        assert edit(client, auth, sale["id"], **bad).status_code == 422
    assert log_of(client, auth) == [sale]


def test_editing_a_missing_line_is_not_found(client, auth):
    assert edit(client, auth, "2026-10-12.sale.abcdef12").status_code == 404
    assert edit(client, auth, "not-an-id").status_code == 404


def test_editing_needs_sign_in(client, admin_setup):
    assert client.put("/api/admin/sales/2026-10-12.sale.abcdef12", json=sale_body()).status_code == 401


# --- the one-time move from the bookings table --------------------------------------------------------------


def old_line(day="2026-10-10", name="Old Olly"):
    return {
        "pk": "STAFF#vic", "sk": f"SALE#{day}#{day}.sale.0a0b0c0d", "kind": "sale", "id": f"{day}.sale.0a0b0c0d", "date": day,
        "serviceId": "mens-cut", "serviceName": "Men's haircut", "amountCents": 5500, "customPrice": False, "payment": "shop",
        "clientName": name, "note": "", "createdAt": f"{day}T15:00:00+00:00",
    }  # fmt: skip


def test_lines_saved_in_the_bookings_table_move_to_the_sales_table(client, auth):
    import runpy
    from pathlib import Path

    from tests.helpers.aws import raw_sales_table, raw_table

    script = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts" / "migrate_sales_table.py"))
    raw_table().put_item(Item=old_line())
    assert script["migrate"](False) == {"moved": 1, "already_there": 0}  # a dry run changes nothing
    assert len(raw_table().scan()["Items"]) == 1 and raw_sales_table().scan()["Items"] == []
    assert script["migrate"](True) == {"moved": 1, "already_there": 0}
    assert [i for i in raw_table().scan()["Items"] if i["sk"].startswith("SALE#")] == []
    [row] = log_of(client, auth)  # and the dashboard sees it
    assert row["clientName"] == "Old Olly" and row["dateKey"] == "2026-10-10" and row["amountCents"] == 5500
    assert script["migrate"](True) == {"moved": 0, "already_there": 0}  # nothing left, safe to run again


def test_a_move_that_stopped_halfway_finishes_cleanly(client, auth):
    import runpy
    from pathlib import Path

    from tests.helpers.aws import raw_sales_table, raw_table

    script = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts" / "migrate_sales_table.py"))
    line = old_line()
    raw_table().put_item(Item=line)
    copy = {k: v for k, v in line.items() if k not in ("kind",)} | {"pk": "SALES#vic", "sk": line["sk"].removeprefix("SALE#")}
    raw_sales_table().put_item(Item=copy)  # copied, but the old one was never removed
    assert script["migrate"](True) == {"moved": 0, "already_there": 1}
    assert len(log_of(client, auth)) == 1 and [i for i in raw_table().scan()["Items"] if i["sk"].startswith("SALE#")] == []
