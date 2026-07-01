import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    constant_load: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1s',
      duration: '2s',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },

  thresholds: {
    // Lambda trả 202 Accepted — latency của Lambda + SQS publish
    'http_req_duration{expected_response:true}': ['p(99)<2000'],
    'http_req_failed': ['rate<0.01'],
  },
};

export default function () {
  const url = 'https://8d1j9a80b7.execute-api.us-east-1.amazonaws.com/sandbox/alerts';

  // Prometheus Alertmanager webhook format
  // Lambda extractAlerts() đọc payload.alerts[]
  const payload = JSON.stringify({
    version: '4',
    groupKey: `k6-group-${__ITER}`,
    status: 'firing',
    receiver: 'triage-hub',
    groupLabels: {
      alertname: 'HighLatency',
    },
    commonLabels: {
      alertname: 'HighLatency',
      tenant_id: 'tenant-b',        // phải tồn tại trong DynamoDB
      environment: 'sandbox',
      severity: 'high',
      service: 'checkout-api',
    },
    commonAnnotations: {
      summary: 'High p95 latency on checkout-api',
      description: 'p95 latency above threshold for 5 minutes',
    },
    alerts: [
      {
        status: 'firing',
        labels: {
          alertname: 'HighLatency',
          tenant_id: 'tenant-b',
          environment: 'sandbox',
          severity: 'high',
          service: 'checkout-api',
          region: 'us-east-1',
        },
        annotations: {
          summary: 'High p95 latency on checkout-api',
          description: 'p95 latency above threshold during load test',
        },
        startsAt: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
        endsAt: '0001-01-01T00:00:00Z',
        fingerprint: `k6-fp-${__ITER}`,
      },
    ],
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Tenant-Id': 'tenant-a',
      'x-api-key': __ENV.API_KEY || '',
    },
  };

  const res = http.post(url, payload, params);

  // Debug iteration đầu tiên
  if (__ITER === 0) {
    console.log(`[DEBUG] status=${res.status}`);
    console.log(`[DEBUG] body=${res.body ? res.body.substring(0, 300) : '(empty)'}`);
  }

}
