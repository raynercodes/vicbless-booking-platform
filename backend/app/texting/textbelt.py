"""Textbelt bridge. Delete this file when the AWS SMS account is approved (see texting/__init__.py).

Uses only the standard library, so it adds nothing to the Lambda package.
API: POST https://textbelt.com/text  (docs.textbelt.com), form fields: phone, message, key, sender.
Answer: JSON { success, quotaRemaining, textId } or { success: false, error }.
Textbelt answers STOP replies by itself. The `sender` field names the business, which their rules ask for.
The key is the Textbelt key bought for Vic, kept in Parameter Store (/vicbless/<env>/textbelt-key). The special key
"textbelt" is Textbelt's free test key (about one text a day for everyone), good only to check that it is wired up.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from ..core.brand import BRAND_NAME
from ..core.logs import log
from . import SmsMessage

API_URL = "https://textbelt.com/text"
USER_AGENT = "vicbless-backend/1.0"
TIMEOUT_SECONDS = 5


class SmsSendError(Exception):
    """Raised when Textbelt could not deliver. The caller (services/notifications.py) logs it and carries on."""

    pass


class TextbeltSender:
    def __init__(self, api_key: str):
        self.api_key = api_key

    def _request(self, message: SmsMessage) -> urllib.request.Request:
        """The full HTTP request. The key goes only in the form body, and neither it nor the number is ever logged."""
        form = urllib.parse.urlencode(
            {"phone": message.to, "message": message.body, "key": self.api_key, "sender": BRAND_NAME.title()}
        )
        return urllib.request.Request(
            API_URL,
            data=form.encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT},
        )

    def send(self, message: SmsMessage) -> None:
        """Send one text. Raises SmsSendError when Textbelt refuses it or cannot be reached."""
        try:
            with urllib.request.urlopen(self._request(message), timeout=TIMEOUT_SECONDS) as response:
                answer = json.loads(response.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            log("sms_failed", provider="textbelt", status=err.code)
            raise SmsSendError(f"Textbelt answered {err.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            log("sms_failed", provider="textbelt", reason=type(err).__name__)
            raise SmsSendError("Could not reach Textbelt") from None
        if not isinstance(answer, dict) or not answer.get("success"):
            # Textbelt's own reason ("Out of quota", "Invalid phone number") is safe to log: it has no personal details.
            reason = str(answer.get("error", "unknown"))[:80] if isinstance(answer, dict) else "unknown"
            log("sms_failed", provider="textbelt", reason=reason)
            raise SmsSendError("Textbelt refused the text")
        remaining = answer.get("quotaRemaining")
        if isinstance(remaining, (int, float)) and remaining <= 10:
            log("sms_quota_low", provider="textbelt", remaining=remaining)  # a nudge in the logs to buy more credit
