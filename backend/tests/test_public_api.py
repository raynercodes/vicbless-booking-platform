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
