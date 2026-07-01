#!/bin/bash
# Wait for internet connectivity
sleep 10
apt-get update -y
apt-get install -y curl

# 1. Install K3s (BẺ KHÓA dải cổng sang 80-40000 và cấp quyền đọc config)
export K3S_KUBECONFIG_MODE="644"
curl -sfL https://get.k3s.io | sh -s - --disable traefik --kube-apiserver-arg="service-node-port-range=80-40000"

# Wait for K3s/kubectl to be fully up
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes; do
  sleep 5
done

# Sao chép kubeconfig cho ubuntu user để gõ kubectl không cần sudo/export
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# 2. Fix CoreDNS loops/upstream DNS forwarder (đợi configmap xuất hiện rồi mới patch)
until kubectl get configmap coredns -n kube-system; do
  sleep 5
done
kubectl get configmap coredns -n kube-system -o yaml | sed 's/forward \. \/etc\/resolv\.conf/forward . 1.1.1.1 8.8.8.8/g' | kubectl apply -f -
kubectl rollout restart deployment coredns -n kube-system

# 5. Cài đặt Helm tự động
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 6. Triển khai Online Boutique & Patch giới hạn RAM của cartservice
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml
until kubectl get deployment cartservice; do
  sleep 5
done
kubectl patch deployment cartservice -p '{"spec":{"template":{"spec":{"containers":[{"name":"server","resources":{"requests":{"cpu":"200m","memory":"256Mi"},"limits":{"cpu":"300m","memory":"512Mi"}}}]}}}}'

# 7. Cấu hình Helm Repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 8. Tạo file cấu hình Alertmanager Webhook tại EC2
cat <<'INNER_EOF' > /tmp/alertmanager-config-values.yaml
alertmanager:
  config:
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'null'
      routes:
      - match_re:
          alertname: CartServiceDown|FrontendLatencyHigh|CpuSpikeNoise
        receiver: 'triage-hub-webhook'
    receivers:
    - name: 'null'
    - name: 'triage-hub-webhook'
      webhook_configs:
      - url: '${api_gateway_url}'
        send_resolved: true
        http_config:
          http_headers:
            x-api-key:
              values:
              - '${api_key}'
            X-Tenant-Id:
              values:
              - '${tenant_id}'
INNER_EOF

# 9. Cài đặt Prometheus + Grafana kèm cấu hình Webhook Alertmanager
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f /tmp/alertmanager-config-values.yaml

# 10. Cài đặt Loki + Promtail
cat <<'INNER_EOF' > /tmp/loki-values.yaml
loki:
  persistence:
    enabled: true
    size: 10Gi
  isDefault: false
promtail:
  enabled: true
  pipelineStages:
    - cri: {}
    - json:
        expressions:
          took_ms: '"http.resp.took_ms"'
          message: message
    - template:
        source: is_request_complete
        template: '{{ if and (eq .message "request complete") .took_ms }}true{{ else }}false{{ end }}'
    - template:
        source: took_seconds
        template: '{{ if eq .is_request_complete "true" }}{{ mul (atof .took_ms) 0.001 }}{{ end }}'
    - metrics:
        grpc_server_handling_seconds:
          type: Histogram
          description: "Frontend response duration in seconds"
          source: took_seconds
          buckets: [0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0]
  config:
    snippets:
      extraRelabelConfigs:
        - action: replace
          source_labels: [__meta_kubernetes_pod_label_app]
          target_label: service
        - action: replace
          source_labels: [__meta_kubernetes_pod_label_run]
          target_label: service
          regex: (.+)
        - target_label: tenant_id
          replacement: "${tenant_id}"
        - target_label: environment
          replacement: "sandbox"
INNER_EOF

helm install loki grafana/loki-stack \
  --namespace monitoring \
  -f /tmp/loki-values.yaml

# 10.1 Tạo cấu hình PodMonitor cho Promtail
cat <<'INNER_EOF' > /tmp/promtail-podmonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: promtail-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: promtail
  podMetricsEndpoints:
  - port: http-metrics
    interval: 15s
INNER_EOF


# 11. Tạo cấu hình Prometheus Rule tại EC2 và apply
cat <<'INNER_EOF' > /tmp/prometheus-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: online-boutique-rules
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
  - name: online-boutique-alerts
    rules:
    - alert: CartServiceDown
      expr: kube_deployment_status_replicas_available{deployment="cartservice"} == 0
      for: 30s
      labels:
        severity: critical
        tenant_id: '${tenant_id}'
        service: 'cartservice'
      annotations:
        summary: "Cart service is down"
        description: "The cartservice has 0 available replicas. Customers cannot access their shopping carts."
    - alert: FrontendLatencyHigh
      expr: histogram_quantile(0.95, sum(rate(promtail_custom_grpc_server_handling_seconds_bucket[2m])) by (le)) > 2
      for: 30s
      labels:
        severity: warning
        tenant_id: '${tenant_id}'
        service: 'frontend'
      annotations:
        summary: "High latency on frontend service"
        description: "The 95th percentile request latency is above 2s for 30s."
    - alert: CpuSpikeNoise
      expr: sum(rate(container_cpu_usage_seconds_total{pod="cpu-stress-noisy"}[1m])) * 100 > 90
      for: 1s
      labels:
        severity: warning
        tenant_id: '${tenant_id}'
        service: 'customer-service'
      annotations:
        summary: "CPU spike noise"
        description: "Transient CPU spike detected on cpu-stress-noisy pod."
    - record: aiops_scenario_metric_value
      expr: kube_deployment_status_replicas_available{deployment="cartservice"}
      labels:
        metric_name: availability
        tenant_id: '${tenant_id}'
        environment: 'sandbox'
        service: 'cartservice'
    - record: aiops_scenario_metric_value
      expr: histogram_quantile(0.95, sum(rate(promtail_custom_grpc_server_handling_seconds_bucket[2m])) by (le)) * 1000
      labels:
        metric_name: latency
        tenant_id: '${tenant_id}'
        environment: 'sandbox'
        service: 'frontend'
    - record: aiops_scenario_metric_value
      expr: sum(rate(container_cpu_usage_seconds_total{pod="cpu-stress-noisy"}[1m])) * 100
      labels:
        metric_name: cpu_usage
        tenant_id: '${tenant_id}'
        environment: 'sandbox'
        service: 'customer-service'
INNER_EOF


# Đợi Prometheus CRD sẵn sàng rồi mới apply Rule & PodMonitor
until kubectl get crd prometheusrules.monitoring.coreos.com && kubectl get crd podmonitors.monitoring.coreos.com; do
  sleep 5
done
kubectl apply -f /tmp/prometheus-rules.yaml
kubectl apply -f /tmp/promtail-podmonitor.yaml

# Expose Frontend trên cổng 80 của EC2
kubectl patch svc frontend -n default -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 80}]}}'

# Đợi Grafana service xuất hiện rồi mới patch sang NodePort cổng 3000 của EC2
until kubectl get svc prometheus-grafana -n monitoring; do
  sleep 5
done
kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 3000}]}}'

# 12. Triển khai Jaeger All-in-One
cat <<'INNER_EOF' > /tmp/jaeger-all-in-one.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.57
        env:
        - name: QUERY_BASE_PATH
          value: /jaeger
        ports:
        - containerPort: 16686
        - containerPort: 4317
        - containerPort: 4318
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-query
  namespace: monitoring
spec:
  ports:
  - name: query
    port: 16686
    targetPort: 16686
  selector:
    app: jaeger
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-collector
  namespace: monitoring
spec:
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
  selector:
    app: jaeger
---
apiVersion: v1
kind: Service
metadata:
  name: otelcol
  namespace: default
spec:
  type: ExternalName
  externalName: jaeger-collector.monitoring.svc.cluster.local
INNER_EOF

kubectl apply -f /tmp/jaeger-all-in-one.yaml

# 13. Patch Services thành NodePorts để Nginx trỏ tới
until kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring; do
  sleep 5
done
kubectl patch svc prometheus-kube-prometheus-prometheus -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"name": "http-web", "port": 9090, "nodePort": 9090}]}}'

until kubectl get svc loki -n monitoring; do
  sleep 5
done
kubectl patch svc loki -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 3100, "nodePort": 3100}]}}'

until kubectl get svc jaeger-query -n monitoring; do
  sleep 5
done
kubectl patch svc jaeger-query -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"name": "query", "port": 16686, "nodePort": 16686}]}}'

# 14. Cài đặt Nginx làm proxy gộp cổng
apt-get install -y nginx
cat <<'INNER_EOF' > /etc/nginx/sites-available/monitoring-proxy
server {
    listen 9000;

    location /loki/ {
        proxy_pass http://127.0.0.1:3100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /jaeger/ {
        proxy_pass http://127.0.0.1:16686;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
INNER_EOF

ln -s /etc/nginx/sites-available/monitoring-proxy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

