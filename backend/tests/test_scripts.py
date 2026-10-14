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


# --- migrate_unit_claims.py (the one-time upgrade of bookings made before the settings update) -------------

from datetime import date  # noqa: E402

TUESDAY_DATE = date(2026, 10, 13)
MIGRATE = Path(__file__).resolve().parents[1] / "scripts" / "migrate_unit_claims.py"


def load_migrate():
    import importlib.util

    spec = importlib.util.spec_from_file_location("migrate_unit_claims", MIGRATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def old_style_booking(day, start, suffix="aaaa1111"):
    """Writes a booking exactly as the OLD site did: one claim per 35 minute block, and no `units` marker."""
    from app.database import keys as k
    from tests.helpers.aws import raw_table

    booking_id = f"{day.isoformat()}.{start // 60:02d}{start % 60:02d}.{suffix}"
    t = raw_table()
    t.put_item(Item={
        "pk": k.PK, "sk": k.booking_sk(day, start, booking_id), "kind": "booking", "id": booking_id, "code": "OLD123",
        "date": day.isoformat(), "start": start, "minutes": 35, "serviceId": "mens-cut", "name": "Old Timer",
        "phone": "5550101111", "blocks": [start], "expiresAt": k.expires(day),
    })  # fmt: skip
    t.put_item(Item={"pk": k.PK, "sk": k.claim_sk(day, start), "kind": "claim", "ref": booking_id, "expiresAt": k.expires(day)})
    return booking_id


def test_migration_adds_the_missing_units_and_is_safe_to_repeat():
    from tests.helpers.aws import raw_table
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    old_style_booking(TUESDAY_DATE, 755)
    assert len(taken_units(TUESDAY_DATE)) == 1

    assert migrate.migrate(apply=False) == {"upgraded": 1, "conflicts": 0, "already_ok": 0}
    assert len(taken_units(TUESDAY_DATE)) == 1  # the dry run changed nothing

    assert migrate.migrate(apply=True)["upgraded"] == 1
    assert len(taken_units(TUESDAY_DATE)) == 7  # 35 minutes = seven 5 minute units
    assert migrate.migrate(apply=True) == {"upgraded": 0, "conflicts": 0, "already_ok": 0}  # second run: nothing left
    item = [i for i in raw_table().scan()["Items"] if i.get("kind") == "booking"][0]
    assert item["units"] is True and len(item["blocks"]) == 7


def test_after_migration_a_cancel_releases_every_unit(client, auth):
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    booking_id = old_style_booking(TUESDAY_DATE, 755)
    migrate.migrate(apply=True)
    assert client.delete(f"/api/admin/bookings/{booking_id}", headers=auth).status_code == 200
    assert len(taken_units(TUESDAY_DATE)) == 0


def test_an_old_block_off_is_upgraded_to_cover_its_whole_range():
    from app.database import keys as k
    from tests.helpers.aws import raw_table
    from tests.helpers.builders import taken_units

    migrate = load_migrate()
    day = TUESDAY_DATE
    t = raw_table()
    t.put_item(Item={"pk": k.PK, "sk": k.block_sk(day, 720, "blk"), "kind": "block", "id": "blk", "date": day.isoformat(),
                     "start": 720, "end": 790, "note": "", "whole": False, "blocks": [720, 755], "expiresAt": k.expires(day)})  # fmt: skip
    for u in (720, 755):
        t.put_item(Item={"pk": k.PK, "sk": k.claim_sk(day, u), "kind": "claim", "ref": "blk", "expiresAt": k.expires(day)})
    migrate.migrate(apply=True)
    assert len(taken_units(day)) == 14  # 12:00 to 1:10, in 5 minute units


def test_a_unit_held_by_something_else_is_reported_and_left_alone(capsys):
    from app.database import keys as k
    from tests.helpers.aws import raw_table

    migrate = load_migrate()
    old_style_booking(TUESDAY_DATE, 755)
    raw_table().put_item(Item={"pk": k.PK, "sk": k.claim_sk(TUESDAY_DATE, 765), "kind": "claim", "ref": "someone-else", "expiresAt": 1})
    assert migrate.migrate(apply=True) == {"upgraded": 0, "conflicts": 1, "already_ok": 0}
    assert "CONFLICT" in capsys.readouterr().err


def test_the_script_asks_for_an_environment(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", [str(MIGRATE)])
    with pytest.raises(SystemExit) as stop:
        runpy.run_path(str(MIGRATE), run_name="__main__")
    assert stop.value.code == 2
