# DataRobot Workload Deploy: GitHub Action

Deploy a repository to a [DataRobot Workload](https://docs.datarobot.com) from GitHub Actions. The action runs a pinned DataRobot CLI from its container image and runs `dr workload up`, which builds the `Dockerfile` on the platform and rolls the workload onto the image that it built.

The workload is the one named by the `workloadId` in the committed `.datarobot.yaml`. Every run rolls that same workload, so the endpoint stays the same.

> **Important:** v2 replaces the manifest format. v1 read its own manifest format and found the workload by name. v2 reads the `.datarobot.yaml` that the DataRobot CLI writes. For the changes, see [Migrate from v1](#migrate-from-v1).

## How it works

The deploy flow has three steps:

1. **Deploy once from a workstation.** Run `dr workload up` in the app directory. The command writes `.datarobot.yaml`, deploys, and adds a `workloadId` line to the file. Commit the file.
2. **Add the action.** Set two secrets and add a workflow, as in [Quick start](#quick-start).
3. **Push.** Each run checks that the manifest has a `workloadId`, then runs `dr workload up --yes --promote` with the pinned CLI image.

The first deploy runs on a workstation because the CLI finds the workload through the `workloadId` in the manifest. A CI checkout starts clean, so a manifest without that line makes every run create a workload. The action fails with an error in that case. For the exception, see [The first deploy](#the-first-deploy).

## Quick start

To set up the action, add two secrets in **Settings > Secrets and variables > Actions**: `DATAROBOT_ENDPOINT`, the URL of the DataRobot instance (for example, `https://app.datarobot.com`), and `DATAROBOT_API_TOKEN`, a DataRobot API key. Then add the following workflow as `.github/workflows/deploy.yml`:

```yaml
name: Deploy to DataRobot

on:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: deploy-datarobot
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    environment:
      name: datarobot
      url: ${{ steps.deploy.outputs.endpoint }}
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - id: deploy
        uses: datarobot-oss/workload-deploy-github@v2
        with:
          datarobot_endpoint: ${{ secrets.DATAROBOT_ENDPOINT }}
          datarobot_api_token: ${{ secrets.DATAROBOT_API_TOKEN }}
```

Run `actions/checkout` first so the manifest and the source are on disk. In a production repository, pin the action to a full commit SHA.

## The DataRobot CLI is pinned

The action runs the CLI from the container image `ghcr.io/datarobot-oss/cli`. It never uses the `latest` tag. The `dr_cli_image` input defaults to the tag of a specific release, `v0.14.2`. The action fails when the image has no tag or has the `latest` tag.

Pinning is deliberate. The workload commands of the CLI change between releases. For example, v0.13 renamed `--lock` to `--promote`. A pinned version makes a run repeatable, and a version bump is a reviewed change. For the strongest pin, set `dr_cli_image` to a digest, such as `ghcr.io/datarobot-oss/cli@sha256:...`.

The action starts the container as the runner's user and mounts the workspace into it, so the files that the CLI writes, such as `.datarobot.yaml`, stay writable on the runner. The endpoint and the token go into the container as environment variables, not as command-line arguments.

## Inputs

The following table lists the inputs of the action.

| Input | Default | Description |
| --- | --- | --- |
| `datarobot_endpoint` | The `DATAROBOT_ENDPOINT` variable | DataRobot instance URL. The `/api/v2` suffix is optional, because the action adds it when it is missing. |
| `datarobot_api_token` | The `DATAROBOT_API_TOKEN` variable | DataRobot API key. Pass it from a secret. |
| `working_directory` | `.` | App directory, relative to the workspace. The action searches for the manifest in this directory and in the parent directories, up to the workspace. |
| `promote` | `true` | Make the deployed version permanent by locking its artifact. A draft workload stops after 8 hours. |
| `sync_env` | `false` | Run `dr workload up` with `--sync-env`. For details, see [Sync the environment variables](#sync-the-environment-variables). |
| `dry_run` | `false` | Print the plan and change nothing. |
| `allow_create` | `false` | Let this run create the workload when the manifest has no `workloadId`. For details, see [The first deploy](#the-first-deploy). |
| `dr_cli_image` | `ghcr.io/datarobot-oss/cli:v0.14.2` | Container image that runs the DataRobot CLI. Name a release tag or a digest. Set it to a mirror in a restricted network. |

## Outputs

The following table lists the outputs of the action. Each run also writes both values to the job summary.

| Output | Description |
| --- | --- |
| `workload_id` | The `workloadId` of the workload. Empty on a dry run. |
| `endpoint` | The endpoint URL, with a trailing slash. Empty on a dry run. The endpoint is served under `/api/v2`, so calls to it need an API token. |

## The first deploy

Run `dr workload up` once on a workstation and commit `.datarobot.yaml`. This is the supported path.

To create the workload from CI instead, set `allow_create: true` for that one run. The run creates the workload and prints the complete `.datarobot.yaml`, including the `workloadId`, in the job summary. The checkout on the runner is then discarded, so commit the printed file to the repository and turn `allow_create` off. If `allow_create` stays on and the file isn't committed, every run creates another workload. The manifest holds IDs but no secret values, but the job summary is visible to everyone who can read the repository.

The CLI doesn't reject a duplicate. In a test on a staging instance with `dr` v0.14.1, a second `dr workload up` from a clean checkout with the same name and no `workloadId` created a second workload with the same name, and both ran.

## Sync the environment variables

`dr workload up --sync-env` brings the environment variables in the manifest into line with the `.env` file in the app directory before it deploys. To pass the flag, set `sync_env: "true"`.

The sync adds variables that the manifest doesn't declare, rewrites a value that changed, and removes a variable that `.env` no longer has. A variable that `.env` also names replaces the manifest entry, including a `source: api-key` entry. The sync works on the checkout, so the manifest on the runner changes, but the repository doesn't.

A checkout has a `.env` file only if you commit one or write it in an earlier step. Without the file, `--sync-env` changes nothing. Values that `--sync-env` writes in the clear are visible in the manifest, so keep secrets out of a committed `.env`.

## Plan on pull requests, apply on merge

To print the plan on pull requests, call the action with `dry_run: "true"`. Call it without `dry_run` on `main`. To add an approval step, run the apply job in a [GitHub environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment) with required reviewers. For a complete workflow, see [`examples/plan-and-apply.yml`](./examples/plan-and-apply.yml). Pull requests from forks get no secrets, so the plan works only for branches in the same repository.

Use a `concurrency` group, as in the quick start. A roll takes minutes, and a second deploy during a roll fails with HTTP 422. The action doesn't lock.

## Stop a workload

The companion action `datarobot-oss/workload-deploy-github/stop@v2` runs `dr workload stop` on the workload in the manifest. Stopping doesn't delete the workload. To bring it back, deploy again, or run `dr workload start WORKLOAD_ID` with the ID from the manifest. For a workflow, see [`examples/stop.yml`](./examples/stop.yml).

## Restricted networks

A runner that can't reach `github.com` can't fetch this action, and a runner that can't reach `ghcr.io` can't pull the CLI image. To run in such a network:

1. Copy this repository into an organization that you control, and reference the copy pinned to a commit.
2. Copy the CLI image into a registry that the runner can reach, and set `dr_cli_image` to the copy. Use a digest to make sure that the copy is the image that you reviewed.

The container gets the `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` variables of the runner, in upper and lower case, when they are set. The DataRobot URL must also be reachable from the runner. For a private certificate authority (CA), the CLI has a `--ca-cert` option, which the action doesn't pass.

## Examples

The following table lists the example workflows in the `examples` folder.

| File | What it shows |
| --- | --- |
| [`deploy.yml`](./examples/deploy.yml) | Deploy on every push to `main`. |
| [`plan-and-apply.yml`](./examples/plan-and-apply.yml) | Plan on pull requests, apply on `main` behind an environment. |
| [`deploy-with-verify.yml`](./examples/deploy-with-verify.yml) | Deploy, then run a smoke test that uses the outputs. |
| [`stop.yml`](./examples/stop.yml) | Stop the workload manually. |
| [`.datarobot.yaml`](./examples/.datarobot.yaml) | A manifest as the CLI writes it. |

## Requirements

The action needs the following:

- A Linux runner with Docker, such as `ubuntu-latest`. The action runs the CLI in a container, so macOS and Windows runners don't work.
- A DataRobot organization with Code-to-Workload builds enabled. The v1 README named the `ENABLE_WORKLOAD_API_CONTAINERS` flag for this. v2 hasn't re-checked it.
- A `Dockerfile` that produces a service that listens on the port in the manifest. The port must be 1024 or higher. The platform builds `linux/amd64`.

## Troubleshooting

The following table lists common errors and their fixes.

| Symptom | Fix |
| --- | --- |
| `No workloadId found in .datarobot.yaml` | Run `dr workload up` on a workstation and commit the manifest, or set `allow_create: true` for one run. Make sure `actions/checkout` ran first. |
| `Docker is not available` | The runner has no Docker. Use a Linux runner with Docker, such as `ubuntu-latest`. |
| `dr_cli_image ... uses the latest tag` or `has no tag` | Set `dr_cli_image` to an image with a release tag or a digest. |
| `DATAROBOT_ENDPOINT is not set` | Pass the `datarobot_endpoint` and `datarobot_api_token` inputs from secrets. |
| `answered HTTP 404, so the CLI could not verify your credentials` | The endpoint isn't the URL of a DataRobot instance. Check the host in `datarobot_endpoint`. |
| `HTTP 422` about a pending replacement | Two deploys ran at once. Add a `concurrency` group. |
| The workload stops after 8 hours | The version was deployed with `promote: "false"`. Deploy again with `promote` on. |

## Status

The scripts have bats tests that run against stub `dr` and `docker` commands. The action ran from a workflow on a GitHub-hosted `ubuntu-latest` runner against a DataRobot instance with the `v0.14.2` image: the guard, a dry run with `sync_env`, a create, a stop and a delete. The runner's user wrote the manifest into the workspace. Not tested: a mirrored `dr_cli_image` and `promote: "true"`.

## Migrate from v1

v2 changes the manifest, the inputs, and the outputs:

- The manifest is the one that `dr workload up` writes. v2 doesn't read the v1 fields `build.port`, `build.health`, `runtime.cpu`, and the rest. Run `dr workload up` in the app directory to create the manifest.
- The `workloadId` in the manifest names the workload. v1 matched the `name`. To keep a workload that v1 deployed, put its ID in the manifest.
- The inputs `manifest`, `workload_name`, `wait_timeout`, and `prune_old_artifact` are removed, and so are the outputs `workload_name`, `console_url`, and `artifact_id`.
- Per-branch workloads named after the ref aren't supported. The CLI takes the workload name from the manifest.
- The `v1` tag is unchanged.

## Develop

Run the tests with [bats-core](https://github.com/bats-core/bats-core):

```sh
tests/run.sh
```

CI runs `actionlint`, `yamllint`, `shfmt`, `shellcheck`, `gitleaks`, and the bats suite. The indentation for shell files is set in `.editorconfig`.

## License

Copyright 2026 DataRobot, Inc.

Licensed under the [Apache License, Version 2.0](./LICENSE).
