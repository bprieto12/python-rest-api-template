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


class _QuietHealthChecks(logging.Filter):
    """Drop uvicorn's access-log line for a *successful* /healthz or /readyz.

    They're hit every ~30s, forever, by the ALB and container health checks
    — once the deployment is stable those lines are pure noise. A failing
    health check still logs normally (status is the last of uvicorn's five
    %-args: client_addr, method, path, http_version, status — see
    uvicorn.protocols.http.h11_impl's access_logger.info call) — that's the
    one case actually worth seeing.
    """

    _quiet_paths = ("/healthz", "/readyz")

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if not isinstance(args, tuple) or len(args) < 5:
            return True
        path, status = args[2], args[4]
        is_quiet_path = any(path == p or str(path).startswith(f"{p}?") for p in self._quiet_paths)
        return not (is_quiet_path and isinstance(status, int) and 200 <= status < 300)


logging.getLogger("uvicorn.access").addFilter(_QuietHealthChecks())


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
