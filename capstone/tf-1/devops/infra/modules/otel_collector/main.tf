# =============================================================================
# OpenTelemetry Collector — KAN-214 Logging + KAN-215 Metrics
# Mode: DaemonSet (one pod per EKS node)
# Pipelines:
#   logs:    filelog + k8s_events → batch → awscloudwatchlogs
#   metrics: otlp + prometheus → resource + batch → awsemf (CloudWatch EMF)
# =============================================================================

resource "helm_release" "opentelemetry_collector" {
  name             = "opentelemetry-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  namespace        = "kube-system"
  create_namespace = true
  timeout          = 600
  cleanup_on_fail  = true
  force_update     = true
  replace          = true
  wait             = false

  values = [
    <<-EOT
    image:
      repository: otel/opentelemetry-collector-contrib

    mode: daemonset

    # Mount pod log directory from host
    extraVolumes:
      - name: varlogpods
        hostPath:
          path: /var/log/pods
    extraVolumeMounts:
      - name: varlogpods
        mountPath: /var/log/pods
        readOnly: true

    # Expose ports for OTLP receiver and self-metrics
    ports:
      otlp:
        enabled: true
        containerPort: 4317
        servicePort: 4317
        protocol: TCP
      otlp-http:
        enabled: true
        containerPort: 4318
        servicePort: 4318
        protocol: TCP
      metrics:
        enabled: true
        containerPort: 8888
        servicePort: 8888
        protocol: TCP

    # Create a named ClusterIP service so Prometheus can resolve
    # opentelemetry-collector.kube-system:8888 for scraping
    service:
      enabled: true

    clusterRole:
      create: true
      rules:
        - apiGroups: [""]
          resources: ["events", "namespaces", "nodes", "nodes/metrics", "pods", "replicationcontrollers", "resourcequotas", "services", "endpoints"]
          verbs: ["get", "list", "watch"]
        - apiGroups: ["apps"]
          resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
          verbs: ["get", "list", "watch"]
        - apiGroups: ["batch"]
          resources: ["jobs", "cronjobs"]
          verbs: ["get", "list", "watch"]
        - nonResourceURLs: ["/metrics"]
          verbs: ["get"]

    config:
      # ── Receivers ────────────────────────────────────────────────────────────
      receivers:
        # Log collection from container log files
        filelog:
          include:
            - /var/log/pods/*/*/*.log
          exclude:
            - /var/log/pods/kube-system_*/*/*.log
          start_at: beginning
          include_file_path: true
          include_file_name: false
          operators:
            - type: container

        # Kubernetes events as structured logs
        k8s_events:
          auth_type: serviceAccount

        # OTLP receiver for application-instrumented metrics
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318

        # Scrape OTel Collector's own metrics
        prometheus:
          config:
            scrape_configs:
              - job_name: otel-collector-self
                scrape_interval: 60s
                static_configs:
                  - targets: ['localhost:8888']

      # ── Processors ───────────────────────────────────────────────────────────
      processors:
        # Batch for efficiency
        batch: {}

        # Enrich with Kubernetes metadata
        k8sattributes:
          auth_type: "serviceAccount"
          passthrough: false
          extract:
            metadata:
              - k8s.pod.name
              - k8s.namespace.name
              - k8s.deployment.name
              - k8s.statefulset.name
            labels:
              - tag_name: app.label.component
                key: app.kubernetes.io/component
                from: pod

        # Enrich with resource attributes
        resource:
          attributes:
            - action: upsert
              key: environment
              value: "${var.environment}"
            - action: upsert
              key: cloud.region
              value: "${var.aws_region}"
            - action: upsert
              key: cloud.provider
              value: aws

        # Memory limiter to prevent OOM
        memory_limiter:
          check_interval: 5s
          limit_mib: 200
          spike_limit_mib: 50

      # ── Exporters ─────────────────────────────────────────────────────────────
      exporters:
        # Log exporter → CloudWatch Logs
        awscloudwatchlogs:
          log_group_name: "${var.eks_log_group_name}"
          log_stream_name: "otel-collector"
          region: "${var.aws_region}"
          sending_queue:
            enabled: false

        # Traces exporter → AWS X-Ray
        awsxray:
          region: "${var.aws_region}"

        # Metrics exporter → CloudWatch EMF (Embedded Metrics Format)
        awsemf:
          region: "${var.aws_region}"
          namespace: "TriageHub/Metrics"
          log_group_name: "/triage-hub/${var.environment}/metrics"
          log_stream_name: "otel-metrics"
          dimension_rollup_option: "NoDimensionRollup"
          metric_declarations:
            # HTTP application metrics
            - dimensions: [[job, method, status]]
              metric_name_selectors:
                - http_requests_total
                - http_request_duration_seconds
            # OTel Collector internal metrics
            - dimensions: [[service_name]]
              metric_name_selectors:
                - otelcol_.*

      # ── Service / Pipelines ──────────────────────────────────────────────────
      service:
        pipelines:
          # Log pipeline: container logs + K8s events → CloudWatch Logs
          logs:
            receivers: [filelog, k8s_events]
            processors: [memory_limiter, k8sattributes, batch]
            exporters: [awscloudwatchlogs]

          # Metrics pipeline: OTLP from apps + self-scrape → CloudWatch EMF
          metrics:
            receivers: [otlp, prometheus]
            processors: [memory_limiter, k8sattributes, resource, batch]
            exporters: [awsemf]

          # Traces pipeline: OTLP traces → AWS X-Ray
          traces:
            receivers: [otlp]
            processors: [memory_limiter, k8sattributes, resource, batch]
            exporters: [awsxray]
    EOT
  ]
}
