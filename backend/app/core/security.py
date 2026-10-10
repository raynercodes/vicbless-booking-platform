"""Admin sign-in: password hashing and session tokens.

Password: HMAC with a secret pepper first (so a stolen database row alone cannot be cracked), then
PBKDF2-HMAC-SHA256 with 600,000 rounds (the current OWASP number). That many rounds is CPU work,
which is why the Lambda has 1024 MB (more memory means more CPU).
Stored as:  pbkdf2_sha256$600000$<salt base64>$<hash base64>

Session: a signed token (JWT, HS256) that lasts 12 hours. The site sends it in the Authorization header.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import time

import jwt

from .errors import NotConfigured, Unauthorized

ITERATIONS = 600_000
ALGORITHM = "pbkdf2_sha256"
SESSION_SECONDS = 12 * 60 * 60
ISSUER = "vicbless"
AUDIENCE = "vicbless-admin"
SUBJECT = "vic"
MIN_SECRET_LENGTH = 32


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()


def _prehash(password: str, pepper: str) -> bytes:
    """Mixes the secret pepper into the password first (HMAC), so the stored hash can't be cracked without it."""
    return hmac.new(pepper.encode(), password.encode(), hashlib.sha256).digest()


def hash_password(password: str, pepper: str, *, iterations: int = ITERATIONS, salt: bytes | None = None) -> str:
    salt = salt or os.urandom(16)  # a fresh random salt per hash, so two identical passwords never look alike
    digest = hashlib.pbkdf2_hmac("sha256", _prehash(password, pepper), salt, iterations)
    return f"{ALGORITHM}${iterations}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, stored: str, pepper: str) -> bool:
    # A malformed stored value just means "wrong password"; it must never crash the sign-in.
    try:
        algorithm, rounds, salt_b64, hash_b64 = stored.split("$")
        iterations = int(rounds)
        salt = base64.b64decode(salt_b64, validate=True)
        expected = base64.b64decode(hash_b64, validate=True)
    except (ValueError, TypeError):
        return False
    # The rounds cap stops a corrupted value from making the server compute for minutes.
    if algorithm != ALGORITHM or not 1 <= iterations <= 5_000_000:
        return False
    # Recompute with the stored salt and rounds, then compare in constant time (compare_digest) so the
    # time taken doesn't leak how many characters matched.
    actual = hashlib.pbkdf2_hmac("sha256", _prehash(password, pepper), salt, iterations)
    return hmac.compare_digest(actual, expected)


def issue_token(secret: str, *, now: float | None = None) -> str:
    if len(secret or "") < MIN_SECRET_LENGTH:
        raise NotConfigured("Sign-in isn't set up yet.")
    # Claims: who issued it (iss), who it is for (aud), whose it is (sub), when (iat), and when it dies (exp).
    issued = int(time.time() if now is None else now)
    claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": SUBJECT, "iat": issued, "exp": issued + SESSION_SECONDS}
    return jwt.encode(claims, secret, algorithm="HS256")


def check_token(token: str, secret: str) -> None:
    """Returns None if the token is valid; raises Unauthorized if not."""
    if len(secret or "") < MIN_SECRET_LENGTH:
        raise NotConfigured("Sign-in isn't set up yet.")
    # PyJWT checks the signature AND every claim below. algorithms=["HS256"] is fixed, so a forged
    # token that claims "alg: none" is refused.
    try:
        jwt.decode(
            token,
            secret,
            algorithms=["HS256"],
            audience=AUDIENCE,
            issuer=ISSUER,
            subject=SUBJECT,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )
    except jwt.PyJWTError:
        raise Unauthorized("Your session ended. Please sign in again.") from None
