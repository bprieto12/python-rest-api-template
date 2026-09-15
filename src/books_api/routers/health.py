"""Liveness and readiness probes (mounted at the root, not under /api/v1)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from ..db import Tables, get_tables

router = APIRouter(tags=["health"])


@router.get("/healthz", summary="Liveness probe")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz", summary="Readiness probe")
async def readyz(tables: Annotated[Tables, Depends(get_tables)]) -> dict[str, str]:
    # .load() does a DescribeTable call — cheap, and a real connectivity +
    # existence check, unlike just inspecting already-cached metadata.
    await tables.books.load()
    return {"status": "ready"}


@router.get("/", include_in_schema=False)
async def root() -> dict[str, str]:
    return {"status": "ok", "docs": "/docs"}
