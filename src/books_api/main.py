"""Application factory + ASGI entrypoint (``uvicorn books_api.main:app``)."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import __version__
from .config import get_settings
from .db import close_dynamodb, open_dynamodb
from .routers import books, health
from .telemetry import instrument_app, setup_telemetry

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    setup_telemetry(settings)

    app.state.dynamodb = await open_dynamodb(settings)
    logger.info("books-api started (env=%s)", settings.environment)

    try:
        yield
    finally:
        await close_dynamodb(app.state.dynamodb)
        logger.info("books-api stopped")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="Books API",
        version=__version__,
        summary="A template REST API that serves book data.",
        lifespan=lifespan,
        debug=settings.debug,
    )
    app.include_router(health.router)
    app.include_router(books.router, prefix=settings.api_v1_prefix)
    instrument_app(app)
    return app


app = create_app()
