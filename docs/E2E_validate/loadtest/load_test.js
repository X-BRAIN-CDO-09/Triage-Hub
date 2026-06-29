import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  scenarios: {
    constant_load: {
      executor: 'constant-arrival-rate',
      rate: 100,             // Duy trì tải 100 RPS theo đúng Test Eval Report
      timeUnit: '1s',
      duration: '10m',       // Chạy trong 10 phút để thu thập chỉ số ổn định
      preAllocatedVUs: 20,   // Số lượng Virtual Users khởi tạo sẵn
      maxVUs: 100,
    },
  },
};

export default function () {
  // 1. Endpoint chuẩn theo tài liệu kỹ thuật (Base path: /v1)
  const url = 'https://dnwglvkmo9.execute-api.us-east-1.amazonaws.com/sandbox/v1/triage';
  
  // 2. Cấu trúc Payload chuẩn hóa theo đúng JSON Schema của Hợp đồng
  const payload = JSON.stringify({
    correlation_id: `corr-k6-load-${__ITER}`, // Tạo ID tuần tự dựa trên lượt lặp của k6
    tenant_id: 'tenant-a',
    incident_id: `inc-k6-${Math.floor(Math.random() * 100000)}`, // Sinh mã sự cố ngẫu nhiên
    environment: 'sandbox',
    received_at: new Date().toISOString(),
    alert: {
      alert_id: 'alert-k6-001',
      source: 'synthetic-pack',
      service: 'checkout-api',
      severity: 'high',
      title: 'High p95 latency on checkout-api via k6 load-test',
      description: 'p95 latency above threshold for 5 minutes detected during load testing',
      started_at: new Date(Date.now() - 5 * 60 * 1000).toISOString(), // Giả lập sự cố xảy ra 5 phút trước
      labels: {
        region: 'us-east-1',
        evidence_uri: 'evidence://tenant-a/inc-k6-load'
      }
    },
    metrics: [],
    logs: [
      {
        service: 'checkout-api',
        ts: new Date().toISOString(),
        level: 'error',
        message: 'database timeout after 3000ms',
        trace_id: 'trace-k6-123',
        curation_reason: 'timeout during alert window'
      }
    ],
    traces: [],
    recent_deploys: [],
    ownership: {
      service: 'checkout-api',
      owner_team: 'payments-platform',
      slack_channel: '#oncall-payments',
      jira_project: 'PAY',
      runbooks: []
    }
  });

  // 3. Cấu hình Headers bắt buộc theo quy ước an toàn hệ thống
  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Tenant-Id': 'tenant-a',                           // Khớp chính xác với tenant_id trong body
      'X-Correlation-Id': `corr-k6-load-${__ITER}`,       // Khớp với mã định danh luồng trace
      'Authorization': 'Bearer k6-testing-token-sandbox'  // Token mô phỏng theo Deployment Contract
    },
  };

  // Tiến hành bắn request kiểm thử tải
  http.post(url, payload, params);
}