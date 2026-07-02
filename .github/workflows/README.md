# Workflow Notes

This directory contains the GitHub Actions workflows used for application and infrastructure CI/CD.

## Sandbox Terraform schedule

The shared `sandbox` environment currently uses:

- `ci-infra.yml`: scheduled Terraform apply at `07:17` ICT every day
- `terraform-destroy.yml`: manual Terraform destroy only

GitHub Actions cron expressions use UTC. The current schedules are:

- `17 0 * * *` -> `07:17` ICT

Scheduled infra runs also have a time-window guard. If GitHub Actions starts the cron run outside `07:00-07:59` ICT, the workflow skips the Terraform jobs so a delayed scheduler event cannot recreate the sandbox hours after an intentional destroy.

## App deploy after infra apply

`ci-app.yml` deploys Lambda code automatically when app code is pushed to `develop` or `main`.

`ci-infra.yml` only dispatches App CI after Terraform apply in these cases:

- scheduled infra apply, so the daily sandbox can be hydrated when resources are missing
- manual infra apply with `deploy_app_after_apply=true`

Infra PRs and infra push/merge runs do not dispatch App CI by default. If an infra change creates or changes Lambda runtime resources and the current branch app code should be redeployed, use manual infra apply with `deploy_app_after_apply=true`, or run App CI manually with `deploy=true`.

## Sandbox destroy guardrails

`terraform-destroy.yml` no longer has a scheduled trigger. Destroy is manual-only and requires:

- selecting the `sandbox` environment
- typing `destroy-sandbox` in the confirmation input
- passing the shared Terraform state concurrency lock

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

This prevents Terraform apply and destroy runs from executing at the same time in Actions.
