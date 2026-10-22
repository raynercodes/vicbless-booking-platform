"""The site and the API must agree on hours, services and the slot grid. This reads the real frontend config."""

import re
from pathlib import Path

from app.domain import shop

CONFIG = Path(__file__).resolve().parents[2] / "frontend" / "src" / "config.js"


def source() -> str:
    assert CONFIG.exists(), f"Expected the frontend config at {CONFIG}. The contract test needs the whole repo."
    return CONFIG.read_text()


def block(text: str, start: str, end: str) -> str:
    i = text.index(start)
    return text[i : text.index(end, i)]


def test_days_ahead():
    assert int(re.search(r"export const DAYS_AHEAD = (\d+)", source()).group(1)) == shop.DAYS_AHEAD


def test_slot_limits_match():
    """The dashboard's appointment-length picker offers exactly the lengths the API accepts."""
    text = source()
    found = {name: int(n) for name, n in re.findall(r"export const (SLOT_MIN|SLOT_MAX|SLOT_STEP|MAX_SERVICES) = (\d+)", text)}
    assert found == {
        "SLOT_MIN": shop.MIN_SLOT_MINUTES,
        "SLOT_MAX": shop.MAX_SLOT_MINUTES,
        "SLOT_STEP": shop.UNIT_MINUTES,
        "MAX_SERVICES": shop.MAX_SERVICES,
    }


def test_default_slot_lengths_match():
    """The site starts from the same appointment lengths as the backend (Monday and Tuesday 45, the rest 35)."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const SLOT_MINUTES_BY_DAY = {", "}")
    js = {int(day): int(minutes) for day, minutes in re.findall(r"(\d):\s*(\d+)", body)}
    assert set(js) == set(range(7))
    for js_day, minutes in js.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        assert REAL_DEFAULTS.slot_minutes[py_day] == minutes, f"JS day {js_day}"


def test_staff():
    assert "id: 'vic'" in block(source(), "export const STAFF", "\n")


def test_hours_match():
    body = block(source(), "export const HOURS = {", "\n}")
    body = re.sub(r"//[^\n]*", "", body).split("{", 1)[1]
    body = re.sub(r"at\((\d+),\s*(\d+)\)", r"(\1*60+\2)", body)
    body = re.sub(r"at\((\d+)\)", r"(\1*60)", body)
    js_hours = eval("{" + body.replace("null", "None") + "}", {"__builtins__": {}})  # our own repo file
    assert set(js_hours) == set(range(7))
    for js_day, windows in js_hours.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        expected = [tuple(w) for w in windows] if windows else None
        assert shop.HOURS[py_day] == expected, f"JS day {js_day}"


STRING = r"""(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")"""


def js_string(match_tuple) -> str:
    """Whichever of the two quote styles matched."""
    return match_tuple[0] or match_tuple[1]


def test_default_services_match():
    """The services the site starts with (before the API answers) are the backend's starting services, in the same order."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const SERVICES = [", "\n]")
    found = []
    for obj in re.findall(r"\{[^{}]*\}", body):
        sid = re.search(r"id:\s*" + STRING, obj)
        name = re.search(r"name:\s*" + STRING, obj)
        price = re.search(r"price:\s*(\d+)", obj)
        note = re.search(r"note:\s*" + STRING, obj)
        found.append(
            (
                js_string(sid.groups()),
                js_string(name.groups()),
                int(price.group(1)),
                "from: true" in obj,
                js_string(note.groups()) if note else "",
            )
        )
    assert found, "No services found in the frontend config"
    assert found == [(s.id, s.name, s.price, s.from_price, s.note) for s in REAL_DEFAULTS.services]


def test_input_limits_match():
    """The booking form's character limits (and the 0/500 counter) must be the same numbers the API enforces."""
    from app.schemas import requests

    match = re.search(r"export const LIMITS = \{\s*name:\s*(\d+),\s*notes:\s*(\d+)\s*\}", source())
    assert match, "frontend/src/config.js has no LIMITS yet. Run update-vicbless-notes-counter.sh (from inside frontend/) first."
    assert (int(match.group(1)), int(match.group(2))) == (requests.NAME_MAX, requests.NOTES_MAX)


def test_contact_email_matches():
    """The email customers are told to write to is the same on the site and in the emails and error messages."""
    from app.core.brand import CONTACT_EMAIL

    match = re.search(r"email:\s*'([^']+)'", block(source(), "export const BUSINESS", "\n}"))
    assert match and match.group(1) == CONTACT_EMAIL


def test_reminder_choices_and_defaults_match_the_site():
    """The dashboard offers the same reminder times the API accepts, and starts from the same ones."""
    text = source()
    choices = re.search(r"export const REMINDER_CHOICES = \[([\d,\s]+)\]", text)
    default = re.search(r"export const REMINDER_HOURS_DEFAULT = \[([\d,\s]+)\]", text)
    assert choices and default, "frontend/src/config.js is missing REMINDER_CHOICES or REMINDER_HOURS_DEFAULT"
    as_ints = lambda m: tuple(int(n) for n in re.findall(r"\d+", m.group(1)))  # noqa: E731
    assert sorted(as_ints(choices)) == sorted(shop.REMINDER_CHOICES)
    assert as_ints(default) == shop.DEFAULT_SETTINGS.reminder_hours


def test_the_consent_line_on_the_booking_form_says_what_carriers_expect():
    text = source()
    line = re.search(r"export const SMS_CONSENT = '([^']+)'", text)
    assert line, "frontend/src/config.js has no SMS_CONSENT"
    assert "Msg & data rates may apply" in line.group(1) and "Reply STOP to opt out" in line.group(1)


def test_after_hours_defaults_match():
    """After Hours Cuts starts the same on the site and in the API: id, name, price, description, and the late appointments per day."""
    from tests.fixtures.settings import REAL_DEFAULTS

    body = block(source(), "export const AFTER_HOURS = {", "\n}")
    js_id = js_string(re.search(r"id:\s*" + STRING, body).groups())
    js_name = js_string(re.search(r"name:\s*" + STRING, body).groups())
    js_note = js_string(re.search(r"note:\s*" + STRING, body).groups())
    js_price = int(re.search(r"price:\s*(\d+)", body).group(1))
    slots = re.search(r"slots:\s*\{([^}]*)\}", body).group(1)
    js_slots = {int(k): int(v) for k, v in re.findall(r"(\d):\s*(\d+)", slots)}
    assert js_id == shop.AFTER_HOURS_ID and js_name == shop.AFTER_HOURS_NAME
    assert js_price == REAL_DEFAULTS.after_hours.price and js_note == REAL_DEFAULTS.after_hours.note
    for js_day, count in js_slots.items():
        py_day = (js_day - 1) % 7  # JavaScript: Sunday = 0. Python: Monday = 0.
        assert REAL_DEFAULTS.after_hours.slots[py_day] == count, f"JS day {js_day}"
    assert len(js_slots) == 7
    max_slots = int(re.search(r"export const MAX_AFTER_SLOTS = (\d+)", source()).group(1))
    assert max_slots == shop.MAX_AFTER_SLOTS
