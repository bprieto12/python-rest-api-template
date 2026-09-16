// Mixed read/write load test — the main performance test for this service.
// Staged ramp-up/hold/ramp-down, mostly list/get reads with a smaller
// fraction of full create -> patch -> delete write cycles.
//
// IMPORTANT — DynamoDB capacity: both tables run PROVISIONED at 5 read /
// 5 write capacity units, not on-demand (see terraform/dynamodb.tf's
// comment for why: it's what keeps this on the perpetual free tier). The
// defaults below are deliberately conservative to stay under that ceiling.
// Cranking VUS/HOLD_DURATION up without also raising the tables' capacity
// (or switching billing_mode to PAY_PER_REQUEST) first won't produce a
// meaningful result — it'll just trip the dynamodb_throttles CloudWatch
// alarms and page whoever's subscribed. Read performance/README.md before running
// anything heavier than the defaults, especially against production.
//
// Every book this script creates, it also deletes in the same iteration —
// see the "write cycle" group below. The only way one survives is the run
// getting killed mid-iteration; those are tagged genre=load-test
// specifically so they're easy to find and clean up afterward (see
// performance/README.md).
//
// Usage:
//   BASE_URL=https://staging.books-api.example.com \
//   COGNITO_CLIENT_ID=... COGNITO_CLIENT_SECRET=... COGNITO_DOMAIN=... \
//     k6 run performance/load.js
//
//   Override the load shape (stay mindful of the capacity note above):
//     VUS=10 RAMP_DURATION=1m HOLD_DURATION=3m k6 run performance/load.js
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { getAuthHeaders } from './lib/auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
const VUS = Number(__ENV.VUS || 5);
const RAMP_DURATION = __ENV.RAMP_DURATION || '30s';
const HOLD_DURATION = __ENV.HOLD_DURATION || '1m';
// Fraction of iterations that do a full write cycle instead of just
// reading — kept low since writes are what actually consume DynamoDB write
// capacity (reads share a much larger effective budget at this data size).
const WRITE_FRACTION = Number(__ENV.WRITE_FRACTION || 0.2);

const writeErrors = new Rate('write_errors');

export const options = {
  stages: [
    { duration: RAMP_DURATION, target: VUS },
    { duration: HOLD_DURATION, target: VUS },
    { duration: RAMP_DURATION, target: 0 },
  ],
  thresholds: {
    // Mirrors terraform/alarms.tf's own SLOs (gateway_5xx / gateway_latency_p99)
    // on purpose — a k6 failure here means "the same thing production
    // alerting would page on," not an arbitrary separate bar.
    http_req_failed: ['rate<0.01'],
    'http_req_duration{expected_response:true}': ['p(99)<3000'],
    write_errors: ['rate<0.05'],
  },
};

export function setup() {
  return { headers: getAuthHeaders() };
}

function randomIsbn() {
  // Not a real, checksum-valid ISBN — just a unique digit string, which is
  // all BookCreate.isbn actually validates (length 10-20, see schemas.py).
  return `979${Date.now()}${__VU}`.slice(0, 13);
}

export default function (data) {
  const params = { headers: data.headers };

  group('read path', function () {
    const list = http.get(`${BASE_URL}/api/v1/books?limit=20`, params);
    const listOk = check(list, { 'list is 200': (r) => r.status === 200 });

    // .json() throws on a null/non-JSON body — a failed request (timeout,
    // 5xx, connection error) has one, and a load test failing an
    // individual iteration shouldn't skip the rest of this function
    // (notably sleep() below) just because one request came back bad.
    const items = listOk ? list.json('items') || [] : [];
    if (items.length > 0) {
      const pick = items[Math.floor(Math.random() * items.length)];
      const single = http.get(`${BASE_URL}/api/v1/books/${pick.id}`, params);
      check(single, { 'get by id is 200': (r) => r.status === 200 });
    }
  });

  if (Math.random() < WRITE_FRACTION) {
    group('write cycle', function () {
      const jsonParams = { headers: { ...data.headers, 'Content-Type': 'application/json' } };
      const payload = JSON.stringify({
        title: `k6 load test book ${__VU}-${__ITER}`,
        author: 'k6',
        isbn: randomIsbn(),
        genre: 'load-test',
        price: 9.99,
        in_stock: 1,
      });

      const created = http.post(`${BASE_URL}/api/v1/books`, payload, jsonParams);
      const createOk = check(created, { 'create is 201': (r) => r.status === 201 });
      writeErrors.add(!createOk);
      if (!createOk) {
        return;
      }
      const id = created.json('id');

      const patched = http.patch(
        `${BASE_URL}/api/v1/books/${id}`,
        JSON.stringify({ price: 19.99 }),
        jsonParams
      );
      writeErrors.add(!check(patched, { 'patch is 200': (r) => r.status === 200 }));

      const deleted = http.del(`${BASE_URL}/api/v1/books/${id}`, null, params);
      writeErrors.add(!check(deleted, { 'delete is 204': (r) => r.status === 204 }));
    });
  }

  sleep(1);
}
