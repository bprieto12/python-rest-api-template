"""Async SQLAlchemy engine / session plumbing.

The engine and sessionmaker are created once per running app in the FastAPI
lifespan (see :mod:`books_api.main`) and stashed on ``app.state`` so that tests
can substitute their own. Request handlers get a session via the
:func:`get_session` dependency.
"""

from __future__ import annotations

from collections.abc import AsyncGenerator

from fastapi import Request
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from .config import Settings


class Base(DeclarativeBase):
    """Declarative base for every ORM model."""


def create_engine(settings: Settings) -> AsyncEngine:
    kwargs: dict[str, object] = {"echo": settings.db_echo, "pool_pre_ping": True}
    # QueuePool tuning is meaningless for SQLite's NullPool and raises if passed.
    if not settings.database_url.startswith("sqlite"):
        kwargs["pool_size"] = settings.db_pool_size
        kwargs["max_overflow"] = settings.db_max_overflow
    return create_async_engine(settings.database_url, **kwargs)


def create_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False, autoflush=False)


async def get_session(request: Request) -> AsyncGenerator[AsyncSession, None]:
    """Yield a session that commits on success and rolls back on error."""
    sessionmaker: async_sessionmaker[AsyncSession] = request.app.state.sessionmaker
    session = sessionmaker()
    try:
        yield session
        await session.commit()
    except Exception:
        await session.rollback()
        raise
    finally:
        await session.close()
