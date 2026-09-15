"""Data-access layer over the two DynamoDB tables — no HTTP here.

Two tables (see ``db.py``/``config.py``):

- ``books`` — the actual records, partition key ``id`` (a plain int, handed
  out by an atomic counter stored *in this same table* under the reserved
  key ``id=0`` — see ``_next_id``). DynamoDB has no autoincrement.
- ``isbns`` — one pointer item per ISBN (``{"isbn": ..., "book_id": ...}``),
  which exists purely so ISBN uniqueness can be enforced with a conditional
  write (``attribute_not_exists(isbn)``). DynamoDB has no secondary unique
  constraint, so this is the standard workaround: a second table keyed on
  the thing you need to be unique.

**Listing is a full table Scan, filtered and sorted in Python.** DynamoDB is
a key-value store, not a query engine — there's no server-side equivalent of
SQL's case-insensitive ``ILIKE '%term%'`` (title/description search) short of
a real search index (OpenSearch, etc.), which is well out of proportion for
a small mock catalogue. ``genre`` (an exact match) is pushed down as a scan
``FilterExpression`` since DynamoDB can do that natively; ``author``/``q``
substring matching happens after the scan, in Python. This is the honest
trade-off of choosing DynamoDB for its cost profile over a query engine —
fine at hundreds of items, not at hundreds of thousands. Revisit (a GSI on
genre, or a real search index) if the catalogue ever grows into that regime.
"""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

from .db import Tables
from .models import Book
from .schemas import BookCreate, BookUpdate

_COUNTER_ID = 0  # reserved — never a real book id, excluded from scans/listings


class IsbnConflictError(Exception):
    """Raised when a create/update would claim an ISBN another book already has."""


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _from_item(item: dict[str, Any]) -> Book:
    return Book(
        id=int(item["id"]),
        title=item["title"],
        author=item["author"],
        isbn=item["isbn"],
        genre=item.get("genre"),
        published_year=int(item["published_year"]) if "published_year" in item else None,
        price=Decimal(item["price"]),
        in_stock=int(item["in_stock"]),
        description=item.get("description"),
        created_at=datetime.fromisoformat(item["created_at"]),
        updated_at=datetime.fromisoformat(item["updated_at"]),
    )


def _book_item(
    book_id: int, data: dict[str, Any], *, created_at: str, updated_at: str
) -> dict[str, Any]:
    """Build a DynamoDB item, omitting unset optional fields rather than storing NULLs."""
    item: dict[str, Any] = {
        "id": book_id,
        "title": data["title"],
        "author": data["author"],
        "isbn": data["isbn"],
        "price": Decimal(str(data["price"])),
        "in_stock": data["in_stock"],
        "created_at": created_at,
        "updated_at": updated_at,
    }
    if data.get("genre") is not None:
        item["genre"] = data["genre"]
    if data.get("published_year") is not None:
        item["published_year"] = data["published_year"]
    if data.get("description") is not None:
        item["description"] = data["description"]
    return item


async def _next_id(tables: Tables) -> int:
    resp = await tables.books.update_item(
        Key={"id": _COUNTER_ID},
        UpdateExpression="ADD next_id :one",
        ExpressionAttributeValues={":one": 1},
        ReturnValues="UPDATED_NEW",
    )
    return int(resp["Attributes"]["next_id"])


async def _scan_all(tables: Tables, *, genre: str | None) -> list[dict[str, Any]]:
    filter_expr = Attr("id").gt(_COUNTER_ID)
    if genre:
        filter_expr = filter_expr & Attr("genre").eq(genre)

    items: list[dict[str, Any]] = []
    scan_kwargs: dict[str, Any] = {"FilterExpression": filter_expr}
    while True:
        resp = await tables.books.scan(**scan_kwargs)
        items.extend(resp["Items"])
        if "LastEvaluatedKey" not in resp:
            return items
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


async def list_books(
    tables: Tables,
    *,
    limit: int,
    offset: int,
    genre: str | None = None,
    author: str | None = None,
    q: str | None = None,
) -> tuple[list[Book], int]:
    raw_items = await _scan_all(tables, genre=genre)
    books = [_from_item(item) for item in raw_items]

    if author:
        needle = author.lower()
        books = [b for b in books if needle in b.author.lower()]
    if q:
        needle = q.lower()
        books = [
            b
            for b in books
            if needle in b.title.lower() or (b.description and needle in b.description.lower())
        ]

    books.sort(key=lambda b: (b.title, b.id))
    total = len(books)
    return books[offset : offset + limit], total


async def get_book(tables: Tables, book_id: int) -> Book | None:
    if book_id == _COUNTER_ID:
        return None  # the counter item isn't a book, regardless of what's asked for
    resp = await tables.books.get_item(Key={"id": book_id})
    item = resp.get("Item")
    return _from_item(item) if item else None


async def get_book_by_isbn(tables: Tables, isbn: str) -> Book | None:
    pointer = (await tables.isbns.get_item(Key={"isbn": isbn})).get("Item")
    if pointer is None:
        return None
    return await get_book(tables, int(pointer["book_id"]))


async def create_book(tables: Tables, data: BookCreate) -> Book:
    book_id = await _next_id(tables)
    now = _now_iso()
    payload = data.model_dump()

    # Claim the ISBN first — a single conditional write is atomic on its own,
    # unlike sequencing two independent put_items, so this is the operation
    # that actually decides the race, not the book-item write that follows.
    try:
        await tables.isbns.put_item(
            Item={"isbn": data.isbn, "book_id": book_id},
            ConditionExpression="attribute_not_exists(isbn)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise IsbnConflictError(data.isbn) from exc
        raise

    try:
        await tables.books.put_item(
            Item=_book_item(book_id, payload, created_at=now, updated_at=now)
        )
    except Exception:
        # Best-effort compensation: don't leave the ISBN permanently claimed
        # by a book that was never actually created.
        await tables.isbns.delete_item(Key={"isbn": data.isbn})
        raise

    book = await get_book(tables, book_id)
    assert book is not None  # just written, above
    return book


async def update_book(tables: Tables, book: Book, data: BookUpdate) -> Book:
    changes = data.model_dump(exclude_unset=True)
    now = _now_iso()

    new_isbn = changes.get("isbn")
    if new_isbn and new_isbn != book.isbn:
        try:
            await tables.isbns.put_item(
                Item={"isbn": new_isbn, "book_id": book.id},
                ConditionExpression="attribute_not_exists(isbn)",
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise IsbnConflictError(new_isbn) from exc
            raise
        try:
            await _apply_update(tables, book.id, changes, updated_at=now)
        except Exception:
            await tables.isbns.delete_item(Key={"isbn": new_isbn})  # roll back the claim
            raise
        await tables.isbns.delete_item(Key={"isbn": book.isbn})  # release the old one
    else:
        await _apply_update(tables, book.id, changes, updated_at=now)

    updated = await get_book(tables, book.id)
    assert updated is not None  # just updated, above
    return updated


async def _apply_update(
    tables: Tables, book_id: int, changes: dict[str, Any], *, updated_at: str
) -> None:
    changes = {**changes, "updated_at": updated_at}
    set_parts: list[str] = []
    remove_parts: list[str] = []
    names: dict[str, str] = {}
    values: dict[str, Any] = {}

    for field, value in changes.items():
        placeholder = f"#{field}"
        names[placeholder] = field
        if value is None:
            remove_parts.append(placeholder)
        else:
            value_placeholder = f":{field}"
            if field == "price":
                value = Decimal(str(value))
            set_parts.append(f"{placeholder} = {value_placeholder}")
            values[value_placeholder] = value

    expression = ""
    if set_parts:
        expression += "SET " + ", ".join(set_parts) + " "
    if remove_parts:
        expression += "REMOVE " + ", ".join(remove_parts)

    kwargs: dict[str, Any] = {
        "Key": {"id": book_id},
        "UpdateExpression": expression.strip(),
        "ExpressionAttributeNames": names,
    }
    if values:
        kwargs["ExpressionAttributeValues"] = values
    await tables.books.update_item(**kwargs)


async def delete_book(tables: Tables, book: Book) -> None:
    await tables.books.delete_item(Key={"id": book.id})
    await tables.isbns.delete_item(Key={"isbn": book.isbn})
