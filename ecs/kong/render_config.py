#!/usr/bin/env python3
"""Renders kong.yml from Cognito's JWKS + the current consumer list.

Kong OSS's `jwt` plugin verifies a token's signature against a public key
stored *in Kong itself* — there's no live-JWKS-fetching plugin in OSS (that's
Kong Enterprise's `openid-connect`). This script stands in for that: it
fetches Cognito's current signing key once (its caller does — see below) and
bakes it into every consumer's JWT credential. If Cognito ever rotates its
signing key, every consumer's credential here goes stale at once and
verification starts failing for everyone — re-run this (i.e. redeploy Kong)
to pick up the new key. Cognito rotates rarely, but not never.

Run by .github/workflows/cd.yml's build-and-push-kong job, right before
`docker build` — this writes kong.yml into the build context that
ecs/kong/Dockerfile then COPYs in, so the declarative config is baked into
the image (DB-less Kong reads it once at startup, no Admin API involved).

Usage:
    render_config.py --jwks jwks.json --consumers consumers.json \\
        --rate-limits rate-limits.json --upstream-host books-api \\
        --upstream-port 8000 --out kong.yml

`jwks.json` — Cognito's own JWKS endpoint response
  (https://cognito-idp.<region>.amazonaws.com/<user_pool_id>/.well-known/jwks.json).
`consumers.json` — {"<name>": "<cognito client_id>", ...}, i.e.
  `terraform output -json cognito_client_ids`.
`rate-limits.json` — {"default": {"minute": N}, "<name>": {"minute": N}, ...};
  see ecs/kong/rate-limits.<environment>.json. Any name without its own entry
  falls back to "default".
`--signing-kid` — optional. Cognito can publish more than one active RSA
  signing key at once (confirmed against real staging infra — not a rare
  rotation edge case, just a thing that happens), and the JWKS response
  gives no way to tell from the key list alone which one current tokens are
  actually signed with. Pass the `kid` from a real, freshly-issued token's
  header (cd.yml's build-and-push-kong job does this) to pick the *correct*
  key deterministically. Without it, this falls back to the first RSA
  signing key in the JWKS and prints a warning — a guess, not a guarantee.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


def _b64url_to_int(value: str) -> int:
    padding = "=" * (-len(value) % 4)
    return int.from_bytes(base64.urlsafe_b64decode(value + padding), "big")


def jwk_to_pem(jwk: dict) -> str:
    public_numbers = rsa.RSAPublicNumbers(e=_b64url_to_int(jwk["e"]), n=_b64url_to_int(jwk["n"]))
    pem = public_numbers.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return pem.decode("ascii")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--jwks", required=True)
    parser.add_argument("--consumers", required=True)
    parser.add_argument("--rate-limits", required=True)
    parser.add_argument("--upstream-host", required=True)
    parser.add_argument("--upstream-port", required=True, type=int)
    parser.add_argument("--signing-kid", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.jwks) as f:
        jwks = json.load(f)
    with open(args.consumers) as f:
        consumers = json.load(f)
    with open(args.rate_limits) as f:
        rate_limits = json.load(f)

    signing_keys = [
        k for k in jwks["keys"] if k.get("kty") == "RSA" and k.get("use", "sig") == "sig"
    ]
    if not signing_keys:
        raise SystemExit("No RSA signing key found in the JWKS response")

    chosen_key = None
    if args.signing_kid:
        chosen_key = next((k for k in signing_keys if k.get("kid") == args.signing_kid), None)
        if chosen_key is None:
            raise SystemExit(
                f"--signing-kid {args.signing_kid!r} not found in the JWKS response "
                f"(kids present: {[k.get('kid') for k in signing_keys]})"
            )
    if chosen_key is None:
        if len(signing_keys) > 1:
            print(
                f"WARNING: JWKS has {len(signing_keys)} RSA signing keys and no --signing-kid "
                "was given — guessing the first one. Kong's JWT verification will fail for any "
                "token actually signed with a different key. Pass --signing-kid instead.",
                file=sys.stderr,
            )
        chosen_key = signing_keys[0]
    rsa_public_key = jwk_to_pem(chosen_key)

    default_limit = rate_limits.get("default", {"minute": 100})

    config: dict = {
        "_format_version": "3.0",
        "services": [
            {
                "name": "books-api",
                "url": f"http://{args.upstream_host}:{args.upstream_port}",
                "routes": [{"name": "books-api-route", "paths": ["/"], "strip_path": False}],
            }
        ],
        "consumers": [],
        "jwt_secrets": [],
        # Global defaults: every request must carry a valid JWT (no route is
        # left unauthenticated at Kong, mirroring API Gateway's own
        # authorizer), and gets the default rate limit unless its consumer
        # has an override below.
        "plugins": [
            {"name": "jwt", "config": {"key_claim_name": "client_id", "claims_to_verify": ["exp"]}},
            {"name": "rate-limiting", "config": {**default_limit, "policy": "local"}},
        ],
    }

    for name, client_id in consumers.items():
        config["consumers"].append({"username": name})
        config["jwt_secrets"].append(
            {
                "consumer": name,
                "key": client_id,  # matched against the token's client_id claim, not the JWK's kid
                "algorithm": "RS256",
                "rsa_public_key": rsa_public_key,
            }
        )
        override = rate_limits.get(name)
        if override:
            config["plugins"].append(
                {
                    "name": "rate-limiting",
                    "consumer": name,
                    "config": {**override, "policy": "local"},
                }
            )

    with open(args.out, "w") as f:
        json.dump(config, f, indent=2)  # valid YAML too — Kong's loader accepts either


if __name__ == "__main__":
    main()
