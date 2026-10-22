"""Vic's sales log in its own table (apart from the bookings): add a line, list them all, change one, remove one."""

from __future__ import annotations

from datetime import date

from botocore.exceptions import ClientError

from ..core.errors import NotFound
from ..domain.sales import Sale, parse_sale_id
from . import keys, table
from .keys import SALES_PK

NOT_FOUND = "That sale was not found. It may already be removed."


def sale_from(item: dict) -> Sale:
    return Sale(
        id=item["id"],
        day=date.fromisoformat(item["date"]),
        service_id=item.get("serviceId", ""),
        service_name=item.get("serviceName", ""),
        amount_cents=int(item["amountCents"]),
        custom_price=bool(item.get("customPrice", False)),
        payment=item.get("payment", "shop"),
        client_name=item.get("clientName", ""),
        note=item.get("note", ""),
        created_at=item.get("createdAt", ""),
    )


def item_for(sale: Sale) -> dict:
    return {
        "pk": SALES_PK,
        "sk": keys.sale_sk(sale.day, sale.id),
        "id": sale.id,
        "date": sale.day.isoformat(),
        "serviceId": sale.service_id,
        "serviceName": sale.service_name,
        "amountCents": sale.amount_cents,
        "customPrice": sale.custom_price,
        "payment": sale.payment,
        "clientName": sale.client_name,
        "note": sale.note,
        "createdAt": sale.created_at,
    }


def add(sale: Sale) -> Sale:
    table.sales_table().put_item(Item=item_for(sale), ConditionExpression="attribute_not_exists(pk)")
    return sale


def get(sale_id: str) -> Sale | None:
    day = parse_sale_id(sale_id)
    if day is None:
        return None
    item = table.sales_table().get_item(Key={"pk": SALES_PK, "sk": keys.sale_sk(day, sale_id)}, ConsistentRead=True).get("Item")
    return sale_from(item) if item else None


def list_all() -> list[Sale]:
    """Every line of the log, newest first (by day, then by when it was logged). Follows DynamoDB's paging."""
    kwargs: dict = {"KeyConditionExpression": "pk = :pk", "ExpressionAttributeValues": {":pk": SALES_PK}, "ConsistentRead": True}
    sales: list[Sale] = []
    while True:
        page = table.sales_table().query(**kwargs)
        sales.extend(sale_from(item) for item in page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    sales.sort(key=lambda s: (s.day, s.created_at), reverse=True)
    return sales


def replace(old: Sale, new: Sale) -> Sale:
    """Swaps a line for its edited version. The same day keeps the same item; a different day is a different sort key, so
    the old item is deleted and the new one written in ONE transaction (never both, never neither)."""
    try:
        if old.id == new.id:
            table.sales_table().put_item(Item=item_for(new), ConditionExpression="attribute_exists(pk)")
        else:
            name = table.sales_table_name()
            table.sales_table().meta.client.transact_write_items(
                TransactItems=[
                    {"Delete": {"TableName": name, "Key": {"pk": SALES_PK, "sk": keys.sale_sk(old.day, old.id)}, "ConditionExpression": "attribute_exists(pk)"}},
                    {"Put": {"TableName": name, "Item": item_for(new), "ConditionExpression": "attribute_not_exists(pk)"}},
                ]
            )
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") in ("ConditionalCheckFailedException", "TransactionCanceledException"):
            raise NotFound(NOT_FOUND) from None  # the line was removed a moment ago
        raise
    return new


def remove(sale_id: str) -> Sale:
    day = parse_sale_id(sale_id)
    if day is None:
        raise NotFound(NOT_FOUND)
    gone = table.sales_table().delete_item(Key={"pk": SALES_PK, "sk": keys.sale_sk(day, sale_id)}, ReturnValues="ALL_OLD").get("Attributes")
    if not gone:
        raise NotFound(NOT_FOUND)
    return sale_from(gone)
