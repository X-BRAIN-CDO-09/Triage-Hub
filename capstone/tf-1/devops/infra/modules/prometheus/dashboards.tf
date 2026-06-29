resource "kubernetes_config_map_v1" "grafana_executive_dashboard" {
  metadata {
    name      = "grafana-executive-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "executive.json" = file("${path.module}/dashboards/executive.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map_v1" "grafana_business_dashboard" {
  metadata {
    name      = "grafana-business-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "business.json" = file("${path.module}/dashboards/business.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map_v1" "grafana_application_dashboard" {
  metadata {
    name      = "grafana-application-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "application.json" = file("${path.module}/dashboards/application.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map_v1" "grafana_infrastructure_dashboard" {
  metadata {
    name      = "grafana-infrastructure-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "infrastructure.json" = file("${path.module}/dashboards/infrastructure.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

