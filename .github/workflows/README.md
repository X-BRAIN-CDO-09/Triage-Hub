# Workflow Notes

This directory contains the GitHub Actions workflows used for application and infrastructure CI/CD.

## Sandbox Terraform schedule

The shared `sandbox` environment currently uses:

- `ci-infra.yml`: scheduled Terraform apply at `07:17` ICT every day
- `terraform-destroy.yml`: scheduled Terraform destroy at `00:00` ICT every day

GitHub Actions cron expressions use UTC. The current schedules are:

- `17 0 * * *` -> `07:17` ICT
- `0 17 * * *` -> `00:00` ICT

## App deploy after infra apply

`ci-app.yml` deploys Lambda code automatically when app code is pushed to `develop` or `main`.

`ci-infra.yml` only dispatches App CI after Terraform apply in these cases:

- scheduled infra apply, so the daily sandbox can be hydrated after a nightly destroy
- manual infra apply with `deploy_app_after_apply=true`

Infra PRs and infra push/merge runs do not dispatch App CI by default. If an infra change creates or changes Lambda runtime resources and the current branch app code should be redeployed, use manual infra apply with `deploy_app_after_apply=true`, or run App CI manually with `deploy=true`.

## Sandbox destroy guardrails

The scheduled destroy workflow is protected by three GitHub Actions variables. These should be configured in the `sandbox` environment variables unless the team intentionally wants repo-wide behavior.

### `ENABLE_AUTO_DESTROY`

- `true`: allow the nightly scheduled destroy to proceed
- `false` or unset: always skip scheduled destroy

### `SKIP_AUTO_DESTROY`

- `true`: temporary keepalive switch for the shared sandbox
- `false` or unset: do not block scheduled destroy

### `LEASE_UNTIL`

Optional ISO-8601 UTC timestamp, for example:

```text
2026-06-30T02:00:00Z
```

If the current UTC time is earlier than `LEASE_UNTIL`, scheduled destroy is skipped.

## Recommended values

### Normal nightly auto-destroy

```text
ENABLE_AUTO_DESTROY=true
SKIP_AUTO_DESTROY=false
LEASE_UNTIL=
```

### Keep sandbox alive tonight

```text
ENABLE_AUTO_DESTROY=true
SKIP_AUTO_DESTROY=true
LEASE_UNTIL=
```

### Keep sandbox alive until a specific time

```text
ENABLE_AUTO_DESTROY=true
SKIP_AUTO_DESTROY=false
LEASE_UNTIL=2026-06-30T02:00:00Z
```

## Terraform lock handling

Terraform apply and destroy use:

```text
-lock-timeout=10m
```

This means Terraform will wait up to 10 minutes to acquire the remote state lock before failing. It does not know how much lock time remains; it simply retries until the lock is released or the timeout is reached.

The workflows also use a shared GitHub Actions concurrency group:

```text
terraform-sandbox-state
```

This prevents scheduled apply and destroy runs from executing at the same time in Actions.
