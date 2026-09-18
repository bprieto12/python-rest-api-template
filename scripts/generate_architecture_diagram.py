"""Regenerates ARCHITECTURE.md's Mermaid diagram from the layout below.

    uv run python scripts/generate_architecture_diagram.py

The diagram is a plain string constant, not something parsed out of
terraform/*.tf — this repo's infrastructure is small and stable enough that
hand-maintaining the picture is more reliable than a parser that'd need to
understand HCL well enough to infer intent, which the .tf files' comments
state directly but their resource graph alone doesn't. Update DIAGRAM here
when the architecture actually changes (a new terraform/*.tf resource that
changes the request path, a new hop, a new data store), then re-run this
script — don't hand-edit ARCHITECTURE.md, it gets overwritten.
"""

from __future__ import annotations

from pathlib import Path

OUTPUT_PATH = Path(__file__).parent.parent / "ARCHITECTURE.md"

DIAGRAM = """\
flowchart TB
    Caller(["Caller (machine-to-machine)"])

    subgraph Cognito_Group["Cognito — token issuer (cognito.tf)"]
        Cognito[("User Pool<br/>client_credentials grant<br/>scopes: books-api/read, books-api/write")]
    end

    Caller -- "1 . client_id + secret" --> Cognito
    Cognito -- "2 . access token" --> Caller

    Route53["Route 53<br/>custom domain (route53.tf)"]
    ACM["ACM certificate<br/>(acm.tf)"]

    subgraph Edge["API Gateway — the public entry point (api_gateway.tf)"]
        direction TB
        Authorizer["JWT Authorizer<br/>validates aud / issuer against Cognito"]
        Routes["Per-route scopes<br/>GET: read or write · POST/PATCH/DELETE: write"]
        Docs["/docs, /openapi.json<br/>(public, no auth)"]
        Authorizer --> Routes
    end

    Caller -- "3 . HTTPS + Bearer token" --> Route53
    Route53 -. alias .-> Edge
    ACM -. TLS termination .-> Edge
    Edge -. unauthenticated .-> Docs

    Routes -- "VPC Link (private)" --> ALB["Internal ALB<br/>(alb.tf — internal = true)"]

    subgraph VPC["VPC — private subnets (network.tf, security_groups.tf)"]
        ALB
        Kong["Kong — ECS service<br/>re-verifies JWT, per-consumer rate limit<br/>(kong.tf)"]
        BooksAPI["books-api — ECS service<br/>FastAPI (ecs.tf, main.tf)"]
        ALB -- "Service Connect" --> Kong
        Kong -- "Service Connect" --> BooksAPI
    end

    BooksAPI --> BooksTable[("DynamoDB: books<br/>PITR enabled (dynamodb.tf)")]
    BooksAPI --> IsbnsTable[("DynamoDB: isbns<br/>ISBN-uniqueness pointer table")]

    subgraph Observability["Observability (logs.tf, alarms.tf, dashboard.tf)"]
        Logs["CloudWatch Logs<br/>app + API Gateway access logs"]
        Alarms["CloudWatch Alarms<br/>unhealthy targets, 5xx, p99 latency, DynamoDB throttles"]
        SNS["SNS: alerts topic<br/>(subscribe yourself — nothing wired by default)"]
        Dashboard["CloudWatch Dashboard"]
        Alarms --> SNS
        Logs --> Dashboard
        Alarms --> Dashboard
    end

    Edge -. access logs .-> Logs
    BooksAPI -. traces + metrics via OTel .-> Logs
    Kong -. logs .-> Logs
    Edge -. 5xx / latency .-> Alarms
    BooksTable -. throttles .-> Alarms
    ALB -. unhealthy targets .-> Alarms
"""

HEADING = """\
# Architecture

<!--
  GENERATED FILE — do not edit by hand.
  Produced by scripts/generate_architecture_diagram.py; run
  `make architecture-diagram` (or the command above) to regenerate after
  changing the diagram there. Edits made directly to this file are
  overwritten the next time it runs.
-->

Machine-to-machine REST API on ECS Fargate, fronted by API Gateway (public
edge: TLS, JWT auth) with Kong behind it for the one thing API Gateway's
HTTP API generation can't do natively — per-consumer rate limiting. See
[`terraform/README.md`](terraform/README.md) for the full request-path
writeup and the reasoning behind each hop, and [`CLAUDE.md`](CLAUDE.md) for
the application-level architecture (routers → repository → DynamoDB).

```mermaid
{diagram}```
"""


def main() -> None:
    OUTPUT_PATH.write_text(HEADING.format(diagram=DIAGRAM))
    print(f"Wrote {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
