"""Request/response models. These are the API contract."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

_CURRENT_YEAR_CEILING = 2100


class BookBase(BaseModel):
    title: str = Field(min_length=1, max_length=512)
    author: str = Field(min_length=1, max_length=256)
    isbn: str = Field(min_length=10, max_length=20, description="ISBN-10 or ISBN-13")
    genre: str | None = Field(default=None, max_length=64)
    published_year: int | None = Field(default=None, ge=0, le=_CURRENT_YEAR_CEILING)
    price: float = Field(default=0.0, ge=0)
    in_stock: int = Field(default=0, ge=0)
    description: str | None = None


class BookCreate(BookBase):
    pass


class BookUpdate(BaseModel):
    """Every field optional — this is a PATCH body."""

    title: str | None = Field(default=None, min_length=1, max_length=512)
    author: str | None = Field(default=None, min_length=1, max_length=256)
    isbn: str | None = Field(default=None, min_length=10, max_length=20)
    genre: str | None = Field(default=None, max_length=64)
    published_year: int | None = Field(default=None, ge=0, le=_CURRENT_YEAR_CEILING)
    price: float | None = Field(default=None, ge=0)
    in_stock: int | None = Field(default=None, ge=0)
    description: str | None = None


class BookRead(BookBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    updated_at: datetime


class BookPage(BaseModel):
    items: list[BookRead]
    total: int
    limit: int
    offset: int
