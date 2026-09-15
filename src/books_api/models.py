"""The book record shape. Not a DynamoDB item directly — see repository.py's
``_from_item``/``_book_item`` for the mapping to actual DynamoDB attribute
types (numbers round-trip as ``Decimal`` at the wire level; timestamps are
stored as ISO 8601 strings). Kept as a plain dataclass, with
``BookRead.model_config = ConfigDict(from_attributes=True)`` in schemas.py
reading it the same way it used to read a SQLAlchemy ORM instance.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal


@dataclass
class Book:
    id: int
    title: str
    author: str
    isbn: str
    genre: str | None
    published_year: int | None
    price: Decimal
    in_stock: int
    description: str | None
    created_at: datetime
    updated_at: datetime
