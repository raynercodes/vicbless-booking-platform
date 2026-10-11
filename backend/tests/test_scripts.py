"""The helper script Vic's password is set up with. It runs once, by hand, so a break would only show up on launch day."""

import re
import runpy
import shlex
import sys
from pathlib import Path

import pytest

from app.core import security

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hash_password.py"


def run_script(monkeypatch, capsys, answers, env="dev"):
    """Runs hash_password.py as if typed at a terminal, answering its two password prompts."""
    typed = iter(answers)
    monkeypatch.setattr("getpass.getpass", lambda prompt="": next(typed))
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--env", env])
    code = None
    try:
        runpy.run_path(str(SCRIPT), run_name="__main__")
    except SystemExit as done:
        code = done.code
    return code, capsys.readouterr()


def stored_values(output):
    """{'pepper': ..., 'jwt-secret': ..., 'admin-password-hash': ...} read back out of the printed aws commands."""
    found = {}
    for line in output.splitlines():
        m = re.search(r"--name /vicbless/dev/(pepper|jwt-secret|admin-password-hash) .*--value=(.*)$", line)
        if m:
            found[m.group(1)] = shlex.split(m.group(2))[0]
    return found


def test_the_printed_hash_logs_vic_in_with_the_printed_pepper(monkeypatch, capsys):
    code, out = run_script(monkeypatch, capsys, ["a long dashboard password", "a long dashboard password"])
    assert code == 0, out.err
    values = stored_values(out.out)
    assert set(values) == {"pepper", "jwt-secret", "admin-password-hash"}
    assert security.verify_password("a long dashboard password", values["admin-password-hash"], values["pepper"])
    assert not security.verify_password("a different password!", values["admin-password-hash"], values["pepper"])
    assert values["admin-password-hash"].startswith("pbkdf2_sha256$600000$")  # the real strength, not the fast test one


def test_every_run_makes_a_fresh_pepper_and_session_secret(monkeypatch, capsys):
    _, first = run_script(monkeypatch, capsys, ["a long dashboard password"] * 2)
    _, second = run_script(monkeypatch, capsys, ["a long dashboard password"] * 2)
    a, b = stored_values(first.out), stored_values(second.out)
    assert a["pepper"] != b["pepper"] and a["jwt-secret"] != b["jwt-secret"]


@pytest.mark.parametrize("answers", [["short", "short"], ["a long dashboard password", "a different long password"]])
def test_a_short_or_mistyped_password_prints_nothing_to_store(monkeypatch, capsys, answers):
    code, out = run_script(monkeypatch, capsys, answers)
    assert code == 1 and "put-parameter" not in out.out
