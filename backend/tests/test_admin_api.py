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
