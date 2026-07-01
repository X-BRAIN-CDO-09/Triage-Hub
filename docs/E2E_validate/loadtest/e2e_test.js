import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    e2e_scenarios: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 3,
      maxDuration: '30s',
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

  const scenarios = [
    {
      name: 'critical_incident_scenario',
      alertname: 'ServiceDown',
      severity: 'critical',
      summary: 'Checkout-API is down',
      description: 'The service is returning 500 errors across all regions',
      expectedNotification: true,
    },
    {
      name: 'latency_degradation_scenario',
      alertname: 'HighLatency',
      severity: 'high',
      summary: 'Checkout-API latency spike',
      description: 'p99 latency reached 5s, 5x higher than normal',
      expectedNotification: true,
    },
    {
      name: 'false_positive_scenario',
      alertname: 'FlappingAlert',
      severity: 'low',
      summary: 'Service availability fluctuating',
      description: 'This is a noisy flapping false alarm to verify false-positive suppression logic',
      expectedNotification: false,
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
          expected_notification: String(currentScenario.expectedNotification),
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

  console.log(`[E2E] ${currentScenario.name} expected_notification=${currentScenario.expectedNotification} status=${res.status}`);
  console.log(`[E2E] response=${res.body ? res.body.substring(0, 300) : '(empty)'}`);

  check(res, {
    'ingest accepted request': (r) => r.status === 202 || r.status === 200,
    'response has processed status': (r) => {
      try { return JSON.parse(r.body).status === 'Processed' || JSON.parse(r.body).SendMessageResponse; }
      catch { return false; }
    },
  });
}
