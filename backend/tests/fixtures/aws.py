"""A fake AWS for every test (moto), with the table built from the real template."""

import boto3
import pytest
from moto import mock_aws

from app.core import config
from tests.helpers.constants import ENVIRONMENT, TEST_SALES_TABLE, TEST_TABLE
from tests.helpers.template import sales_table_definition, table_definition


@pytest.fixture(autouse=True)
def aws(monkeypatch):
    """Runs around EVERY test (autouse): fake credentials, fake AWS, a fresh table, clean caches.

    The app keeps AWS clients and settings in memory between calls (that is what makes the Lambda fast).
    Without the reset below, a client built against one test's fake AWS would leak into the next test.
    """
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_DEFAULT_REGION": "us-east-1",
        "ENVIRONMENT": ENVIRONMENT,
        "TABLE_NAME": TEST_TABLE,
        "SALES_TABLE_NAME": TEST_SALES_TABLE,
        "EMAIL_PROVIDER": "resend",
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("CORS_ALLOWED_ORIGINS", raising=False)
    config.reset_caches()
    with mock_aws():
        boto3.client("dynamodb").create_table(**table_definition(TEST_TABLE))
        boto3.client("dynamodb").create_table(**sales_table_definition(TEST_SALES_TABLE))
        yield
    config.reset_caches()


@pytest.fixture
def atomic_transactions(monkeypatch):
    """Makes the fake DynamoDB run one transaction at a time, the way the real one behaves.

    A real DynamoDB transaction is atomic: when two people try to claim the same time at once, it checks
    and writes as ONE step, so exactly one of them wins. moto (the fake) does not guarantee that when several
    threads call it together, so a concurrency test against it can fail at random (it did: two "winners").
    This lock gives the fake the guarantee the real service already has. What is still being tested is the
    app's own part: that it asks for "only if this claim does not exist yet", so the database can decide.
    """
    import threading

    from app.database import table

    lock = threading.Lock()
    real = table.client()

    class OneAtATime:
        def __getattr__(self, name):
            return getattr(real, name)

        def transact_write_items(self, **kwargs):
            with lock:
                return real.transact_write_items(**kwargs)

    monkeypatch.setattr(table, "client", lambda: OneAtATime())
