"""Async DynamoDB resource plumbing.

The aioboto3 resource is opened once per running app in the FastAPI lifespan
and stashed on ``app.state`` (mirroring the old SQLAlchemy engine/sessionmaker
pattern) so tests can substitute their own. Unlike a SQL connection, a
DynamoDB item operation is already atomic and immediately durable on its
own — there's no session/transaction boundary to open and commit per
request, so ``get_tables`` is a plain dependency, not an async-generator one.

aioboto3 resource sub-objects (``dynamodb.Table(name)``) are coroutines, not
plain factory calls like boto3's — that's aioboto3-specific and easy to miss.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import aioboto3
from fastapi import Request

from .config import Settings


@dataclass
class Tables:
    """Handles for the two tables this app uses, held for the app's lifetime."""

    books: Any  # aioboto3.resources.factory.dynamodb.Table
    isbns: Any


@dataclass
class DynamoDB:
    """Everything opened in the lifespan that needs a matching close."""

    resource_cm: Any  # the `async with`-style context manager itself
    resource: Any  # the entered ServiceResource
    tables: Tables


async def open_dynamodb(settings: Settings) -> DynamoDB:
    session = aioboto3.Session(region_name=settings.aws_region)
    resource_cm = session.resource("dynamodb", endpoint_url=settings.dynamodb_endpoint_url)
    resource = await resource_cm.__aenter__()
    tables = Tables(
        books=await resource.Table(settings.dynamodb_books_table),
        isbns=await resource.Table(settings.dynamodb_isbns_table),
    )
    return DynamoDB(resource_cm=resource_cm, resource=resource, tables=tables)


async def close_dynamodb(db: DynamoDB) -> None:
    await db.resource_cm.__aexit__(None, None, None)


def get_tables(request: Request) -> Tables:
    dynamodb: DynamoDB = request.app.state.dynamodb
    return dynamodb.tables
