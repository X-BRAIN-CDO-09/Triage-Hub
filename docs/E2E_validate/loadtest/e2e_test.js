import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    constant_load: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1s',
      duration: '3s',
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
  const url = 'https://4u3u2yzfvi.execute-api.us-east-1.amazonaws.com/sandbox/alerts';

  const scenarios = [
    {
      name: 'Critical Incident',
      alertname: 'ServiceDown',
      severity: 'critical',
      summary: 'Checkout-API is down',
      description: 'The service is returning 500 errors across all regions'
    },
    {
      name: 'Latency Degradation',
      alertname: 'HighLatency',
      severity: 'warning',
      summary: 'Checkout-API latency spike',
      description: 'p99 latency reached 5s, 5x higher than normal'
    },
    {
      name: 'False Positive',
      alertname: 'FlappingAlert',
      severity: 'info',
      summary: 'Service availability fluctuating',
      description: 'This is a test alert to verify the filtering/false-positive suppression logic'
    }
  ];

  const currentScenario = scenarios[__ITER % scenarios.length];
  
  // Prometheus Alertmanager webhook format
  // Lambda extractAlerts() đọc payload.alerts[]
  const payload = JSON.stringify({
    version: '4',
    groupKey: `k6-group-${__ITER}`,
    status: 'firing',
    receiver: 'triage-hub',
    groupLabels: {
      alertname: currentScenario.alertname,
    },
    commonLabels: {
      alertname: currentScenario.alertname,
      tenant_id: 'tenant-a',        // phải tồn tại trong DynamoDB
      environment: 'sandbox',
      severity: currentScenario.severity,
      service: 'checkout-api',
    },
    commonAnnotations: {
      summary: currentScenario.summary,
      description: currentScenario.description,
    },
    alerts: [
      {
        status: 'firing',
        labels: {
          alertname: currentScenario.alertname,
          tenant_id: 'tenant-a',
          environment: 'sandbox',
          severity: currentScenario.severity,
          service: 'checkout-api',
          region: 'us-east-1',
        },
        annotations: {
          summary: currentScenario.summary,
          description: currentScenario.description,
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
