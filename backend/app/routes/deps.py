"""The web-only glue the routes share.

Why this is not part of services/: these two functions read things off a web Request (a header, the
caller's address). Services are not allowed to import FastAPI (a test enforces it), so the part that
needs a Request stays here and stays tiny. The real work, checking a session token, lives in
services/auth.py.
"""

from __future__ import annotations

from fastapi import Request

from ..services import auth


def require_admin(request: Request) -> None:
    """Runs before the body is read, so a stranger gets 401 whatever they send."""
    auth.check_bearer(request.headers.get("authorization"))


def source_address(request: Request) -> str:
    """The caller's network address as API Gateway reports it (used only for the sign-in lockout)."""
    return request.client.host if request.client else "unknown"
