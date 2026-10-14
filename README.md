# DataRobot Workload Deploy: GitHub Action

Deploy a repository to a [DataRobot Workload](https://docs.datarobot.com) from GitHub Actions. The action installs a pinned DataRobot CLI and runs `dr workload up`, which builds your `Dockerfile` on the platform and rolls the workload onto the new image.

The workload is the one named by the `workloadId` in your committed `.datarobot.yaml`. Every run rolls that same workload, so the endpoint stays the same.

> **Version 2 replaces the manifest.** v1 read its own manifest format and found the workload by name. v2 uses the `.datarobot.yaml` that the DataRobot CLI writes. See [Migrating from v1](#migrating-from-v1).

## How it works

1. **Deploy once from your machine.** Run `dr workload up` in your app directory. It writes `.datarobot.yaml`, deploys, and adds a `workloadId` line to the file. Commit the file.
2. **Add the action.** Set two secrets and add a workflow, as in [Quick start](#quick-start).
3. **Push.** Each run checks that the manifest has a `workloadId`, installs the pinned CLI, and runs `dr workload up --yes --promote`.

The first deploy runs on your machine because the CLI finds its workload through the `workloadId` in the manifest. A CI checkout starts clean, so a manifest without that line would make every run create a new workload. The action refuses to run in that case. See [The first deploy](#the-first-deploy).

## Quick start

Add two secrets (Settings > Secrets and variables > Actions): `DATAROBOT_ENDPOINT`, for example `https://app.datarobot.com`, and `DATAROBOT_API_TOKEN`, a DataRobot API key. Then add `.github/workflows/deploy.yml`:

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

Run `actions/checkout` first so the manifest and your source are on disk. Pin the action to a full commit SHA in a production repository.

## The DataRobot CLI is pinned

The action never installs `latest`. It installs the release named by `dr_cli_version` (default `v0.13.1`) and checks the archive's SHA-256 before it runs the binary. The expected checksums are in [`scripts/dr-cli-checksums.txt`](./scripts/dr-cli-checksums.txt), one per release and platform (Linux and macOS, x86_64 and arm64).

This is deliberate. The CLI's workload commands are still changing between releases, and a new release can rename a flag or change what a command does. A pinned version makes a run repeatable, and a bump is a reviewed change.

To use another release, pass `dr_cli_version` and the checksum of the archive for your runner as `dr_cli_sha256`, or add the release's checksums to the table in a pull request. A version with no checksum fails the install.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `datarobot_endpoint` | the `DATAROBOT_ENDPOINT` variable | DataRobot instance URL. |
| `datarobot_api_token` | the `DATAROBOT_API_TOKEN` variable | DataRobot API key. Pass it from a secret. |
| `working_directory` | `.` | App directory, relative to the workspace. The manifest is searched for here and in the parent directories, up to the workspace. |
| `promote` | `true` | Make the deployed version permanent by locking its artifact. A draft workload stops after 8 hours. |
| `dry_run` | `false` | Print the plan and change nothing. |
| `allow_create` | `false` | Let this run create the workload when the manifest has no `workloadId`. See [The first deploy](#the-first-deploy). |
| `dr_cli_version` | `v0.13.1` | DataRobot CLI release to install. |
| `dr_cli_sha256` | from the table | Checksum of the CLI archive. Required for a version that is not in the table. |
| `dr_cli_download_base` | GitHub releases of `datarobot-oss/cli` | Where releases are served, as `<base>/<version>/<archive>`. Set it to a mirror in a restricted network. |

## Outputs

| Output | Description |
| --- | --- |
| `workload_id` | The `workloadId` of the workload. Empty on a dry run. |
| `endpoint` | The endpoint URL, with a trailing slash. Empty on a dry run. The endpoint is served under `/api/v2`, so calls to it need your API token. |

The run also writes a summary with both values to the job summary.

## The first deploy

Run `dr workload up` once on your machine and commit `.datarobot.yaml`. That is the supported path.

To create the workload from CI instead, set `allow_create: true` for that one run. The run creates the workload, prints the `workloadId` in the log and the job summary, and then the runner's checkout is discarded. Commit `workloadId: <id>` to `.datarobot.yaml` and turn `allow_create` off. If you leave it on without committing the ID, every run creates another workload.

## Plan on pull requests, apply on merge

Call the action with `dry_run: "true"` on pull requests to print the plan, and without it on `main`. Put the apply job in a [GitHub environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment) with required reviewers to add an approval step. See [`examples/plan-and-apply.yml`](./examples/plan-and-apply.yml). Pull requests from forks get no secrets, so the plan only works for branches in your repository.

Use a `concurrency` group, as in the quick start. A roll takes minutes, and a second deploy during a roll fails with HTTP 422. The action does not lock for you.

## Stopping a workload

The companion action `datarobot-oss/workload-deploy-github/stop@v2` runs `dr workload stop` on the workload in the manifest. Stopping does not delete the workload. `dr workload start <id>` or the next deploy brings it back. See [`examples/stop.yml`](./examples/stop.yml).

## Restricted networks

A runner that cannot reach `github.com` cannot fetch this action or the CLI. To run in such a network:

1. Copy this repository into your own organization and reference it from there, pinned to a commit.
2. Serve the CLI release archives from an internal location with the layout `<base>/<version>/dr_<version>_<OS>_<arch>.tar.gz`, and set `dr_cli_download_base` to it. The action still checks each archive against the table or `dr_cli_sha256`, so a mirror cannot swap the binary.

Your DataRobot URL must also be reachable from the runner. The CLI has a `--ca-cert` option for a private CA, which the action does not pass yet.

## Examples

| File | What it shows |
| --- | --- |
| [`deploy.yml`](./examples/deploy.yml) | Deploy on every push to `main`. |
| [`plan-and-apply.yml`](./examples/plan-and-apply.yml) | Plan on pull requests, apply on `main` behind an environment. |
| [`deploy-with-verify.yml`](./examples/deploy-with-verify.yml) | Deploy, then a smoke test that uses the outputs. |
| [`stop.yml`](./examples/stop.yml) | Stop the workload by hand. |
| [`.datarobot.yaml`](./examples/.datarobot.yaml) | What the CLI writes. |

## Requirements

- Linux or macOS runners. The architecture is x86_64 or arm64.
- A DataRobot organization with Code-to-Workload builds enabled. The v1 README named the `ENABLE_WORKLOAD_API_CONTAINERS` flag for this. v2 has not re-checked it.
- A `Dockerfile` that produces a service listening on the port in the manifest, which must be 1024 or above. The platform builds `linux/amd64`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No workloadId found in .datarobot.yaml` | Run `dr workload up` on your machine and commit the manifest, or set `allow_create: true` for one run. Make sure `actions/checkout` ran first. |
| `No checksum for dr_...` | The version is not in `scripts/dr-cli-checksums.txt`. Pass `dr_cli_sha256`, or use a listed version. |
| `The checksum of ... does not match` | The archive is not the one the table or `dr_cli_sha256` names. Check the mirror and the version. |
| `DATAROBOT_ENDPOINT is not set` | Pass the `datarobot_endpoint` and `datarobot_api_token` inputs from secrets. |
| `HTTP 422` about a pending replacement | Two deploys ran at once. Add a `concurrency` group. |
| The workload stops after 8 hours | The version was deployed with `promote: "false"`. Deploy again with it on. |

## Status

The scripts are tested with bats against a stub `dr`, and the CLI behavior was observed with `dr` v0.13.1: `workload up --yes --promote`, `workload endpoint`, and a dry run from a fresh checkout. Not yet run: the action itself in a GitHub Actions workflow against a DataRobot instance, macOS runners, and a mirrored `dr_cli_download_base`.

## Migrating from v1

- The manifest is the one `dr workload up` writes. The v1 fields `build.port`, `build.health`, `runtime.cpu` and the rest are not read. Run `dr workload up` in your app directory to create the new manifest.
- Workloads are no longer found by `name`. The `workloadId` in the manifest names the workload. To keep an existing workload, put its ID in the manifest.
- The `manifest`, `workload_name`, `wait_timeout` and `prune_old_artifact` inputs are gone, and so are the `workload_name`, `console_url` and `artifact_id` outputs.
- Per-branch workloads named after the ref are no longer supported. The CLI takes the name from the manifest.
- The `v1` tag is unchanged.

## Development

Run the tests with [bats-core](https://github.com/bats-core/bats-core):

```sh
tests/run.sh
```

CI runs `actionlint`, `yamllint`, `shfmt`, `shellcheck`, `gitleaks` and the bats suite. Indentation for shell files is in `.editorconfig`.

## License

Copyright 2026 DataRobot, Inc.

Licensed under the [Apache License, Version 2.0](./LICENSE).
