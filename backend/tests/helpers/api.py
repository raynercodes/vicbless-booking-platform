"""Shortcuts for calling the API in tests, so each test reads like the story it tells."""

from .builders import booking_body
from .constants import TUESDAY


def book(client, **over):
    """POST a booking. book(client, start=755) books 12:35 instead of 12:00."""
    return client.post("/api/bookings", json=booking_body(**over))


def busy(client, day: str = TUESDAY) -> list[int]:
    """The taken block starts for one day, as a customer's browser would see them."""
    return client.get(f"/api/availability?from={day}&to={day}").json()[day]["busy"]


def schedule_of(client, auth, day: str = TUESDAY) -> dict:
    """Vic's view of one day (needs the `auth` fixture)."""
    response = client.get(f"/api/admin/schedule?date={day}", headers=auth)
    assert response.status_code == 200, response.text
    return response.json()
