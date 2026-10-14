"""The shop's settings in tests."""

import dataclasses

import pytest

from app.domain import shop

# The shop's real defaults (Monday and Tuesday are 45 minutes). Captured at import, before any test changes them,
# so the few tests about the defaults themselves can still see the real ones.
REAL_DEFAULTS = shop.DEFAULT_SETTINGS

# What most tests run with: every day 35 minutes, the grid the first tests were written for. They are about HOW booking
# works (claims, races, emails), not about which length a weekday has, so one familiar grid keeps them easy to read.
# Tests about the 45 minute days, mixed lengths, and saving settings set their own.
CLASSIC = dataclasses.replace(REAL_DEFAULTS, slot_minutes=(35,) * 7)


@pytest.fixture(autouse=True)
def classic_grid(monkeypatch):
    """Runs around every test: until a test saves its own settings, the shop's settings are CLASSIC."""
    monkeypatch.setattr(shop, "DEFAULT_SETTINGS", CLASSIC)
