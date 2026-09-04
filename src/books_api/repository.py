"""Data-access layer. Pure functions over an :class:`AsyncSession` — no HTTP here."""

from __future__ import annotations

from collections.abc import Sequence

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Book
from .schemas import BookCreate, BookUpdate


async def list_books(
    session: AsyncSession,
    *,
    limit: int,
    offset: int,
    genre: str | None = None,
    author: str | None = None,
    q: str | None = None,
) -> tuple[Sequence[Book], int]:
    filters = []
    if genre:
        filters.append(Book.genre == genre)
    if author:
        filters.append(Book.author.ilike(f"%{author}%"))
    if q:
        like = f"%{q}%"
        filters.append(or_(Book.title.ilike(like), Book.description.ilike(like)))

    rows_stmt = (
        select(Book).where(*filters).order_by(Book.title, Book.id).limit(limit).offset(offset)
    )
    count_stmt = select(func.count()).select_from(Book).where(*filters)

    total = (await session.execute(count_stmt)).scalar_one()
    rows = (await session.execute(rows_stmt)).scalars().all()
    return rows, total


async def get_book(session: AsyncSession, book_id: int) -> Book | None:
    return await session.get(Book, book_id)


async def get_book_by_isbn(session: AsyncSession, isbn: str) -> Book | None:
    return (await session.execute(select(Book).where(Book.isbn == isbn))).scalar_one_or_none()


async def create_book(session: AsyncSession, data: BookCreate) -> Book:
    book = Book(**data.model_dump())
    session.add(book)
    await session.flush()
    await session.refresh(book)
    return book


async def update_book(session: AsyncSession, book: Book, data: BookUpdate) -> Book:
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(book, field, value)
    await session.flush()
    await session.refresh(book)
    return book


async def delete_book(session: AsyncSession, book: Book) -> None:
    await session.delete(book)
    await session.flush()
