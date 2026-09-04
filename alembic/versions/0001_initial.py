"""initial books table

Revision ID: 0001_initial
Revises:
Create Date: 2026-09-03
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "books",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("author", sa.String(length=256), nullable=False),
        sa.Column("isbn", sa.String(length=20), nullable=False),
        sa.Column("genre", sa.String(length=64), nullable=True),
        sa.Column("published_year", sa.Integer(), nullable=True),
        sa.Column("price", sa.Numeric(precision=10, scale=2), nullable=False),
        sa.Column("in_stock", sa.Integer(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
    )
    op.create_index("ix_books_title", "books", ["title"])
    op.create_index("ix_books_author", "books", ["author"])
    op.create_index("ix_books_genre", "books", ["genre"])
    op.create_index("ix_books_isbn", "books", ["isbn"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_books_isbn", table_name="books")
    op.drop_index("ix_books_genre", table_name="books")
    op.drop_index("ix_books_author", table_name="books")
    op.drop_index("ix_books_title", table_name="books")
    op.drop_table("books")
