"""The one DynamoDB table, and its name."""

from __future__ import annotations

from ..core import aws, config


def table():
    """The table object. Looked up on each call so tests (and the Lambda) always use the current settings."""
    return aws.dynamodb_resource().Table(config.get_settings().table_name)


def client():
    """The low-level client, needed for transactions (the table object can't run them)."""
    return table().meta.client


def table_name() -> str:
    return config.get_settings().table_name


def sales_table():
    """The sales log's own table (kept apart from the bookings table, so the log is never touched by booking clean-up)."""
    return aws.dynamodb_resource().Table(config.get_settings().sales_table_name)


def sales_table_name() -> str:
    return config.get_settings().sales_table_name
