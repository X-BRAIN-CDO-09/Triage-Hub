# =============================================================================
# Prometheus Module ΓÇö KAN-215 Platform Metrics Collection
# Deploy kube-prometheus-stack via Helm:
#   - Prometheus (StatefulSet + EBS persistent storage)
#   - node-exporter (CPU, Memory, Disk, Network per node)
#   - kube-state-metrics (Deployment, Pod state)
#   - Alertmanager (with custom alert rules)
# =============================================================================

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  timeout          = 600
  cleanup_on_fail  = true
  force_update     = true
  wait             = false

  values = [
    <<-EOT
    # ΓöÇΓöÇ Global ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    fullnameOverride: prometheus

    # ΓöÇΓöÇ Grafana: Dashboarding and Reporting ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    grafana:
      enabled: true
      adminPassword: admin
      sidecar:
        dashboards:
          enabled: true
          label: grafana_dashboard
          labelValue: "1"
          searchNamespace: ALL
      imageRenderer:
        enabled: true
      grafana.ini:
        rendering:
          server_url: http://prometheus-grafana-image-renderer.monitoring.svc:8081/render
          callback_url: http://prometheus-grafana.monitoring.svc:80/

    # ΓöÇΓöÇ Alertmanager ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    alertmanager:
      enabled: true
      alertmanagerSpec:
        secrets:
          - slack-webhook
      config:
        global:
          resolve_timeout: 5m
          slack_api_url_file: '/etc/alertmanager/secrets/slack-webhook/url'
        route:
          group_by: ['alertname', 'job']
          group_wait: 30s
          group_interval: 5m
          repeat_interval: 12h
          receiver: 'default-receiver'
          routes:
            - receiver: 'null'
              matchers:
                - alertname=~"Watchdog|InfoInhibitor"
        receivers:
          - name: 'null'
          - name: 'default-receiver'
            webhook_configs:
              - url: '${var.alertmanager_webhook_url != "" ? var.alertmanager_webhook_url : "http://localhost"}'
                send_resolved: true
            slack_configs:
              - send_resolved: true
                channel: '#alerts'
                title: '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }} {{ if eq .Status "firing" }}≡ƒöÑ{{ else }}Γ£à{{ end }}'
                text: >-
                  {{ range .Alerts -}}
                  *Alert:* {{ .Labels.alertname }}{{ if .Labels.severity }} - `{{ .Labels.severity }}`{{ end }}
                  *Description:* {{ .Annotations.description }}
                  *Details:*
                    {{ range .Labels.SortedPairs }} ΓÇó *{{ .Name }}:* `{{ .Value }}`
                    {{ end }}
                  {{ end }}
            sns_configs:
              - topic_arn: '${var.alertmanager_sns_topic_arn}'
                send_resolved: true

    # ΓöÇΓöÇ Prometheus ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    prometheus:
      prometheusSpec:
        # Retention & storage
        retention: ${var.prometheus_retention}

        # Use emptyDir for sandbox (no EBS CSI driver required)
        storageSpec:
          emptyDir:
            medium: ""

        # Scrape all ServiceMonitors/PodMonitors across all namespaces
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
        ruleSelectorNilUsesHelmValues: false

        # Additional scrape configs for Kubernetes service discovery
        additionalScrapeConfigs:
          # 1. Scrape pod annotations (prometheus.io/scrape=true)
          - job_name: kubernetes-pods
            kubernetes_sd_configs:
              - role: pod
            relabel_configs:
              - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
                action: keep
                regex: "true"
              - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
                action: replace
                target_label: __metrics_path__
                regex: (.+)
              - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
                action: replace
                regex: ([^:]+)(?::\d+)?;(\d+)
                replacement: $$1:$$2
                target_label: __address__
              - source_labels: [__meta_kubernetes_namespace]
                target_label: namespace
              - source_labels: [__meta_kubernetes_pod_name]
                target_label: pod
              - source_labels: [__meta_kubernetes_pod_label_app]
                target_label: app

          # 2. Scrape OTel Collector metrics endpoint
          - job_name: otel-collector
            static_configs:
              - targets: ['opentelemetry-collector.kube-system:8888']

    # ΓöÇΓöÇ Recording Rules & Alerts ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    additionalPrometheusRulesMap:
      recording-rules:
        groups:
          - name: triage_hub.recording_rules
            interval: 60s
            rules:
              # HTTP request rate
              - record: job:http_requests_total:rate5m
                expr: sum(rate(http_requests_total[5m])) by (job)

              # HTTP error rate (5xx)
              - record: job:http_errors_total:rate5m
                expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)

              # HTTP p99 response time
              - record: job:http_request_duration_seconds:p99
                expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))

              # HTTP p95 response time
              - record: job:http_request_duration_seconds:p95
                expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))

              # Node CPU usage %
              - record: instance:node_cpu_utilization:rate5m
                expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

              # Node Memory usage %
              - record: instance:node_memory_utilization:ratio
                expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

              # Availability SLO
              - record: slo:availability:ratio
                expr: sum(rate(http_requests_total{status!~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

              # Latency SLO
              - record: slo:latency:ratio
                expr: sum(rate(http_request_duration_seconds_bucket{le="2.0"}[5m])) / sum(rate(http_request_duration_seconds_count[5m]))

      alert-rules:
        groups:
          - name: triage_hub.alert_rules
            rules:
              # High CPU
              - alert: HighNodeCPUUsage
                expr: instance:node_cpu_utilization:rate5m > 80
                for: 5m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "High CPU usage on {{ $labels.instance }}"
                  description: "CPU usage is {{ $value | printf \"%.1f\" }}% on {{ $labels.instance }} for 5 minutes."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # High Memory
              - alert: HighNodeMemoryUsage
                expr: instance:node_memory_utilization:ratio > 0.8
                for: 5m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "High memory usage on {{ $labels.instance }}"
                  description: "Memory usage is {{ $value | humanizePercentage }} on {{ $labels.instance }}."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # High Disk Usage
              - alert: HighNodeDiskUsage
                expr: 1 - (node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"}) > 0.9
                for: 5m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "High disk usage on {{ $labels.instance }}"
                  description: "Disk usage is {{ $value | humanizePercentage }} on {{ $labels.instance }}."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # Pod CrashLoopBackOff
              - alert: PodCrashLoopBackOff
                expr: kube_pod_container_status_restarts_total > 3
                for: 15m
                labels:
                  severity: critical
                  environment: ${var.environment}
                annotations:
                  summary: "Pod {{ $labels.pod }} is crash looping"
                  description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has restarted {{ $value }} times."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # High HTTP Error Rate
              - alert: HighHTTPErrorRate
                expr: job:http_errors_total:rate5m / job:http_requests_total:rate5m > 0.05
                for: 5m
                labels:
                  severity: critical
                  environment: ${var.environment}
                annotations:
                  summary: "High HTTP error rate for {{ $labels.job }}"
                  description: "Error rate is {{ $value | humanizePercentage }} for {{ $labels.job }}."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # High P99 Latency
              - alert: HighP99Latency
                expr: job:http_request_duration_seconds:p99 > 2
                for: 5m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "High P99 latency for {{ $labels.job }}"
                  description: "P99 latency is {{ $value | printf \"%.2f\" }}s for {{ $labels.job }}."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # Pod Not Ready
              - alert: PodNotReady
                expr: kube_pod_status_ready{condition="true"} == 0
                for: 10m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "Pod {{ $labels.pod }} not ready"
                  description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been not ready for 10 minutes."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # Service Down
              - alert: InstanceDown
                expr: up == 0
                for: 5m
                labels:
                  severity: critical
                  environment: ${var.environment}
                annotations:
                  summary: "Instance {{ $labels.instance }} down"
                  description: "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # Queue Backlog
              - alert: QueueBacklog
                expr: aws_sqs_approximate_number_of_messages_visible > 1000
                for: 5m
                labels:
                  severity: warning
                  environment: ${var.environment}
                annotations:
                  summary: "High Queue Backlog"
                  description: "Queue backlog is {{ $value }}."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"

              # Failed Jobs
              - alert: FailedJobs
                expr: kube_job_failed > 0
                for: 1m
                labels:
                  severity: critical
                  environment: ${var.environment}
                annotations:
                  summary: "Job failed"
                  description: "Job {{ $labels.job_name }} in namespace {{ $labels.namespace }} failed."
                  runbook_url: "https://github.com/org/triage-hub/wiki/runbooks#{{ $labels.alertname }}"


    # ΓöÇΓöÇ node-exporter: Infrastructure metrics ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodeExporter:
      enabled: true

    # ΓöÇΓöÇ kube-state-metrics: Kubernetes object metrics ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    kube-state-metrics:
      enabled: true

    # ΓöÇΓöÇ Prometheus Operator ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    prometheusOperator:
      enabled: true
    EOT
  ]
}
# =============================================================================
# SNS Topic ΓÇö alert notifications via email subscription
# =============================================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts-${var.environment}"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alertmanager_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alertmanager_notification_email
}

resource "kubernetes_secret" "slack_webhook" {
  metadata {
    name      = "slack-webhook"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    url = var.slack_webhook_url
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.monitoring]
}
