"""AWS clients. Created on first use so tests can start their fake AWS first."""

from __future__ import annotations

import threading

_clients: dict[str, object] = {}
_lock = threading.Lock()


def _get(kind: str):
    """Creates an AWS client the first time it is asked for, then reuses it (building one is slow).

    Lambda keeps the process warm between requests, so this module-level cache is what makes the
    second request faster than the first. Tests call reset_clients() so each test gets a fresh fake AWS.
    """
    import boto3  # imported here so just importing this file stays fast

    with _lock:
        if kind not in _clients:
            if kind == "dynamodb":
                _clients[kind] = boto3.resource("dynamodb")
            else:
                _clients[kind] = boto3.client(kind)
        return _clients[kind]


def dynamodb_resource():
    return _get("dynamodb")


def ssm_client():
    return _get("ssm")


def reset_clients() -> None:
    with _lock:
        _clients.clear()
