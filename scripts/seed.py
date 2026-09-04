"""Idempotently load the mock catalogue into the configured database.

    uv run python scripts/seed.py

Assumes the schema already exists (run ``uv run alembic upgrade head`` first).
Pass ``--create-all`` to create tables directly instead — handy for a throwaway
local database, but never in a real environment where Alembic owns the schema.
"""

from __future__ import annotations

import argparse
import asyncio

from sqlalchemy import select

from books_api.config import get_settings
from books_api.db import Base, create_engine, create_sessionmaker
from books_api.models import Book
from books_api.seed_data import BOOKS


async def seed(*, create_all: bool) -> None:
    settings = get_settings()
    engine = create_engine(settings)
    try:
        if create_all:
            async with engine.begin() as conn:
                await conn.run_sync(Base.metadata.create_all)

        sessionmaker = create_sessionmaker(engine)
        async with sessionmaker() as session:
            existing = set((await session.execute(select(Book.isbn))).scalars().all())
            added = 0
            for row in BOOKS:
                if row["isbn"] in existing:
                    continue
                session.add(Book(**row))
                added += 1
            await session.commit()
        print(f"seeded {added} new book(s); {len(BOOKS) - added} already present")
    finally:
        await engine.dispose()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--create-all",
        action="store_true",
        help="create tables via SQLAlchemy metadata instead of requiring migrations",
    )
    args = parser.parse_args()
    asyncio.run(seed(create_all=args.create_all))


if __name__ == "__main__":
    main()
