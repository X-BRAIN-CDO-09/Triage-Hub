output "helm_release_name" {
  value       = helm_release.opentelemetry_collector.name
  description = "The name of the OTel Collector Helm release"
}
