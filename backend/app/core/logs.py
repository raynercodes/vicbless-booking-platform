"""Structured JSON logs for CloudWatch. Never log names, phone numbers or emails."""

from __future__ import annotations

import contextvars
import json
import logging
import sys

request_id: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

_logger = logging.getLogger("vicbless")


def setup() -> None:
    if _logger.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(handler)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False


def log(event: str, level: int = logging.INFO, **fields) -> None:
    setup()
    _logger.log(level, json.dumps({"event": event, "requestId": request_id.get(), **fields}, default=str))
