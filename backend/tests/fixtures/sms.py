"""Catching texts instead of sending them."""

import pytest

from app.services import notifications
from tests.helpers.aws import put_param

OWNER_PHONE = "(555) 010-0777"


@pytest.fixture
def texts(monkeypatch):
    """A list that fills with every text the app tries to send. Also sets Vic's number, so owner texts go somewhere."""
    box = []

    class Recorder:
        def send(self, message):
            box.append(message)

    monkeypatch.setattr(notifications, "get_sms_sender", lambda: Recorder())
    put_param("owner-phone", OWNER_PHONE, secure=False)
    return box
