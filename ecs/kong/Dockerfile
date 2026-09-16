# DB-less Kong: the declarative config (kong.yml) is baked in at build time,
# not fetched or templated at container startup — no Postgres, no Admin API
# calls, nothing stateful to run alongside this. render_config.py produces
# kong.yml from the current Cognito consumers/JWKS + ecs/kong/rate-limits.*.json
# before this image is built — see .github/workflows/cd.yml's build-and-push-kong
# job, which runs that script right before `docker build`.
FROM kong:3.7

COPY kong.yml /kong.yml

ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/kong.yml \
    KONG_PROXY_LISTEN="0.0.0.0:8000" \
    KONG_STATUS_LISTEN="0.0.0.0:8100" \
    KONG_ADMIN_LISTEN="off"

EXPOSE 8000 8100
