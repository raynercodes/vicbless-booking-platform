"""Sending text messages (SMS). The rest of the app only knows about SmsSender and SmsMessage.

Today the provider is Textbelt (texting/textbelt.py): simple, no sign-up verification, pay per text. It is a bridge,
like the email one. When Vic's account at AWS (End User Messaging / SNS) is approved: add texting/aws.py with the same
`send` method, add it to get_sender() below, set SMS_PROVIDER=aws, then delete textbelt.py and its line here.
Nothing else changes.

Only US mobile numbers are texted (10 digits). Anything else is skipped and logged, never an error.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Protocol

from ..core import config
from ..core.logs import log


@dataclass(frozen=True)
class SmsMessage:
    """One text, independent of which provider sends it. `to` is a 10 digit US number."""

    to: str
    body: str


class SmsSender(Protocol):
    """Anything with a send() method counts as a provider (Textbelt now, AWS later)."""

    def send(self, message: SmsMessage) -> None: ...


class NullSender:
    """Used when no provider is set up. Logs that a text would have gone out, and sends nothing."""

    def send(self, message: SmsMessage) -> None:
        log("sms_skipped", reason="no_provider")


def us_number(raw: str | None) -> str | None:
    """'(555) 010-0777', '+1 555 010 0777' or '5550100777' -> '5550100777'. None when it is not a 10 digit US number."""
    digits = re.sub(r"\D", "", raw or "")
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    return digits if len(digits) == 10 and digits[0] not in "01" else None


def get_sender() -> SmsSender:
    """Picks the provider named by the SMS_PROVIDER setting. If its key isn't set up yet, texts are skipped (and
    logged) rather than breaking bookings. That is what lets the app run before Textbelt is configured."""
    provider = config.get_settings().sms_provider
    if provider == "textbelt":
        from .textbelt import TextbeltSender

        key = config.params.get("textbelt-key")
        if key:
            return TextbeltSender(api_key=key)
        log("sms_not_configured", provider="textbelt")
        return NullSender()
    return NullSender()
