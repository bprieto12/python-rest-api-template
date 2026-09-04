"""Test fixtures.

By default the suite runs against an in-memory SQLite database so it needs no
services. Point ``TEST_DATABASE_URL`` at Postgres (as CI does) to exercise the
real driver:

    TEST_DATABASE_URL=postgresql+asyncpg://books:books@localhost:5432/books_test
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from books_api.db import Base
from books_api.main import create_app
from books_api.seed_data import BOOKS

TEST_DATABASE_URL = os.getenv("TEST_DATABASE_URL", "sqlite+aiosqlite:///:memory:")


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[object]:
    if TEST_DATABASE_URL.startswith("sqlite"):
        eng = create_async_engine(
            TEST_DATABASE_URL,
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
    else:
        eng = create_async_engine(TEST_DATABASE_URL)

    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    try:
        yield eng
    finally:
        async with eng.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await eng.dispose()


@pytest_asyncio.fixture
async def client(engine: object) -> AsyncIterator[AsyncClient]:
    """An HTTP client wired to a fresh app whose DB is the test engine.

    The FastAPI lifespan is deliberately skipped (no telemetry, no second
    engine); ``app.state`` is populated by hand instead.
    """
    app = create_app()
    app.state.engine = engine
    app.state.sessionmaker = async_sessionmaker(engine, expire_on_commit=False, autoflush=False)
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
