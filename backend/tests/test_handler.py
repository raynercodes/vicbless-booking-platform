import json

from app.handler import lambda_handler


def http_api_event(method, path, body=None, headers=None):
    return {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"content-type": "application/json", **(headers or {})},
        "requestContext": {
            "accountId": "123",
            "apiId": "abc",
            "domainName": "abc.execute-api.us-east-1.amazonaws.com",
            "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "203.0.113.9", "userAgent": "test"},
            "requestId": "r1",
            "stage": "$default",
            "time": "12/Oct/2026:10:00:00 +0000",
            "timeEpoch": 1,
        },
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
    }


def test_health_through_the_lambda_entry_point():
    resp = lambda_handler(http_api_event("GET", "/api/health"), None)
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["status"] == "ok"
    assert resp["headers"]["cache-control"] == "no-store"


def test_docs_404_through_the_lambda_entry_point():
    for path in ("/api/docs", "/docs", "/api/openapi.json"):
        assert lambda_handler(http_api_event("GET", path), None)["statusCode"] == 404


def test_source_ip_reaches_the_app_for_the_lockout(admin_setup):
    for _ in range(5):
        lambda_handler(http_api_event("POST", "/api/admin/login", {"password": "bad"}), None)
    resp = lambda_handler(http_api_event("POST", "/api/admin/login", {"password": "bad"}), None)
    assert resp["statusCode"] == 429
