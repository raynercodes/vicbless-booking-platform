"""Catching emails instead of sending them."""

import pytest

from app.services import notifications
from tests.helpers.aws import put_param


@pytest.fixture
def sent(monkeypatch):
    """A list that fills with every email the app tries to send. Also sets Vic's address, so owner emails go somewhere."""
    box = []

    class Recorder:
        def send(self, message):
            box.append(message)

    monkeypatch.setattr(notifications, "get_sender", lambda: Recorder())
    put_param("owner-email", "vic@example.com", secure=False)
    return box
