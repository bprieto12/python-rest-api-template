"""OpenTelemetry wiring: metrics + traces, with a console fallback.

``setup_telemetry`` installs global providers once per process. ``instrument_app``
attaches the FastAPI middleware to a specific app. Both are safe to call more
than once (relevant to the test suite, which builds many apps).

DynamoDB calls are instrumented globally via ``BotocoreInstrumentor`` (it
patches botocore's request pipeline, which aioboto3/aiobotocore also runs
through) rather than per-resource like the old SQLAlchemy engine hook — boto3
resources have no single object to attach a per-engine instrumentor to.
"""

from __future__ import annotations

import logging

from opentelemetry import metrics, trace
from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import (
    ConsoleMetricExporter,
    MetricExporter,
    MetricReader,
    PeriodicExportingMetricReader,
)
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter, SpanExporter

from .config import Settings

logger = logging.getLogger(__name__)

_METER_NAME = "books_api"
_configured = False


def _metric_exporter(settings: Settings) -> MetricExporter:
    if settings.otel_exporter_otlp_protocol == "grpc":
        from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

        return OTLPMetricExporter(endpoint=settings.otel_exporter_otlp_endpoint)
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter as HTTPExp

    return HTTPExp(endpoint=settings.otel_exporter_otlp_endpoint)


def _span_exporter(settings: Settings) -> SpanExporter:
    if settings.otel_exporter_otlp_protocol == "grpc":
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

        return OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint)
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter as HTTPExp

    return HTTPExp(endpoint=settings.otel_exporter_otlp_endpoint)


def setup_telemetry(settings: Settings) -> None:
    global _configured
    if _configured or not settings.otel_enabled:
        return

    resource = Resource.create(
        {
            "service.name": settings.otel_service_name,
            "deployment.environment": settings.environment,
        }
    )
    interval = settings.otel_metric_export_interval_ms
    has_otlp = bool(settings.otel_exporter_otlp_endpoint)

    readers: list[MetricReader] = []
    if has_otlp:
        readers.append(PeriodicExportingMetricReader(_metric_exporter(settings), export_interval_millis=interval))
    if settings.otel_console_export or not has_otlp:
        readers.append(PeriodicExportingMetricReader(ConsoleMetricExporter(), export_interval_millis=interval))
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=readers))

    tracer_provider = TracerProvider(resource=resource)
    if has_otlp:
        tracer_provider.add_span_processor(BatchSpanProcessor(_span_exporter(settings)))
    if settings.otel_console_export:
        tracer_provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    try:
        BotocoreInstrumentor().instrument()  # type: ignore[no-untyped-call]
    except Exception:  # already instrumented (e.g. re-import in tests) — keep booting
        logger.debug("botocore instrumentation skipped", exc_info=True)

    _configured = True
    logger.info("OpenTelemetry configured (otlp=%s)", settings.otel_exporter_otlp_endpoint or "off")


def instrument_app(app: object) -> None:
    try:
        # Health/readiness probes are hit every ~30s, forever, by the ALB and
        # container health checks — excluding them here drops both the trace
        # spans AND the http.server.* metrics for those paths (excluded_urls
        # feeds the one middleware that emits both), not just one or the
        # other. Unlike the uvicorn access-log filter in main.py, this
        # excludes them unconditionally, failures included — a health check
        # transitioning to unhealthy is already visible via ECS/ALB target
        # health directly, without needing a dedicated trace for it.
        FastAPIInstrumentor.instrument_app(app, excluded_urls="/healthz,/readyz")  # type: ignore[arg-type]
    except Exception:
        logger.debug("fastapi instrumentation skipped", exc_info=True)


def get_meter() -> metrics.Meter:
    return metrics.get_meter(_METER_NAME)
