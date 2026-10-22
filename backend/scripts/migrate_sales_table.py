#!/usr/bin/env python3
"""One-time move: copy sales-log lines that were saved in the bookings table into the new, separate sales table.

    AWS_PROFILE=vicbless python backend/scripts/migrate_sales_table.py --env dev            # shows what it WOULD do
    AWS_PROFILE=vicbless python backend/scripts/migrate_sales_table.py --env dev --apply    # does it

Why: the first version of the sales log kept its lines in the same table as the bookings (sort keys starting "SALE#").
The log now has its own table (the SalesTable of the template), so it is never mixed with bookings that expire after
90 days. Only needed for an environment where lines were logged BEFORE the sales table existed; with nothing to move it
says so and does nothing.

Order of a release: 1) deploy the backend (this creates the sales table), 2) run this with --apply for that environment.
Safe to run twice: each line is written to the new table first and removed from the old one only after that worked, and a
line already in the new table is left as it is.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from botocore.exceptions import ClientError  # noqa: E402

from app.database import keys, table  # noqa: E402
from app.database.keys import PK, SALES_PK  # noqa: E402


def old_lines() -> list[dict]:
    """Every sales line still in the bookings table. Follows DynamoDB paging."""
    kwargs: dict = {
        "KeyConditionExpression": "pk = :pk AND begins_with(sk, :p)",
        "ExpressionAttributeValues": {":pk": PK, ":p": "SALE#"},
        "ConsistentRead": True,
    }
    found: list[dict] = []
    while True:
        page = table.table().query(**kwargs)
        found.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return found
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def migrate(apply: bool) -> dict:
    report = {"moved": 0, "already_there": 0}
    for item in old_lines():
        new_item = {k: v for k, v in item.items() if k not in ("kind", "expiresAt")}
        new_item["pk"] = SALES_PK
        new_item["sk"] = item["sk"].removeprefix("SALE#")
        label = f"{item.get('date')} {item.get('clientName')} ${int(item.get('amountCents', 0)) / 100:.2f}"
        if not apply:
            print(f"would move {label}")
            report["moved"] += 1
            continue
        try:
            table.sales_table().put_item(Item=new_item, ConditionExpression="attribute_not_exists(pk)")
        except ClientError as err:
            if err.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            report["already_there"] += 1  # copied by an earlier run that stopped before the clean-up
        else:
            report["moved"] += 1
            print(f"moved {label}")
        table.table().delete_item(Key={"pk": PK, "sk": item["sk"]})
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--apply", action="store_true", help="really write (without this it only shows what it would do)")
    args = parser.parse_args()

    os.environ["ENVIRONMENT"] = args.env
    os.environ["TABLE_NAME"] = f"vicbless-{args.env}"
    os.environ["SALES_TABLE_NAME"] = f"vicbless-sales-{args.env}"
    os.environ.setdefault("AWS_DEFAULT_REGION", args.region)

    report = migrate(args.apply)
    verb = "Moved" if args.apply else "Would move"
    print(f"\n{verb} {report['moved']} line(s); already in the sales table {report['already_there']}.")
    if not report["moved"] and not report["already_there"]:
        print("Nothing to move.")
    if not args.apply and report["moved"]:
        print("Run again with --apply to move them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
