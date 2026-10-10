"""Reads infra/template.yaml so the tests can build their fake table from the REAL table definition.

If the table's keys or index ever change in the template, the tests change with it. They can't pass
against a table shape that isn't the one that gets deployed.
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]  # the repo root
TEMPLATE_PATH = ROOT / "infra" / "template.yaml"


class _CloudFormationLoader(yaml.SafeLoader):
    """YAML loader that tolerates CloudFormation's short tags (!Ref, !Sub, !If ...) by keeping them as plain data."""


def _keep_tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {suffix: loader.construct_sequence(node, deep=True)}
    return {suffix: loader.construct_mapping(node, deep=True)}


_CloudFormationLoader.add_multi_constructor("!", _keep_tag)


def load_template() -> dict:
    return yaml.load(TEMPLATE_PATH.read_text(), Loader=_CloudFormationLoader)


def table_definition(table_name: str) -> dict:
    """The arguments boto3's create_table needs, taken from the template's Table resource."""
    props = load_template()["Resources"]["Table"]["Properties"]
    return {
        "TableName": table_name,
        "BillingMode": props["BillingMode"],
        "AttributeDefinitions": props["AttributeDefinitions"],
        "KeySchema": props["KeySchema"],
        "GlobalSecondaryIndexes": props["GlobalSecondaryIndexes"],
    }
