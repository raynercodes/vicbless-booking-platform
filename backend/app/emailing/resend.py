"""Resend bridge. Delete this file when AWS SES is approved (see emailing/__init__.py).

Uses only the standard library, so it adds nothing to the Lambda package.
API: POST https://api.resend.com/emails  (docs: resend.com/docs/api-reference/emails/send-email)
Fields: from, to, subject, html, text, reply_to. Rate limit: 10 requests/second, answered with 429.
Until a domain is verified in Resend, it only delivers from onboarding@resend.dev to the account owner's own address.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

from ..core.logs import log
from . import EmailMessage

API_URL = "https://api.resend.com/emails"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 5


class EmailSendError(Exception):
    """Raised when Resend could not deliver. The caller (services/notifications.py) logs it and carries on."""

    pass


class ResendSender:
    def __init__(self, api_key: str, sender: str):
        self.api_key = api_key
        self.sender = sender

    def _payload(self, message: EmailMessage) -> dict:
        """Our EmailMessage -> the JSON body Resend expects."""
        payload = {
            "from": self.sender,
            "to": [message.to],
            "subject": message.subject,
            "html": message.html,
            "text": message.text,
        }
        if message.reply_to:
            payload["reply_to"] = [message.reply_to]
        return payload

    def _request(self, message: EmailMessage) -> urllib.request.Request:
        """The full HTTP request. The API key travels only in the Authorization header, and is never logged."""
        return urllib.request.Request(
            API_URL,
            data=json.dumps(self._payload(message)).encode(),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
            },
        )

    def send(self, message: EmailMessage) -> None:
        """Send one email. Retries once if Resend says to slow down. Raises EmailSendError on failure."""
        # At most two tries: Resend allows 10 requests/second, and one booking sends two emails back to back.
        for attempt in (1, 2):
            try:
                with urllib.request.urlopen(self._request(message), timeout=TIMEOUT_SECONDS) as response:
                    response.read()
                return
            except urllib.error.HTTPError as err:
                if err.code == 429 and attempt == 1:
                    try:
                        wait = float(err.headers.get("retry-after", "1"))
                    except (TypeError, ValueError):
                        wait = 1.0
                    time.sleep(min(max(wait, 0.2), 1.5))
                    continue
                log("email_failed", provider="resend", status=err.code)
                raise EmailSendError(f"Resend answered {err.code}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as err:
                log("email_failed", provider="resend", reason=type(err).__name__)
                raise EmailSendError("Could not reach Resend") from None
