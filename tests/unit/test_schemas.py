"""Pure validation tests for the Pydantic wire contract — no app, no I/O."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal

import pytest
from pydantic import ValidationError

from books_api.models import Book
from books_api.schemas import BookCreate, BookRead, BookUpdate


def _payload(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "Test-Driven Development",
        "author": "Kent Beck",
        "isbn": "9780321146533",
    }
    base.update(overrides)
    return base


def test_book_create_accepts_a_minimal_valid_payload() -> None:
    book = BookCreate(**_payload())
    assert book.title == "Test-Driven Development"
    assert book.price == 0.0
    assert book.in_stock == 0
    assert book.genre is None


@pytest.mark.parametrize(
    "overrides",
    [
        {"title": ""},
        {"author": ""},
        {"isbn": "too-short"},
        {"isbn": "0" * 21},
        {"price": -0.01},
        {"in_stock": -1},
        {"published_year": -1},
        {"published_year": 2101},
    ],
)
def test_book_create_rejects_invalid_fields(overrides: dict[str, object]) -> None:
    with pytest.raises(ValidationError):
        BookCreate(**_payload(**overrides))


def test_book_update_defaults_every_field_to_unset() -> None:
    update = BookUpdate()
    assert update.model_dump(exclude_unset=True) == {}


def test_book_update_exclude_unset_only_includes_provided_fields() -> None:
    update = BookUpdate(price=9.99, in_stock=42)
    assert update.model_dump(exclude_unset=True) == {"price": 9.99, "in_stock": 42}


def test_book_update_rejects_invalid_fields_when_present() -> None:
    with pytest.raises(ValidationError):
        BookUpdate(title="")


def test_book_read_builds_from_a_book_dataclass() -> None:
    now = datetime.now(UTC)
    book = Book(
        id=1,
        title="Dune",
        author="Frank Herbert",
        isbn="9780441013593",
        genre="science fiction",
        published_year=1965,
        price=Decimal("12.50"),
        in_stock=3,
        description=None,
        created_at=now,
        updated_at=now,
    )
    read = BookRead.model_validate(book)
    assert read.id == 1
    assert read.title == "Dune"
    assert read.price == 12.50
