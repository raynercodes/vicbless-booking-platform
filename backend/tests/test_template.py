"""Checks on infra/template.yaml, the one template for both environments."""

import pytest

from tests.helpers.template import ROOT, TEMPLATE_PATH, load_template

TEMPLATE = TEMPLATE_PATH


@pytest.fixture(scope="module")
def t():
    return load_template()


def test_function_settings(t):
    fn = t["Resources"]["ApiFunction"]["Properties"]
    assert t["Globals"]["Function"]["MemorySize"] == 1024
    assert t["Globals"]["Function"]["Runtime"] == "python3.12"
    assert fn["Handler"] == "app.handler.lambda_handler"
    assert (TEMPLATE.parent / fn["CodeUri"]).resolve() == (ROOT / "backend")
    assert (ROOT / "backend" / "app" / "handler.py").exists()


def test_no_codedeploy_anywhere(t):
    text = TEMPLATE.read_text()
    for word in ("AutoPublishAlias", "DeploymentPreference", "CodeDeploy", "AWS::Lambda::Alias"):
        assert word not in text


def test_no_docs_route_and_only_api_paths(t):
    events = t["Resources"]["ApiFunction"]["Properties"]["Events"]
    paths = {e["Properties"]["Path"] for e in events.values() if e["Type"] == "HttpApi"}
    assert paths == {"/api", "/api/{proxy+}", "/api/admin/login"}


def test_reminders_run_on_a_schedule_and_text_provider_is_set(t):
    fn = t["Resources"]["ApiFunction"]["Properties"]
    schedules = [e for e in fn["Events"].values() if e["Type"] == "Schedule"]
    assert len(schedules) == 1 and schedules[0]["Properties"]["Schedule"] == "rate(15 minutes)"
    assert fn["Environment"]["Variables"]["SMS_PROVIDER"] == "textbelt"


def test_table(t):
    table = t["Resources"]["Table"]
    p = table["Properties"]
    assert table["DeletionPolicy"] == "Retain" and p["BillingMode"] == "PAY_PER_REQUEST"
    assert p["TimeToLiveSpecification"] == {"AttributeName": "expiresAt", "Enabled": True}
    assert [g["IndexName"] for g in p["GlobalSecondaryIndexes"]] == ["gsi1"]
    assert "IsProd" in str(p["PointInTimeRecoverySpecification"]) and "IsProd" in str(p["DeletionProtectionEnabled"])


def test_environments_and_params(t):
    assert t["Parameters"]["Environment"]["AllowedValues"] == ["dev", "prod"]
    assert set(t["Parameters"]) == {"Environment", "CorsAllowedOrigins"}  # the deploy workflow passes exactly these


def test_permissions_are_scoped(t):
    statements = t["Resources"]["ApiFunction"]["Properties"]["Policies"][0]["Statement"]
    actions = {a for s in statements for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}
    assert "dynamodb:Scan" not in actions and "ssm:GetParametersByPath" not in actions
    assert not any(a.endswith(":*") for a in actions)
    assert "dynamodb:Query" in actions and "ssm:GetParameter" in actions
    assert "Resource" in statements[1] and "*" not in str(statements[1]["Resource"]).replace("/vicbless/${Environment}/*", "")


def test_login_is_throttled_hard(t):
    rs = t["Resources"]["HttpApi"]["Properties"]["RouteSettings"]["POST /api/admin/login"]
    assert rs["ThrottlingRateLimit"] <= 5 and rs["ThrottlingBurstLimit"] <= 10


def test_outputs(t):
    assert {"ApiUrl", "ApiDomainName", "TableName", "FunctionName"} <= set(t["Outputs"])


def test_log_retention(t):
    lg = t["Resources"]["ApiLogGroup"]
    assert lg["Properties"]["RetentionInDays"] == 14 and lg["DeletionPolicy"] == "Retain"
