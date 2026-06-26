#!/bin/bash
# Wait for internet connectivity
sleep 10
apt-get update -y
apt-get install -y curl unzip

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

# Install Argo Rollouts CLI plugin
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ./kubectl-argo-rollouts-linux-amd64
mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# Export PATH to ensure /usr/local/bin is available
export PATH=$PATH:/usr/local/bin

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
      receiver: 'triage-hub-webhook'
      routes:
      - match:
          alertname: Watchdog
        receiver: 'null'
      - receiver: 'triage-hub-webhook'
    receivers:
    - name: 'null'
    - name: 'triage-hub-webhook'
      webhook_configs:
      - url: '${api_gateway_url}'
        send_resolved: true
        http_config:
          headers:
            x-api-key: '${api_key}'
            X-Tenant-Id: '${tenant_id}'
INNER_EOF

# 9. Cài đặt Prometheus + Grafana kèm cấu hình Webhook Alertmanager
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f /tmp/alertmanager-config-values.yaml

# 10. Cài đặt Loki + Promtail
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true,loki.isDefault=false,loki.persistence.enabled=true,loki.persistence.size=10Gi

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
      annotations:
        summary: "Cart service is down"
        description: "The cartservice has 0 available replicas. Customers cannot access their shopping carts."
    - alert: PodCpuUsageHigh
      expr: sum(rate(container_cpu_usage_seconds_total{pod="cpu-stress-noisy"}[1m])) * 100 > 80
      for: 30s
      labels:
        severity: warning
        tenant_id: '${tenant_id}'
      annotations:
        summary: "CPU usage high on noisy pod"
        description: "The cpu-stress-noisy pod is consuming more than 80% CPU."
INNER_EOF

# Đợi Prometheus CRD sẵn sàng rồi mới apply Rule
until kubectl get crd prometheusrules.monitoring.coreos.com; do
  sleep 5
done
kubectl apply -f /tmp/prometheus-rules.yaml

# Expose Frontend trên cổng 80 của EC2
kubectl patch svc frontend -n default -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 80}]}}'

# Đợi Grafana service xuất hiện rồi mới patch sang NodePort cổng 3000 của EC2
until kubectl get svc prometheus-grafana -n monitoring; do
  sleep 5
done
kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 3000}]}}'
