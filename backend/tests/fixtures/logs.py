"""Reading what the app writes to its logs."""

import json
import logging

import pytest

from app.core import logs


@pytest.fixture
def logged():
    """A list of every log line written during the test, each as a dict like {"event": "sms_sent", "kind": ...}."""
    lines: list[dict] = []

    class Collect(logging.Handler):
        def emit(self, record):
            lines.append(json.loads(record.getMessage()))

    logs.setup()
    handler = Collect()
    logging.getLogger("vicbless").addHandler(handler)
    yield lines
    logging.getLogger("vicbless").removeHandler(handler)


def events(lines, name):
    """The log lines with this event name."""
    return [line for line in lines if line["event"] == name]
