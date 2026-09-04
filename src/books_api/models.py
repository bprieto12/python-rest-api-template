"""ORM models. Kept portable so the test suite can run on SQLite."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from sqlalchemy import DateTime, Integer, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


class Book(Base):
    __tablename__ = "books"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(512), index=True)
    author: Mapped[str] = mapped_column(String(256), index=True)
    isbn: Mapped[str] = mapped_column(String(20), unique=True, index=True)
    genre: Mapped[str | None] = mapped_column(String(64), index=True, default=None)
    published_year: Mapped[int | None] = mapped_column(Integer, default=None)
    price: Mapped[Decimal] = mapped_column(Numeric(10, 2), default=Decimal("0.00"))
    in_stock: Mapped[int] = mapped_column(Integer, default=0)
    description: Mapped[str | None] = mapped_column(Text, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
