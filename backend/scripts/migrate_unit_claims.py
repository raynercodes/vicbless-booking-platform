#!/usr/bin/env python3
"""One-time upgrade: give bookings and block-offs made BEFORE the settings update the 5 minute claims they need.

    AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev            # shows what it WOULD do
    AWS_PROFILE=vicbless python backend/scripts/migrate_unit_claims.py --env dev --apply    # does it

Why: the old site claimed one item per 35 minute block. The new site claims every 5 minute unit, so that the
appointment length can differ by weekday (Monday and Tuesday 45 minutes) and change later without any chance of a
double booking. A booking made the old way holds only its first unit(s); until it is upgraded, a new booking on a
different grid could overlap it. This script adds the missing units to every old booking and block-off.

Order of a release: 1) deploy the backend, 2) run this with --apply for that environment, 3) deploy the frontend.
It is safe to run twice (items already upgraded are skipped) and safe while the site is live: it only ever ADDS
claims that are free. If a claim is held by something else, that item is reported as a conflict and left alone
so Vic can look at it by hand.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.errors import SlotTaken  # noqa: E402
from app.database import keys, table, transactions  # noqa: E402
from app.database.keys import PK  # noqa: E402
from app.domain import shop  # noqa: E402

OLD_BLOCK_MINUTES = 35  # the length every old claim stood for


def wanted_units(item: dict) -> list[int]:
    """Every 5 minute unit an old item should hold."""
    if item["kind"] == "booking":
        start, minutes = int(item["start"]), int(item["minutes"])
        return shop.occupied_starts(start, minutes)
    old = sorted(int(u) for u in item.get("blocks", []))
    if not old:
        return []
    return list(range(old[0], old[-1] + OLD_BLOCK_MINUTES, shop.UNIT_MINUTES))


def old_items() -> list[dict]:
    """All bookings and block-offs not yet upgraded (they have no `units` marker). Follows DynamoDB paging."""
    found: list[dict] = []
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk",
        "ExpressionAttributeValues": {":pk": PK},
        "ConsistentRead": True,
    }
    while True:
        page = table.table().query(**kwargs)
        found += [i for i in page["Items"] if i.get("kind") in ("booking", "block") and not i.get("units")]
        if "LastEvaluatedKey" not in page:
            return found
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def upgrade(item: dict, units: list[int]) -> None:
    """Claims the units (in chunks), then marks the item upgraded. Raises SlotTaken if another item holds one."""
    day = date.fromisoformat(item["date"])
    ref = item["id"]
    size = transactions.CHUNK_CLAIMS
    for i in range(0, len(units), size):
        transactions.write_all_or_nothing(
            [transactions.claim_put(day, u, ref, allow_same_ref=True) for u in units[i : i + size]]
        )
    table.table().update_item(
        Key={"pk": item["pk"], "sk": item["sk"]},
        UpdateExpression="SET #b = :b, units = :t",
        ExpressionAttributeNames={"#b": "blocks"},
        ExpressionAttributeValues={":b": units, ":t": True},
    )


def migrate(apply: bool) -> dict[str, int]:
    """Upgrades (or, without `apply`, only counts) every old item. Returns {'upgraded', 'conflicts', 'already_ok'}."""
    report = {"upgraded": 0, "conflicts": 0, "already_ok": 0}
    for item in old_items():
        units = wanted_units(item)
        if not units:
            report["already_ok"] += 1
            continue
        label = f"{item['kind']} {item['id']}"
        if not apply:
            print(f"would upgrade {label}: {len(units)} units")
            report["upgraded"] += 1
            continue
        try:
            upgrade(item, units)
        except SlotTaken:
            print(f"CONFLICT {label}: a unit is held by something else. Left alone; check it by hand.", file=sys.stderr)
            report["conflicts"] += 1
        else:
            print(f"upgraded {label}: {len(units)} units")
            report["upgraded"] += 1
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--apply", action="store_true", help="really write (without this it only shows what it would do)")
    args = parser.parse_args()

    os.environ["ENVIRONMENT"] = args.env
    os.environ["TABLE_NAME"] = f"vicbless-{args.env}"
    os.environ.setdefault("AWS_DEFAULT_REGION", args.region)

    report = migrate(args.apply)
    verb = "Upgraded" if args.apply else "Would upgrade"
    print(f"\n{verb} {report['upgraded']}; conflicts {report['conflicts']}; nothing to do {report['already_ok']}.")
    if not args.apply and report["upgraded"]:
        print("Run again with --apply to write the changes.")
    return 1 if report["conflicts"] else 0


if __name__ == "__main__":
    sys.exit(main())
