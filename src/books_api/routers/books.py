"""CRUD endpoints for books, mounted under ``settings.api_v1_prefix``."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from .. import repository
from ..db import Tables, get_tables
from ..schemas import BookCreate, BookPage, BookRead, BookUpdate
from ..telemetry import get_meter

router = APIRouter(prefix="/books", tags=["books"])

_book_writes = get_meter().create_counter(
    "books.writes",
    unit="1",
    description="Count of create/update/delete operations on books",
)

TablesDep = Annotated[Tables, Depends(get_tables)]


@router.get("", response_model=BookPage, summary="List books")
async def list_books(
    tables: TablesDep,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
    genre: str | None = None,
    author: str | None = None,
    q: Annotated[str | None, Query(description="Full-text-ish match on title/description")] = None,
) -> BookPage:
    rows, total = await repository.list_books(
        tables, limit=limit, offset=offset, genre=genre, author=author, q=q
    )
    return BookPage(
        items=[BookRead.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post(
    "",
    response_model=BookRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create a book",
)
async def create_book(payload: BookCreate, tables: TablesDep) -> BookRead:
    if await repository.get_book_by_isbn(tables, payload.isbn):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A book with ISBN {payload.isbn} already exists",
        )
    try:
        book = await repository.create_book(tables, payload)
    except repository.IsbnConflictError as exc:
        # The pre-check above missed a concurrent create — the conditional
        # write in the repository is what actually caught it.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A book with ISBN {exc} already exists",
        ) from exc
    _book_writes.add(1, {"op": "create"})
    return BookRead.model_validate(book)


@router.get("/{book_id}", response_model=BookRead, summary="Get a book by id")
async def get_book(book_id: int, tables: TablesDep) -> BookRead:
    book = await repository.get_book(tables, book_id)
    if book is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Book not found")
    return BookRead.model_validate(book)


@router.patch("/{book_id}", response_model=BookRead, summary="Partially update a book")
async def update_book(book_id: int, payload: BookUpdate, tables: TablesDep) -> BookRead:
    book = await repository.get_book(tables, book_id)
    if book is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Book not found")
    if payload.isbn and payload.isbn != book.isbn:
        clash = await repository.get_book_by_isbn(tables, payload.isbn)
        if clash is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"A book with ISBN {payload.isbn} already exists",
            )
    try:
        updated = await repository.update_book(tables, book, payload)
    except repository.IsbnConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A book with ISBN {exc} already exists",
        ) from exc
    _book_writes.add(1, {"op": "update"})
    return BookRead.model_validate(updated)


@router.delete("/{book_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete a book")
async def delete_book(book_id: int, tables: TablesDep) -> Response:
    book = await repository.get_book(tables, book_id)
    if book is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Book not found")
    await repository.delete_book(tables, book)
    _book_writes.add(1, {"op": "delete"})
    return Response(status_code=status.HTTP_204_NO_CONTENT)
