"""Keeps the backend easy to find your way around. Each layer may only use the layers listed here.

    routes -> services -> database -> domain -> core
Breaking one of these rules fails the tests, so the folders cannot quietly turn back into a tangle.
"""

import ast
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "app"

ALLOWED = {
    "core": set(),
    "domain": {"core"},
    "schemas": {"core", "domain"},
    "database": {"core", "domain"},
    "emailing": {"core", "domain"},
    "services": {"core", "domain", "schemas", "database", "emailing"},
    "routes": {"core", "domain", "schemas", "services"},
}
WEB_OK = {"routes", "core/web.py", "main.py", "handler.py"}  # the only places that may import fastapi / starlette
BOTO_OK = {"core/aws.py"}
BOTOCORE_OK_DIR = "database"


def py_files():
    return [p for p in APP.rglob("*.py") if "__pycache__" not in p.parts]


def imports(path: Path):
    """Yield (kind, name): ('app', 'database') for our own packages, ('lib', 'fastapi') for others."""
    rel = path.relative_to(APP)
    package = ["app", *rel.parts[:-1]]
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield "lib", a.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0:
                yield "lib", (node.module or "").split(".")[0]
                continue
            base = package[: len(package) - (node.level - 1)]
            target = base + (node.module.split(".") if node.module else [])
            if len(target) >= 2:
                yield "app", target[1]
            else:  # "from .. import x": x is itself a package or module of app
                for a in node.names:
                    yield "app", a.name


def layer_of(path: Path):
    parts = path.relative_to(APP).parts
    return parts[0] if len(parts) > 1 else None


def test_every_layer_only_uses_the_layers_below_it():
    problems = []
    for path in py_files():
        layer = layer_of(path)
        if layer not in ALLOWED:
            continue
        for kind, name in imports(path):
            if kind == "app" and name != layer and name not in ALLOWED[layer]:
                problems.append(
                    f"{path.relative_to(APP)} imports app.{name} ({layer} may only use {sorted(ALLOWED[layer]) or 'nothing else'})"
                )
    assert not problems, "\n".join(problems)


def test_only_the_web_layer_knows_about_fastapi():
    problems = []
    for path in py_files():
        rel = path.relative_to(APP).as_posix()
        if any(rel == ok or rel.startswith(ok + "/") for ok in WEB_OK):
            continue
        for kind, name in imports(path):
            if kind == "lib" and name in ("fastapi", "starlette", "mangum"):
                problems.append(f"{rel} imports {name}")
    assert not problems, "\n".join(problems)


def test_aws_libraries_stay_in_their_place():
    problems = []
    for path in py_files():
        rel = path.relative_to(APP).as_posix()
        for kind, name in imports(path):
            if kind == "lib" and name == "boto3" and rel not in BOTO_OK:
                problems.append(f"{rel} imports boto3 (only core/aws.py may)")
            if kind == "lib" and name == "botocore" and not rel.startswith(BOTOCORE_OK_DIR + "/"):
                problems.append(f"{rel} imports botocore (only database/ may)")
    assert not problems, "\n".join(problems)


def test_no_loose_modules_beyond_the_entry_points():
    loose = {p.name for p in APP.glob("*.py")}
    assert loose == {"__init__.py", "main.py", "handler.py"}, loose
