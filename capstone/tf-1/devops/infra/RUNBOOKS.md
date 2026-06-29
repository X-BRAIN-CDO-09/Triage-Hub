# Operational Runbooks - Triage Hub Platform

## 1. Monitoring & Observability Stack

### Overview
Triage Hub relies on a comprehensive observability stack based on Prometheus, Grafana, OpenTelemetry Collector, and AlertManager deployed on Amazon EKS.

### Components
- **Prometheus Operator**: Manages Prometheus and AlertManager instances.
- **Prometheus**: Scrapes metrics from `ServiceMonitors` and standard node exporters.
- **Grafana**: Visualizes metrics through pre-configured dashboards (Executive, Business, Application).
- **AlertManager**: Routes alerts to specific channels (e.g., Slack) based on routing rules.
- **OpenTelemetry Collector**: Receives traces (X-Ray), metrics, and logs from Triage Hub applications and exports them to AWS X-Ray and CloudWatch.

## 2. Alert Rules and Remediation

### Infrastructure Alerts

#### Alert: `HighCpuLoad`
- **Condition**: Node CPU usage > 80% for 5 minutes.
- **Impact**: Application latency or node failure.
- **Remediation**:
  1. Check what pods are consuming high CPU: `kubectl top pods -A`
  2. If applications are spiking, check HPA status: `kubectl get hpa -A`
  3. If node is simply underprovisioned, consider scaling the EKS node group.

#### Alert: `HighMemoryUsage`
- **Condition**: Node Memory usage > 80% for 5 minutes.
- **Impact**: Pods might be OOMKilled.
- **Remediation**:
  1. Identify memory-heavy pods: `kubectl top pods -A --sort-by=memory`
  2. Inspect specific pods for memory leaks.
  3. Check node capacity and consider scaling up if necessary.

#### Alert: `DiskSpaceRunningOut`
- **Condition**: Available disk space < 10% for 5 minutes.
- **Impact**: Applications unable to write logs/data, node becomes unstable.
- **Remediation**:
  1. Identify the node.
  2. Clear old container images: `crictl rmi --prune`
  3. Rotate logs or increase EBS volume size.

### Application Alerts

#### Alert: `HighErrorRate`
- **Condition**: HTTP Error Rate (5xx) > 5% for 5 minutes.
- **Impact**: Users experiencing frequent failures.
- **Remediation**:
  1. Check application logs via CloudWatch or Grafana.
  2. Trace recent requests in AWS X-Ray to identify the failing component (e.g., `jira-dispatcher`).
  3. Look for downstream dependency issues (e.g., Jira API limits).

#### Alert: `HighP99Latency`
- **Condition**: P99 response time > 2 seconds for 5 minutes.
- **Impact**: Degraded user experience.
- **Remediation**:
  1. Check AWS X-Ray for slow operations (e.g., database queries or external API calls).
  2. Ensure DynamoDB provisioned capacity isn't throttling.

#### Alert: `InstanceDown` / `PodNotReady`
- **Condition**: Service is down or Pod is not ready for 5/10 minutes.
- **Impact**: Partial or full outage of a service.
- **Remediation**:
  1. Describe the pod: `kubectl describe pod <pod-name> -n <namespace>`
  2. Check pod logs for crash loop reasons.
  3. Verify liveness/readiness probe configurations.

## 3. Incident Response Workflow

1. **Acknowledge**: Respond to the Slack alert indicating you are investigating.
2. **Triage**: 
   - Open the **Triage Hub Executive/Application Dashboard** in Grafana.
   - Check AWS X-Ray traces for the affected timeframe.
3. **Mitigate**: Apply temporary fixes (e.g., restarting pods, scaling nodes, rolling back a deployment).
4. **Resolve**: Implement the permanent fix.
5. **Post-Mortem**: Document the incident, root cause, and preventative measures.

## 4. Maintenance Commands

### Restarting Monitoring Stack
```bash
kubectl rollout restart deployment prometheus-grafana -n monitoring
kubectl rollout restart statefulset prometheus-prometheus -n monitoring
kubectl rollout restart statefulset alertmanager-prometheus-alertmanager -n monitoring
```

### Checking Logs
```bash
# AlertManager
kubectl logs -l app.kubernetes.io/name=alertmanager -n monitoring

# OpenTelemetry Collector
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n monitoring
```
