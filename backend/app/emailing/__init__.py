"""Sending email. The rest of the app only knows about EmailSender and EmailMessage.

Today the provider is Resend (emailing/resend.py), a bridge while AWS SES waits for production access.
When SES is ready: add emailing/ses.py with the same `send` method, add it to get_sender() below,
set EMAIL_PROVIDER=ses, then delete resend.py and its line here. Nothing else changes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..core import config
from ..core.logs import log


@dataclass(frozen=True)
class EmailMessage:
    """One email, independent of which provider sends it. `reply_to` is who a reply should go to."""

    to: str
    subject: str
    text: str
    html: str
    reply_to: str = ""


class EmailSender(Protocol):
    """Anything with a send() method counts as a provider (Resend now, SES later). Nothing else is required."""

    def send(self, message: EmailMessage) -> None: ...


class NullSender:
    """Used when no provider is set up. Logs that an email would have gone out, and sends nothing."""

    def send(self, message: EmailMessage) -> None:
        log("email_skipped", reason="no_provider")


def get_sender() -> EmailSender:
    """Picks the provider named by the EMAIL_PROVIDER setting. If its keys aren't set up yet, emails are skipped
    (and logged) rather than breaking bookings. That is what lets the app run before Resend is configured.
    """
    provider = config.get_settings().email_provider
    if provider == "resend":
        from .resend import ResendSender

        key = config.params.get("resend-api-key")
        sender = config.params.get("email-from")
        if key and sender:
            return ResendSender(api_key=key, sender=sender)
        log("email_not_configured", provider="resend")
        return NullSender()
    return NullSender()
