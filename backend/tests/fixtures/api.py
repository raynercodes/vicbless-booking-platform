"""The API client, and a signed-in Vic."""

import pytest
from fastapi.testclient import TestClient

from app.core import security
from tests.helpers.aws import put_param
from tests.helpers.constants import ADMIN_PASSWORD, JWT_SECRET, PEPPER


@pytest.fixture
def client():
    """A client that calls the real app in-process (no network). The app is built fresh per test."""
    from app.main import create_app

    return TestClient(create_app())


@pytest.fixture
def admin_setup():
    """Stores Vic's sign-in secrets in the fake Parameter Store, the way hash_password.py + the AWS CLI would."""
    put_param("pepper", PEPPER)
    put_param("jwt-secret", JWT_SECRET)
    put_param("admin-password-hash", security.hash_password(ADMIN_PASSWORD, PEPPER, iterations=1000))


@pytest.fixture
def auth(client, admin_setup):
    """Headers for a signed-in Vic: {"Authorization": "Bearer <token>"}. Signs in for real through the API."""
    response = client.post("/api/admin/login", json={"password": ADMIN_PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['token']}"}
