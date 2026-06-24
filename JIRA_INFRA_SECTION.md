---

> **Owner:** CDO-09 (Jira Integration Layer)

## Jira Integration Layer

### Architecture

![Jira Integration Architecture](../assets/Jira-Integration.drawio.png)

The architecture enforces **Jira-First** ordering. The AI Engine sends a diagnosis payload via API Gateway → EventBridge. The `jira-dispatcher` consumes the event, looks up the AI-recommended `account_id` from DynamoDB, creates the Jira ticket, and **only on success** emits a `slack.notify` event. The `slack-dispatcher` never touches Jira. On Jira failure, the payload goes to SQS DLQ and a `slack.fallback` event fires a raw text alert.

### Sequence flow

![Jira Flow Sequence](..docs/assets/Jira_flow.jpeg)

---

### Component table

| Component | AWS Service | Rationale | Cost estimate |
|---|---|---|---|
| Compute | `jira-dispatcher` Lambda | Event-driven, pay-per-use, zero idle cost. Single-purpose function with <30s runtime. No need for long-running containers. | Free Tier up to 1M req/month. ~$0.50/month at 10k alerts. |
| Database | DynamoDB | Key-value lookup by `tenant_id#email`. No joins, single-digit ms reads. Managed, auto-scaling. | On-demand. ~$0.25/GB-month. ~5KB per mapping × 50 tenants × 50 users = negligible. |
| Event Bus | EventBridge | Native Lambda target, 24h retry window, schema registry, event filtering. Decouples dispatchers without custom middleware. | $1.00/million events. 2 events per alert (ingest + notify). |
| Queue | SQS (DLQ) | Dead-letter queue for poisoned alerts. Max 14-day retention, redrive to Lambda for replay. | $0.40/million requests. Receives <1% of traffic. |
| Security | Secrets Manager | Auto-rotation every 30 days. Fine-grained IAM scoped to Lambda read access only. Encrypted at rest via KMS. | $0.40/secret/month + $0.05/10k API calls. One secret for Jira API token. |

---

### Design rationale

#### Why Jira-First

Two competing patterns were rejected:

**Slack-First Chained Dependency** — The `slack-dispatcher` creates the Jira ticket as a side effect after posting to Slack. This couples notification to ticketing: if Slack is slow, Jira creation stalls. If the engineer acknowledges before Jira exists, the audit trail breaks. A Slack API failure causes the entire incident to go unrecorded.

**Blind Auto-Assignment** — The AI-recommended owner is assigned immediately without human confirmation. If the AI is wrong (deactivated user, wrong team, cross-tenant mapping), tickets languish in the wrong queue, inflating MTTA.

Jira-First treats the Jira ticket as the **single source of truth**. The ticket must exist before any notification is sent. The `issue_key` flows through every subsequent event, creating an immutable chain: alert → ticket → notification → acknowledgement.

#### Comparison with alternatives

| Axis | Jira-First | Slack-First | Blind Auto-Assign |
|---|---|---|---|
| Time to Route (MTTA) | ~45s (create 2s + post 1s + accept ~42s) | ~90s (post 1s + read 60s + create 2s + reassign) | ~30s but ~25% wrong → effective MTTA doubles |
| Wrong Assignment Rate | <3% (AI recommends, human verifies, assigns after accept) | ~3% + ~10% if human acknowledges before Jira exists | ~25% (AI model accuracy ceiling for team-owner prediction) |
| Silent Data Drop Rate | <0.1% (DLQ captures every failure; fallback Slack notifies) | ~8% (Slack delivered, Jira never created, no permanent record) | ~25% (ticket created, assigned wrong, sits stale) |

*Numbers are estimated baselines for capscope, to be validated during W12 eval.*

#### Accepted weakness

**Stale DynamoDB mapping.** The background sync runs every 5 minutes. If a new engineer joins before the sync runs, the `jira-dispatcher` cannot resolve their email to a Jira `account_id`.

- Ticket is always created **unassigned** regardless of mapping state. Human-in-the-loop via Slack is the primary path, not the DynamoDB lookup.
- A DynamoDB miss is not a failure — the "Accept" flow prompts manual input. Estimated <2% of initial assignments.
- Sync interval can drop to 1 minute at negligible cost (~120 extra Jira API calls/day).

This trades a <5 minute staleness window for operational simplicity over a streaming CDC pipeline from Jira (webhook listener, retries, callback auth). Pragmatic for capscope and first production release.

---

### Multi-tenant approach

Every request carries `X-Tenant-Id` (UUID v4). API Gateway validates its presence; Lambda enforces partition key scoping in DynamoDB.

| Dimension | Pattern | Rationale |
|---|---|---|
| Compute | Shared | Single Lambda handles all tenants. Cold start paid once. No cross-tenant state in memory — all state lives in DynamoDB. |
| Data | Pooled (row-level) | Single DynamoDB table with Partition Key = `tenant_id#email`. IAM condition `ddb:LeadingKeys` enforces tenant scope at the policy level — fail-closed even if application code has a bug. |
| Network | Shared | Single VPC, single subnet group. No per-tenant ENI or NAT Gateway. |

Silo isolation (per-tenant table) would cost ~$6.50/month for 50 tables vs ~$0/month idle for one pooled table — 13× the cost with no measurable security gain given the IAM guardrail.

---

### Audit trail

Every AI decision is linked to the resulting Jira ticket for full traceability:

- `issue_key` is included as a correlation ID in all subsequent EventBridge events and CloudWatch Logs structured logs.
- Jira ticket's description field contains a `Correlation-ID` header value that maps back to the original `alert.ingested` event.
- The AI diagnosis payload (root cause, confidence score, remediation steps, recommended `account_id`) is persisted alongside the event in CloudWatch Logs, keyed by the same correlation ID.
- This enables post-incident queries of the form: *"Show me the AI diagnosis that led to ticket INC-123."*

---

### Failure modes & recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| Jira API down (429/500) | Lambda catches HTTP >= 400. EventBridge retry exhausted (3 attempts), routes to DLQ. | Payload written to SQS DLQ with original `alert.ingested` envelope. `jira-dispatcher` emits `slack.fallback` → `slack-dispatcher` sends raw alert with "[JIRA DOWN]" prefix. DLQ redrive after Jira recovery. | < 60s (detection + fallback) | 0 (payload in DLQ) |
| AI recommends invalid/deactivated `account_id` | Jira returns 400 on `PUT /assignee` — `"user does not exist"`. | `jira-dispatcher` catches 400, logs to CloudWatch. Ticket remains **unassigned**. `slack.notify` event includes `assignee_status: "unassigned_invalid_user"`. Slack shows "Assign Me" button → webhook calls back to reassign to current engineer. | < 30s | 0 (ticket created, only assignment fails) |
| DynamoDB lookup timeout | Lambda `DynamoDB.GetItem` latency > 3s triggers CloudWatch alarm. Function catches `ProvisionedThroughputExceededException` or timeout. | Ticket created unassigned. `slack.notify` includes `assignee_status: "dynamodb_timeout"`. Slack shows "⚠️ User mapping unavailable — please assign manually." | < 5s | 0 (assignment deferred to human) |
