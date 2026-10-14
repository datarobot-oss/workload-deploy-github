# DataRobot Workload Deploy: GitHub Action

Deploy a repository to a [DataRobot Workload](https://docs.datarobot.com) from GitHub Actions. The action installs a pinned DataRobot CLI and runs `dr workload up`, which builds the `Dockerfile` on the platform and rolls the workload onto the image that it built.

The workload is the one named by the `workloadId` in the committed `.datarobot.yaml`. Every run rolls that same workload, so the endpoint stays the same.

> **Important:** v2 replaces the manifest format. v1 read its own manifest format and found the workload by name. v2 reads the `.datarobot.yaml` that the DataRobot CLI writes. For the changes, see [Migrate from v1](#migrate-from-v1).

## How it works

The deploy flow has three steps:

1. **Deploy once from a workstation.** Run `dr workload up` in the app directory. The command writes `.datarobot.yaml`, deploys, and adds a `workloadId` line to the file. Commit the file.
2. **Add the action.** Set two secrets and add a workflow, as in [Quick start](#quick-start).
3. **Push.** Each run checks that the manifest has a `workloadId`, installs the pinned CLI, and runs `dr workload up --yes --promote`.

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

The action never installs the `latest` release of the CLI. It installs the release set by `dr_cli_version` (default `v0.14.1`) and checks the SHA-256 checksum of the archive before it runs the binary. The expected checksums are in [`scripts/dr-cli-checksums.txt`](./scripts/dr-cli-checksums.txt), one for each release and platform (Linux and macOS, x86_64 and arm64).

Pinning is deliberate. The workload commands of the CLI change between releases. For example, v0.13 renamed `--lock` to `--promote`. A pinned version makes a run repeatable, and a version bump is a reviewed change.

To use another release, set `dr_cli_version`, and set `dr_cli_sha256` to the checksum of the archive for the runner. Alternatively, add the checksums of the release to the table in a pull request. A version without a checksum fails the install.

## Inputs

The following table lists the inputs of the action.

| Input | Default | Description |
| --- | --- | --- |
| `datarobot_endpoint` | The `DATAROBOT_ENDPOINT` variable | DataRobot instance URL. The `/api/v2` suffix is optional, because the action adds it when it is missing. |
| `datarobot_api_token` | The `DATAROBOT_API_TOKEN` variable | DataRobot API key. Pass it from a secret. |
| `working_directory` | `.` | App directory, relative to the workspace. The action searches for the manifest in this directory and in the parent directories, up to the workspace. |
| `promote` | `true` | Make the deployed version permanent by locking its artifact. A draft workload stops after 8 hours. |
| `dry_run` | `false` | Print the plan and change nothing. |
| `allow_create` | `false` | Let this run create the workload when the manifest has no `workloadId`. For details, see [The first deploy](#the-first-deploy). |
| `dr_cli_version` | `v0.14.1` | DataRobot CLI release to install. |
| `dr_cli_sha256` | From the checksum table | Checksum of the CLI archive. Required for a version that isn't in the table. |
| `dr_cli_download_base` | GitHub releases of `datarobot-oss/cli` | Base URL that serves the CLI releases. Set it to a mirror in a restricted network. |

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

## Plan on pull requests, apply on merge

To print the plan on pull requests, call the action with `dry_run: "true"`. Call it without `dry_run` on `main`. To add an approval step, run the apply job in a [GitHub environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment) with required reviewers. For a complete workflow, see [`examples/plan-and-apply.yml`](./examples/plan-and-apply.yml). Pull requests from forks get no secrets, so the plan works only for branches in the same repository.

Use a `concurrency` group, as in the quick start. A roll takes minutes, and a second deploy during a roll fails with HTTP 422. The action doesn't lock.

## Stop a workload

The companion action `datarobot-oss/workload-deploy-github/stop@v2` runs `dr workload stop` on the workload in the manifest. Stopping doesn't delete the workload. To bring it back, deploy again, or run `dr workload start WORKLOAD_ID` with the ID from the manifest. For a workflow, see [`examples/stop.yml`](./examples/stop.yml).

## Restricted networks

A runner that can't reach `github.com` can't fetch this action or the CLI. To run in such a network:

1. Copy this repository into an organization that you control, and reference the copy pinned to a commit.
2. Serve the CLI release archives from an internal location with the layout `BASE_URL/VERSION/dr_VERSION_OS_ARCH.tar.gz`, and set `dr_cli_download_base` to `BASE_URL`. The action still checks each archive against the checksum table or `dr_cli_sha256`, so a mirror can't swap the binary.

The DataRobot URL must also be reachable from the runner. For a private certificate authority (CA), the CLI has a `--ca-cert` option, which the action doesn't pass.

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

- Linux or macOS runners, on x86_64 or arm64.
- A DataRobot organization with Code-to-Workload builds enabled. The v1 README named the `ENABLE_WORKLOAD_API_CONTAINERS` flag for this. v2 hasn't re-checked it.
- A `Dockerfile` that produces a service that listens on the port in the manifest. The port must be 1024 or higher. The platform builds `linux/amd64`.

## Troubleshooting

The following table lists common errors and their fixes.

| Symptom | Fix |
| --- | --- |
| `No workloadId found in .datarobot.yaml` | Run `dr workload up` on a workstation and commit the manifest, or set `allow_create: true` for one run. Make sure `actions/checkout` ran first. |
| `No checksum for dr_...` | The version isn't in `scripts/dr-cli-checksums.txt`. Set `dr_cli_sha256`, or use a listed version. |
| `The checksum of ... does not match` | The archive isn't the one that the table or `dr_cli_sha256` names. Check the mirror and the version. |
| `DATAROBOT_ENDPOINT is not set` | Pass the `datarobot_endpoint` and `datarobot_api_token` inputs from secrets. |
| `answered HTTP 404, so the CLI could not verify your credentials` | The endpoint isn't the URL of a DataRobot instance. Check the host in `datarobot_endpoint`. |
| `HTTP 422` about a pending replacement | Two deploys ran at once. Add a `concurrency` group. |
| The workload stops after 8 hours | The version was deployed with `promote: "false"`. Deploy again with `promote` on. |

## Status

The scripts have bats tests that run against a stub `dr`. The behavior of the CLI was observed with `dr` v0.14.1: `workload up --yes --promote`, `workload endpoint`, a dry run from a clean checkout, and a second create with the same name. The action ran from a workflow on a GitHub-hosted Linux runner against a DataRobot instance: the guard, a create, a dry run, a roll and a stop. Not tested: macOS runners, a mirrored `dr_cli_download_base`, and `promote: "true"`.

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
