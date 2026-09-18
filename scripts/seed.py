"""Idempotently load the mock catalogue into the configured tables.

    uv run python scripts/seed.py

Assumes the tables already exist (Terraform owns them in every real
environment — see ../terraform). Pass --create-tables to create them
directly instead, via plain DynamoDB API calls — handy for local dev
against DynamoDB Local, but never in a real environment.
"""

from __future__ import annotations

import argparse
import asyncio

import aioboto3
from botocore.exceptions import EndpointConnectionError

from books_api import repository
from books_api.config import Settings, get_settings
from books_api.db import close_dynamodb, open_dynamodb
from books_api.schemas import BookCreate
from books_api.seed_data import BOOKS

_CONNECT_RETRIES = 30  # local dev only — DynamoDB Local's container may not be accepting
_CONNECT_RETRY_DELAY_S = 1  # connections yet by the time this runs (docker compose start order)


async def _create_tables(settings: Settings) -> None:
    session = aioboto3.Session(region_name=settings.aws_region)
    async with session.resource("dynamodb", endpoint_url=settings.dynamodb_endpoint_url) as dynamodb:
        for attempt in range(1, _CONNECT_RETRIES + 1):
            try:
                await dynamodb.meta.client.list_tables(Limit=1)
                break
            except EndpointConnectionError:
                if attempt == _CONNECT_RETRIES:
                    raise
                await asyncio.sleep(_CONNECT_RETRY_DELAY_S)

        for name, key_name, key_type in (
            (settings.dynamodb_books_table, "id", "N"),
            (settings.dynamodb_isbns_table, "isbn", "S"),
        ):
            try:
                table = await dynamodb.create_table(
                    TableName=name,
                    KeySchema=[{"AttributeName": key_name, "KeyType": "HASH"}],
                    AttributeDefinitions=[{"AttributeName": key_name, "AttributeType": key_type}],
                    BillingMode="PAY_PER_REQUEST",
                )
                await table.wait_until_exists()
                print(f"created table {name}")
            except dynamodb.meta.client.exceptions.ResourceInUseException:
                print(f"table {name} already exists")


async def seed() -> None:
    settings = get_settings()
    db = await open_dynamodb(settings)
    try:
        added = 0
        for row in BOOKS:
            try:
                await repository.create_book(db.tables, BookCreate(**row))
                added += 1
            except repository.IsbnConflictError:
                continue  # already seeded — create_book's conditional write is the dedup check
        print(f"seeded {added} new book(s); {len(BOOKS) - added} already present")
    finally:
        await close_dynamodb(db)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--create-tables",
        action="store_true",
        help="create the DynamoDB tables directly instead of requiring Terraform first",
    )
    args = parser.parse_args()
    if args.create_tables:
        asyncio.run(_create_tables(get_settings()))
    asyncio.run(seed())


if __name__ == "__main__":
    main()
