"""Test fixtures.

The suite runs against a local, in-process DynamoDB double — no Docker, no
real AWS. moto's usual ``@mock_aws`` decorator only patches ``botocore``
internals, which this app's async ``aioboto3``/``aiobotocore`` calls don't go
through, so it silently doesn't intercept anything here. moto's *server*
mode (``ThreadedMotoServer``) is a real local HTTP server instead — it works
with any HTTP client, aiobotocore included — so that's what this uses.

Fake AWS credentials are set below since aiobotocore refuses to even attempt
a signed request with none present, regardless of the target being local.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import aioboto3
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from moto.server import ThreadedMotoServer

os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from books_api.db import DynamoDB, Tables
from books_api.main import create_app
from books_api.seed_data import BOOKS

BOOKS_TABLE = "books-api-books-test"
ISBNS_TABLE = "books-api-isbns-test"


@pytest.fixture(scope="session")
def moto_endpoint() -> AsyncIterator[str]:
    server = ThreadedMotoServer(port=0)
    server.start()
    port = server._server.socket.getsockname()[1]  # no public accessor for an ephemeral port
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.stop()


@pytest_asyncio.fixture
async def dynamodb(moto_endpoint: str) -> AsyncIterator[DynamoDB]:
    """A fresh pair of tables per test, against the session-wide moto server."""
    session = aioboto3.Session(region_name="us-east-1")
    async with session.resource("dynamodb", endpoint_url=moto_endpoint) as resource:
        books = await resource.create_table(
            TableName=BOOKS_TABLE,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "N"}],
            BillingMode="PAY_PER_REQUEST",
        )
        await books.wait_until_exists()
        isbns = await resource.create_table(
            TableName=ISBNS_TABLE,
            KeySchema=[{"AttributeName": "isbn", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "isbn", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        await isbns.wait_until_exists()
        try:
            yield DynamoDB(resource_cm=None, resource=resource, tables=Tables(books=books, isbns=isbns))
        finally:
            await books.delete()
            await isbns.delete()


@pytest_asyncio.fixture
async def client(dynamodb: DynamoDB) -> AsyncIterator[AsyncClient]:
    """An HTTP client wired to a fresh app whose tables are the test ones.

    The FastAPI lifespan is deliberately skipped (no telemetry, no second
    DynamoDB resource); ``app.state`` is populated by hand instead.
    """
    app = create_app()
    app.state.dynamodb = dynamodb
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest_asyncio.fixture
async def seeded_client(client: AsyncClient) -> AsyncClient:
    for book in BOOKS[:5]:
        resp = await client.post("/api/v1/books", json=book)
        assert resp.status_code == 201, resp.text
    return client


@pytest.fixture
def sample_book() -> dict[str, object]:
    return {
        "title": "Test-Driven Development",
        "author": "Kent Beck",
        "isbn": "9780321146533",
        "genre": "software",
        "published_year": 2002,
        "price": 39.99,
        "in_stock": 3,
        "description": "Red, green, refactor.",
    }
