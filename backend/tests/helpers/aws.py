"""Small helpers for the fake AWS."""

import boto3

from app.core import config

from .constants import ENVIRONMENT


def put_param(name: str, value: str, *, secure: bool = True) -> None:
    """Stores a setting the way the deploy would: /vicbless/<env>/<name> in Parameter Store."""
    boto3.client("ssm").put_parameter(
        Name=f"/vicbless/{ENVIRONMENT}/{name}",
        Value=value,
        Type="SecureString" if secure else "String",
        Overwrite=True,
    )
    config.params.reset()  # the app caches settings for 5 minutes; forget so the new value is seen at once


def raw_table():
    """The table object, for tests that need to look at exactly what was stored."""
    return boto3.resource("dynamodb").Table("vicbless-test")


def raw_sales_table():
    """The sales log's own table, for tests that need to look at exactly what was stored."""
    return boto3.resource("dynamodb").Table("vicbless-sales-test")
