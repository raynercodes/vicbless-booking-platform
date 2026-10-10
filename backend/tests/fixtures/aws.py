"""A fake AWS for every test (moto), with the table built from the real template."""

import boto3
import pytest
from moto import mock_aws

from app.core import config
from tests.helpers.constants import ENVIRONMENT, TEST_TABLE
from tests.helpers.template import table_definition


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
        "EMAIL_PROVIDER": "resend",
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("CORS_ALLOWED_ORIGINS", raising=False)
    config.reset_caches()
    with mock_aws():
        boto3.client("dynamodb").create_table(**table_definition(TEST_TABLE))
        yield
    config.reset_caches()
