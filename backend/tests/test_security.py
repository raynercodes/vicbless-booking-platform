import time

import jwt
import pytest

from app.core import security
from app.core.errors import NotConfigured, Unauthorized

SECRET = "s" * 40


def test_hash_format_and_default_rounds():
    assert security.ITERATIONS == 600_000
    h = security.hash_password("pw", "pepper")
    algo, rounds, salt, digest = h.split("$")
    assert (algo, rounds) == ("pbkdf2_sha256", "600000") and salt and digest


def test_verify_roundtrip_with_default_rounds():
    h = security.hash_password("pw", "pepper")
    assert security.verify_password("pw", h, "pepper")
    assert not security.verify_password("wrong", h, "pepper")


def test_pepper_matters():
    h = security.hash_password("pw", "pepper", iterations=1000)
    assert not security.verify_password("pw", h, "other-pepper")


def test_salt_is_random():
    assert security.hash_password("pw", "p", iterations=10) != security.hash_password("pw", "p", iterations=10)


@pytest.mark.parametrize(
    "stored",
    [
        "",
        "garbage",
        "a$b$c",
        "pbkdf2_sha256$x$y$z",
        "md5$1000$AAAA$AAAA",
        "pbkdf2_sha256$0$AAAA$AAAA",
        "pbkdf2_sha256$99999999$AAAA$AAAA",
    ],
)
def test_malformed_hashes_are_just_false(stored):
    assert security.verify_password("pw", stored, "pepper") is False


def test_token_roundtrip_and_expiry():
    token = security.issue_token(SECRET)
    security.check_token(token, SECRET)
    old = security.issue_token(SECRET, now=time.time() - 13 * 3600)
    with pytest.raises(Unauthorized):
        security.check_token(old, SECRET)


def test_token_tamper_and_wrong_secret():
    token = security.issue_token(SECRET)
    with pytest.raises(Unauthorized):
        security.check_token(token, "t" * 40)
    with pytest.raises(Unauthorized):
        security.check_token(token + "x", SECRET)


def test_alg_none_and_wrong_subject_rejected():
    none_token = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "vic", "iat": 1, "exp": int(time.time()) + 99}, None, algorithm="none"
    )
    with pytest.raises(Unauthorized):
        security.check_token(none_token, SECRET)
    other = jwt.encode(
        {"iss": "vicbless", "aud": "vicbless-admin", "sub": "bob", "iat": 1, "exp": int(time.time()) + 99},
        SECRET,
        algorithm="HS256",
    )
    with pytest.raises(Unauthorized):
        security.check_token(other, SECRET)


def test_short_secret_is_not_configured():
    with pytest.raises(NotConfigured):
        security.issue_token("short")
    with pytest.raises(NotConfigured):
        security.check_token("x", "")
