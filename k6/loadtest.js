import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Gauge, Rate } from 'k6/metrics';

// Custom metrics to track during load testing
const requestDuration = new Trend('http_req_duration');
const requestRate = new Rate('http_req_rate');
const errorRate = new Rate('http_errors');
const activeVUs = new Gauge('active_vus');

export const options = {
  stages: [
    { duration: '1m', target: 10 },   // Ramp up: 0 → 10 Virtual Users (VUs)
    { duration: '3m', target: 20 },   // Ramp up: 10 → 20 VUs
    { duration: '2m', target: 20 },   // Hold: 20 VUs (steady state load)
    { duration: '1m', target: 0 },    // Ramp down: 20 → 0 VUs
  ],
  thresholds: {
    'http_req_duration': ['p(95)<500'],        // 95% of requests must complete under 500ms
    'http_errors': ['rate<0.1'],               // Error rate must be less than 10%
    'checks': ['rate>0.95'],                   // 95% of assertions must pass
  },
};

export default function () {
  // Track active Virtual Users
  activeVUs.add(1);

  // Target service URL (internal Kubernetes service DNS inside toolbox container network)
  const url = 'http://172.20.0.8:8000/api/quote';

  const response = http.get(url, {
    timeout: '10s',
  });

  // Verify response meets expectations
  const success = check(response, {
    'status is 200': (r) => r.status === 200,
    'has quote field': (r) => r.json('quote') !== undefined,
    'response time < 1s': (r) => r.timings.duration < 1000,
  });

  // Record metrics
  requestRate.add(1);
  if (!success) {
    errorRate.add(1);
  }

  // Simulate think time between requests (random delay up to 2 seconds)
  sleep(Math.random() * 2);

  activeVUs.add(-1);
}
