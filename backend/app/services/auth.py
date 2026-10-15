"""Vic signing in, and checking that a request really comes from a signed-in Vic.

There is exactly one account (Vic), so there is no username: just a password. Three secrets live in
AWS (see core/config.py): the password HASH (never the password itself), a "pepper" that makes the
hash useless if the database leaks, and the secret that signs session tokens.
"""

from __future__ import annotations

from ..core import config, security
from ..core.errors import NotConfigured, TooManyAttempts, Unauthorized
from ..core.logs import log
from ..database import login_attempts

NOT_SET_UP = "Sign-in isn't set up yet."


def login(password: str, source: str) -> dict:
    """Checks the password and returns a session token.

    `source` is the caller's network address. After 5 wrong passwords from one address in 15 minutes
    that address is locked out. It is per address on purpose: a global lockout would let a stranger
    keep Vic out of his own dashboard just by guessing wrongly on purpose.
    """
    if login_attempts.login_locked(source):
        raise TooManyAttempts()  # checked first, so a locked-out caller can't keep guessing
    stored = config.params.get("admin-password-hash")
    pepper = config.params.get("pepper")
    secret = config.params.get("jwt-secret")
    if not (stored and pepper and secret):
        raise NotConfigured(NOT_SET_UP)
    if not security.verify_password(password, stored, pepper):
        login_attempts.record_login_failure(source)
        log("login_failed")  # never logs the password or who tried it
        raise Unauthorized("That password isn't right. Check it and try again.")
    login_attempts.clear_login_failures(source)  # a good sign-in wipes the failure count
    log("login_ok")
    return {"token": security.issue_token(secret), "expiresIn": security.SESSION_SECONDS}


def check_bearer(authorization: str | None) -> None:
    """Accepts the raw Authorization header ("Bearer <token>") and raises Unauthorized unless it is a valid session.

    Takes a plain string, not a web request, so this layer stays free of FastAPI.
    """
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        log("auth_rejected", reason="no_token")
        raise Unauthorized()
    secret = config.params.get("jwt-secret")
    if not secret:
        raise NotConfigured(NOT_SET_UP)
    try:
        security.check_token(token.strip(), secret)
    except Unauthorized:
        log("auth_rejected", reason="bad_or_expired_token")  # a dashboard left open past its 12 hours shows up here
        raise
