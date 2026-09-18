"""Unit tests for repository.py's pure DynamoDB item <-> Book mapping helpers.

These don't touch DynamoDB at all — no moto, no network — so they belong in
unit, not integration.
"""

from __future__ import annotations

from decimal import Decimal

from books_api.repository import _book_item, _from_item


def test_book_item_omits_unset_optional_fields() -> None:
    data = {
        "title": "Dune",
        "author": "Frank Herbert",
        "isbn": "9780441013593",
        "price": 12.5,
        "in_stock": 3,
        "genre": None,
        "published_year": None,
        "description": None,
    }
    item = _book_item(1, data, created_at="2024-01-01T00:00:00+00:00", updated_at="2024-01-01T00:00:00+00:00")
    assert "genre" not in item
    assert "published_year" not in item
    assert "description" not in item
    assert item["price"] == Decimal("12.5")


def test_book_item_includes_optional_fields_when_set() -> None:
    data = {
        "title": "Dune",
        "author": "Frank Herbert",
        "isbn": "9780441013593",
        "price": 12.5,
        "in_stock": 3,
        "genre": "science fiction",
        "published_year": 1965,
        "description": "Sci-fi classic.",
    }
    item = _book_item(1, data, created_at="2024-01-01T00:00:00+00:00", updated_at="2024-01-01T00:00:00+00:00")
    assert item["genre"] == "science fiction"
    assert item["published_year"] == 1965
    assert item["description"] == "Sci-fi classic."


def test_from_item_round_trips_types() -> None:
    item = {
        "id": Decimal("1"),
        "title": "Dune",
        "author": "Frank Herbert",
        "isbn": "9780441013593",
        "genre": "science fiction",
        "published_year": Decimal("1965"),
        "price": Decimal("12.50"),
        "in_stock": Decimal("3"),
        "description": "Sci-fi classic.",
        "created_at": "2024-01-01T00:00:00+00:00",
        "updated_at": "2024-01-01T00:00:00+00:00",
    }
    book = _from_item(item)
    assert book.id == 1
    assert isinstance(book.id, int)
    assert book.published_year == 1965
    assert book.price == Decimal("12.50")
    assert book.created_at.isoformat() == "2024-01-01T00:00:00+00:00"


def test_from_item_handles_missing_optional_fields() -> None:
    item = {
        "id": Decimal("2"),
        "title": "Untitled",
        "author": "Anonymous",
        "isbn": "0000000000",
        "price": Decimal("0"),
        "in_stock": Decimal("0"),
        "created_at": "2024-01-01T00:00:00+00:00",
        "updated_at": "2024-01-01T00:00:00+00:00",
    }
    book = _from_item(item)
    assert book.genre is None
    assert book.published_year is None
    assert book.description is None
