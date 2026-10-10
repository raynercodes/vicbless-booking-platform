"""A frozen clock."""

import pytest

from app.domain import shop
from tests.helpers.constants import NOW


@pytest.fixture(autouse=True)
def fixed_clock(monkeypatch):
    """Makes "now" Monday 12 Oct 2026, 10:00 am for every test. Individual tests can pass their own `now`."""
    monkeypatch.setattr(shop, "now_local", lambda: NOW)
