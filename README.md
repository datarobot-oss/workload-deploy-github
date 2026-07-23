# DataRobot Workload Deploy — GitHub Action

Deploy any Git repository to a [DataRobot Workload](https://docs.datarobot.com)
straight from GitHub Actions. Point it at a repo that has a `.datarobot.yaml`
(or `.datarobot/workload.yaml`) and a `Dockerfile`, set two secrets, and the
action does the rest: it installs the DataRobot CLI, builds your repo into a
container image **server-side** (Code-to-Workload), and creates — or
zero-downtime rolling-replaces — the workload.

The manifest is the **single source of truth**. There is nothing else to wire up.

> This is the GitHub Actions port of the GitLab CI/CD component
> [`datarobot-oss/workload-deploy`](https://gitlab.com/datarobot-oss/workload-deploy).
> Same manifest, same behavior; GitHub-native packaging (a composite action),
> outputs, and environments.

---

## Quick start

### 1. Add a manifest to your repo

Create `.datarobot.yaml` at the root of the repo you want to deploy (see
[`examples/.datarobot.yaml`](./examples/.datarobot.yaml) for a fully annotated copy):

```yaml
name: my-service        # unique workload name
importance: low         # low | moderate | high | critical
build:
  dockerfile: ./Dockerfile
  port: 8080            # container listen port, must be >= 1024
  health: /healthz      # readiness/liveness probe path
runtime:
  replicas: 1           # use >= 2 for zero-downtime redeploys
  cpu: 0.5              # cores
  memory: 512MB         # B/KB/MB/GB (not Ki/Mi/Gi)
```

Your repo also needs the `Dockerfile` referenced above. DataRobot builds it for
you — you don't need Docker, a registry, or push credentials.

### 2. Add two secrets

In your project: **Settings ▸ Secrets and variables ▸ Actions**, add:

| Secret                | Value                            |
|-----------------------|----------------------------------|
| `DATAROBOT_ENDPOINT`  | e.g. `https://app.datarobot.com` |
| `DATAROBOT_API_TOKEN` | your DataRobot API key           |

`DATAROBOT_ENDPOINT` may be given with or without the trailing `/api/v2` — both
work. Generate the token from **DataRobot ▸ Developer Tools ▸ API Keys**.

### 3. Add a workflow

Create `.github/workflows/deploy.yml` in your project (see
[`examples/deploy.yml`](./examples/deploy.yml)):

```yaml
name: Deploy to DataRobot

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: datarobot
      url: ${{ steps.deploy.outputs.endpoint }}
    steps:
      - uses: actions/checkout@v4
      - id: deploy
        uses: datarobot-oss/workload-deploy-github@v1
        with:
          datarobot_endpoint: ${{ secrets.DATAROBOT_ENDPOINT }}
          datarobot_api_token: ${{ secrets.DATAROBOT_API_TOKEN }}
```

That's it. On the next push to `main`, the job builds and deploys your workload
and prints its endpoint URL. The `id: deploy` + `environment.url` wiring surfaces
a clickable link to the live app on the run and the environment page.

> **Checkout first.** Unlike the GitLab component, a GitHub Action does not
> automatically have your repository on disk — always run `actions/checkout`
> before this action so it can read the manifest and upload your source.

---

## What the action does

1. Installs `curl`, `jq`, `yq`, `git`, and the **DataRobot CLI** (only what's
   missing — GitHub-hosted `ubuntu-latest` already has most of these).
2. Locates the manifest (`.datarobot.yaml` → `.datarobot/workload.yaml`).
3. Renders an artifact spec from the manifest and creates a draft artifact.
4. Uploads your source (respecting `.dockerignore` / `.wapiignore`) and builds
   the image **server-side**, waiting for the build to complete.
5. Looks up a workload by `name`:
   - **not found** → creates it;
   - **found** → issues a **rolling replacement** onto the new image (same URL).
     If the existing workload's artifact is already locked (true for every
     redeploy after the first healthy one), the new artifact is locked *before*
     the swap so the replacement endpoint's lock-status check passes.
6. Waits until the workload reports `running`.
7. **Locks the artifact** once the workload is healthy, if it isn't already.
   Draft artifacts are impermanent — the platform reclaims them, which stops
   the workload — so locking promotes it to an immutable, versioned artifact
   that keeps running.
8. Sets action **outputs** and writes a summary (with the live endpoint and the
   DataRobot console URL) to the run's **job summary**.
9. Best-effort deletes a leftover unlocked draft from a previous deploy.

The action is **idempotent** and **stateless** — it identifies the workload by
the `name` in your manifest, so it needs no cached state between runs.

---

## Inputs

All inputs are optional except the two credentials (which may instead be
supplied as `DATAROBOT_ENDPOINT` / `DATAROBOT_API_TOKEN` environment variables).

| Input                 | Default    | Description |
|-----------------------|------------|-------------|
| `datarobot_endpoint`  | *(env)*    | DataRobot instance URL. Falls back to the `DATAROBOT_ENDPOINT` env var. |
| `datarobot_api_token` | *(env)*    | DataRobot API key (pass from a secret). Falls back to the `DATAROBOT_API_TOKEN` env var. |
| `manifest`            | *(auto)*   | Explicit manifest path. Empty = `.datarobot.yaml` then `.datarobot/workload.yaml`. |
| `workload_name`       | *(manifest `name`)* | The deploy target's workload name. Override (e.g. `my-service-${{ github.ref_name }}`) to give each environment its own workload. |
| `dr_cli_version`      | `latest`   | DataRobot CLI version to install (e.g. `v0.2.78`). |
| `wait_timeout`        | `1200`     | Seconds to wait for the build and for the workload to become healthy. |
| `prune_old_artifact`  | `true`     | Delete a leftover unlocked draft after a successful redeploy (the new, locked artifact is kept). |

## Outputs

| Output          | Example |
|-----------------|---------|
| `workload_id`   | `6a60fbcd…` |
| `workload_name` | `my-service` |
| `endpoint`      | `https://app.datarobot.com/api/v2/endpoints/workloads/…/` |
| `console_url`   | `https://app.datarobot.com/console-nextgen/workloads/…/overview` |
| `artifact_id`   | `6a60f6c1…` |

Read them within the same job via `steps.<id>.outputs.*`, or expose them at the
job level (`outputs:`) for downstream jobs that `needs:` the deploy — see
[`examples/deploy-with-verify.yml`](./examples/deploy-with-verify.yml).

---

## Deploying to multiple environments

Each **deploy target is one workload**, identified by `workload_name` (defaults
to the manifest `name`). The action finds that workload by name and rolls it in
place, so **repeated pushes to the same target always land on the same
workload** — never a duplicate. Different targets need different names.

Map branches to [GitHub Environments](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
with one job per environment — see
[`examples/deploy-environments.yml`](./examples/deploy-environments.yml). For
per-branch "review app" workloads, derive `workload_name` from the ref (e.g.
`my-service-${{ github.ref_name }}`).

### Stopping an environment

The companion **stop action** (`datarobot-oss/workload-deploy-github/stop@v1`)
runs `dr workload stop` on the workload. GitHub has no direct equivalent of
GitLab's `on_stop`, so wire it to the `delete` event (fires on branch deletion)
and/or a manual `workflow_dispatch` — see
[`examples/stop-on-branch-delete.yml`](./examples/stop-on-branch-delete.yml).

Stopping is **non-destructive**: the workload is stopped, not deleted, so the
next deploy (or `dr workload start <id>`) brings it straight back. This pairs
naturally with per-branch review apps — the workload is reclaimed when the
branch goes away.

---

## Examples

Ready-to-copy files in [`examples/`](./examples):

| File | What it shows |
|------|---------------|
| [`.datarobot.yaml`](./examples/.datarobot.yaml) | Annotated manifest. |
| [`deploy.yml`](./examples/deploy.yml) | Minimal single-job deploy. |
| [`deploy-with-verify.yml`](./examples/deploy-with-verify.yml) | Deploy + a `smoke-test` job consuming the outputs. |
| [`deploy-environments.yml`](./examples/deploy-environments.yml) | Branch → environment mapping (main → production, staging → staging). |
| [`deploy-on-tags.yml`](./examples/deploy-on-tags.yml) | Deploy on version tags to a `production` environment. |
| [`stop-on-branch-delete.yml`](./examples/stop-on-branch-delete.yml) | Stop the workload on branch delete / manually. |

---

## Requirements & notes

- **Checkout.** Run `actions/checkout` before this action so your repo (manifest
  + source) is on disk.
- **Runner.** Designed for Linux runners (`ubuntu-latest` or a Linux container).
  It auto-installs missing tooling via `apt-get` or `apk`.
- **Feature flag.** Code-to-Workload container builds require the
  `ENABLE_WORKLOAD_API_CONTAINERS=true` flag on your DataRobot organization.
  Ask your DataRobot admin if the build step fails with a permission error.
- **Image architecture.** DataRobot builds `linux/amd64` — your Dockerfile must
  produce a service that listens on `build.port`.
- **Manifest fields.** `name` and `build.port` are required; everything else has
  sensible defaults. `memory` uses decimal units (`512MB`, `2GB`) — Kubernetes
  binary suffixes (`Mi`/`Gi`) are not supported. `port` must be `>= 1024`.
- **Zero-downtime.** Rolling replacement is zero-downtime only with
  `runtime.replicas >= 2`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `DATAROBOT_ENDPOINT is not set` | Add the secrets and pass them via the action inputs (step 2/3). |
| `No manifest found` | Add `.datarobot.yaml` to your repo root, or set the `manifest` input. Make sure `actions/checkout` ran first. |
| `Image build FAILED` | The job prints the build log tail. Check your `Dockerfile`. |
| Permission / flag error on build | Ask your admin to enable `ENABLE_WORKLOAD_API_CONTAINERS`. |
| `Workload is failed` | Inspect with `dr workload logs <id>` locally, or the DataRobot console. |

## License

Copyright 2026 DataRobot, Inc.

Licensed under the [Apache License, Version 2.0](./LICENSE).
