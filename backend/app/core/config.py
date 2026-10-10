"""Settings and secrets.

Plain settings come from environment variables set by the SAM template. Secrets and owner settings
live in SSM Parameter Store under /vicbless/<environment>/ and are cached briefly in memory.
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass

from . import aws

# How long a secret stays cached in memory. Reading from AWS on every request would be slow and cost money;
# five minutes means a changed secret takes effect within five minutes without a redeploy.
PARAM_TTL_SECONDS = 300


@dataclass(frozen=True)
class Settings:
    """Plain (non-secret) settings, set as environment variables by the SAM template."""

    environment: str
    table_name: str
    cors_origins: tuple[str, ...]
    email_provider: str

    @property
    def ssm_prefix(self) -> str:
        return f"/vicbless/{self.environment}"


def get_settings() -> Settings:
    """Reads the settings fresh each time (cheap), so tests can change environment variables freely."""
    origins = tuple(o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip())
    return Settings(
        environment=os.environ.get("ENVIRONMENT", "dev"),
        table_name=os.environ.get("TABLE_NAME", "vicbless-dev"),
        cors_origins=origins,
        email_provider=os.environ.get("EMAIL_PROVIDER", "resend").strip().lower(),
    )


class ParamStore:
    """Reads SSM parameters with a short cache. A missing parameter returns None and is cached too."""

    def __init__(self, ttl: int = PARAM_TTL_SECONDS):
        self.ttl = ttl
        self._cache: dict[str, tuple[float, str | None]] = {}
        self._lock = threading.Lock()

    def get(self, name: str) -> str | None:
        full = f"{get_settings().ssm_prefix}/{name}"
        now = time.monotonic()
        with self._lock:
            hit = self._cache.get(full)
            if hit and now - hit[0] < self.ttl:
                return hit[1]
        value: str | None
        try:
            value = aws.ssm_client().get_parameter(Name=full, WithDecryption=True)["Parameter"]["Value"]
        except Exception as exc:  # missing parameter, no permission, or AWS hiccup
            code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")
            if code != "ParameterNotFound":
                # a real failure (permissions, AWS hiccup) is not cached as "missing" for five minutes
                raise
            value = None
        with self._lock:
            self._cache[full] = (now, value)
        return value

    def reset(self) -> None:
        with self._lock:
            self._cache.clear()


params = ParamStore()


def reset_caches() -> None:
    """Forget cached clients and parameters. Tests call this between cases."""
    aws.reset_clients()
    params.reset()
