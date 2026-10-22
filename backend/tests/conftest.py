"""Pytest finds fixtures here. They live in tests/fixtures/, one file per topic, and are listed once:

    aws, fixed_clock, classic_grid   run around every test automatically (autouse)
    atomic_transactions  opt-in: the fake database runs one transaction at a time, like the real one
    client, auth         the API, and a signed-in Vic
    sent                 catches outgoing emails
    texts                catches outgoing texts (and sets Vic's number)
    stripe               online payment switched on, with a fake Stripe
    logged               the log lines the app wrote, as dicts

Shared test data and shortcuts live in tests/helpers/ (builders, api shortcuts, constants).
"""

from tests.fixtures.api import admin_setup, auth, client  # noqa: F401
from tests.fixtures.aws import atomic_transactions, aws  # noqa: F401
from tests.fixtures.clock import fixed_clock  # noqa: F401
from tests.fixtures.email import sent  # noqa: F401
from tests.fixtures.logs import logged  # noqa: F401
from tests.fixtures.settings import classic_grid  # noqa: F401
from tests.fixtures.sms import texts  # noqa: F401
from tests.fixtures.stripe import stripe  # noqa: F401
