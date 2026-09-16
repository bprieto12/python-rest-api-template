// Smoke test: one VU, a handful of iterations, read path only (no writes) —
// safe to run against any environment, including production, with
// negligible load. This is "is it actually up and correctly wired end to
// end" check (auth, routing, DynamoDB reads all working), not a load test —
// see load.js for that.
//
// Usage:
//   BASE_URL=https://staging.books-api.example.com \
//   COGNITO_CLIENT_ID=... COGNITO_CLIENT_SECRET=... COGNITO_DOMAIN=... \
//     k6 run perf/smoke.js
//
// Against local dev (no auth, no API Gateway in front — see docker-compose):
//   BASE_URL=http://localhost:8000 k6 run perf/smoke.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { getAuthHeaders } from './lib/auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

export const options = {
  vus: 1,
  iterations: 5,
  thresholds: {
    http_req_failed: ['rate==0'],
    http_req_duration: ['p(95)<2000'],
  },
};

export function setup() {
  return { headers: getAuthHeaders() };
}

export default function (data) {
  const params = { headers: data.headers };

  const health = http.get(`${BASE_URL}/healthz`, params);
  check(health, { 'healthz is 200': (r) => r.status === 200 });

  const list = http.get(`${BASE_URL}/api/v1/books?limit=10`, params);
  check(list, {
    'list books is 200': (r) => r.status === 200,
    // .json() throws on a null body, which a failed request has — check
    // status first so a down server fails the "is 200" check cleanly
    // instead of throwing out of this callback entirely.
    'list books returns items': (r) => r.status === 200 && (r.json('items') || []).length > 0,
  });

  sleep(1);
}
