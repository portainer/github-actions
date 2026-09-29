# github-actions

Shared, reusable GitHub Actions workflows and composite actions for repos
that build a multi-arch container image and ship it with a Helm chart. Put CI
and release logic here once, so a fix lands in every consuming repo instead of
being copied into each of them.

## Design shape

Every consumer's own trigger file (`ci.yml`, `release.yml`) composes the same
five self-contained blocks, calling each once **per repository** — except
`build-image` and `scout`, called once **per image**. A repo that publishes a
second image (for example, a companion workspace image) just calls those two
blocks a second time. Nothing here assumes a single image.

| Block | Called | Purpose |
|---|---|---|
| `validate.yml` | once per repo | lint, test, build, secret scan, Helm chart lint/render; on a release dispatch, the version check |
| `build-image.yml` | once **per image** | builds every arch, pushes by digest, assembles the multi-arch tag |
| `scout.yml` | once **per image** | Docker Scout vulnerability scan |
| `publish-chart.yml` | once per repo | packages and pushes the Helm chart (dev chart on push/pre-release, release chart on release) |
| `publish-github-release.yml` | once per repo, release path only | creates the GitHub Release, marked latest only if it's the highest |

`ci.yml` and `release.yml` end up structurally identical across every
consumer — same blocks, same order — differing only in which inputs they
pass. A `pre-release` boolean on `release.yml` (not a separate trigger file)
picks the registry namespace/chart registry and whether a GitHub Release
gets created at all.

The composite actions under `.github/actions/` (`resolve-image-tag`,
`chart-version`, `checkout-with-submodules`, `package-and-push-chart`, `docker-scout-scan`,
`install-and-run-gitleaks`, `setup-toolchain`, `chart-render-guard`) are
internal building blocks the workflows above call — no consumer repo
references one of these directly.

## Worked example

A minimal single-image `ci.yml` in a consuming repo:

```yaml
name: ci

on:
  pull_request:
    branches: [develop, 'release/**']
  push:
    branches: [develop, 'release/**']

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  validate:
    uses: portainer/github-actions/.github/workflows/validate.yml@<sha> # vX.Y.Z
    with:
      runtime: node
      package-manager: pnpm
      app-repositories: my-app,my-private-submodule
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}

  build-app-image:
    needs: [validate]
    uses: portainer/github-actions/.github/workflows/build-image.yml@<sha> # vX.Y.Z
    with:
      image-name: my-app
      app-repositories: my-app,my-private-submodule
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}
      registry-username: ${{ secrets.REGISTRY_USERNAME }}
      registry-password: ${{ secrets.REGISTRY_PASSWORD }}

  scout-app-image:
    needs: [build-app-image]
    permissions:
      contents: read
      pull-requests: write
    uses: portainer/github-actions/.github/workflows/scout.yml@<sha> # vX.Y.Z
    with:
      image: ${{ needs.build-app-image.outputs.image-ref }}
    secrets:
      registry-username: ${{ secrets.REGISTRY_USERNAME }}
      registry-password: ${{ secrets.REGISTRY_PASSWORD }}

  publish-chart:
    needs: [build-app-image, scout-app-image]
    permissions:
      contents: read
      packages: write
    uses: portainer/github-actions/.github/workflows/publish-chart.yml@<sha> # vX.Y.Z
```

`release.yml` follows the same shape, adding `version`/`pre-release`
`workflow_dispatch` inputs and a terminal `publish-release` job gated on
`!inputs.pre-release`. The inputs must be named exactly `version` (a string,
`X.Y.Z` or `vX.Y.Z`) and `pre-release` (a boolean): `validate.yml`'s
`version` job and `publish-chart.yml` read them from the dispatch event
directly, and fail if either is missing. A two-image repo repeats the `build-image` and `scout`
jobs once per image, and passes each `build-image` call's `image-ref` output
to `publish-github-release.yml`'s `image-refs` list.

## Chart versions and dev charts

`publish-chart.yml` never reads `version:` from `Chart.yaml`; it's a
placeholder. Every chart's `appVersion` equals its `version`.

- **Push to `develop` or `release/X.Y`** publishes a dev chart to
  `oci://ghcr.io/portainer/dev-charts/<chart>` at the version that branch
  ships next, derived from the repo's GitHub Releases:
  - `release/X.Y`: the highest release in X.Y with patch + 1 (X.Y.0 if the
    line has no release yet).
  - `develop` in a repo with `release/*` branches: the highest release line
    with minor + 1 and patch 0.
  - `develop` in a repo that releases from `develop`: the latest release
    with patch + 1.
  - A repo with no release and no release branch falls back to
    `Chart.yaml`'s version.

  Every push until the next release or pre-release overwrites that same
  version, so Portainer shows no upgrade in between: restart the pods to
  pick up a newer image, and repair or reinstall to pick up chart changes.
- **Pre-release dispatch** publishes a dev chart at the dispatched version,
  annotated `dev-charts.portainer.io/pre-release: "true"`. A later push
  never overwrites it: the derived version steps to the next patch instead.
- **Real release dispatch** publishes to
  `oci://ghcr.io/portainer/charts/<chart>`, the only mode allowed to.

Dev charts (push and pre-release) pull the CI image built in the same run:
every `repository: portainer/<image>` in `values.yaml` is rewritten to
`portainerci/<image>`, with that image's `tag` set to what the run pushed
(`develop`, `X.Y`, or the pre-release `X.Y.Z`). Release charts are packaged
untouched and pull `portainer/<image>:X.Y.Z` through `appVersion`. Both
edits happen on a staged copy on the runner, never in the repo.

The `dev-charts.portainer.io/` annotation prefix is reserved for dev-only
metadata and never reaches `charts/`: `validate / helm` flags it in a PR,
`publish-chart.yml` fails if the repo's `Chart.yaml` carries it, and
`package-and-push-chart` refuses to push a chart carrying it anywhere except
a pre-release to `dev-charts`.

On a release or pre-release dispatch, `validate / version` fails before
anything is built or pushed unless the version is `X.Y.Z`, is on the branch's
line (when dispatched from `release/X.Y`), and is higher than the highest
release in its line. A real release additionally needs no existing GitHub
Release and no existing chart in `charts/` at that version. A patch on an
older line gets its GitHub Release without being marked latest.

## Versioning and pinning

Releases are tags: `vX.Y.Z`.

- **Consumers SHA-pin**, with the tag as a trailing comment for
  readability: `uses: portainer/github-actions/.github/workflows/x.yml@<sha> # vX.Y.Z`.
- **This repo's own internal references stay tag-pinned** to the tag it's
  releasing as (`@vX.Y.Z`, never a SHA) — a workflow can't reference a SHA
  of its own commit, since that hash would have to include itself.
- `scripts/pin-internal-refs.py` keeps that in sync mechanically:
  ```
  python3 scripts/pin-internal-refs.py bump vX.Y.Z    # rewrite every internal ref
  python3 scripts/pin-internal-refs.py verify vX.Y.Z  # fail if any ref doesn't match, before pushing the tag
  ```
  Run `bump` to prepare the commit, `verify` right before pushing the tag.

## Consuming this in a new repo

1. Start from the worked example above and set `image-name` and
   `app-repositories` for your repo.
2. Repo secrets needed: a GitHub App ID and private key (passed as
   `app-id`/`app-private-key`), used to mint a read-only token for checking
   out any private submodules, plus container registry credentials (passed
   as `registry-username`/`registry-password`). The secret names in the
   example are placeholders; use whatever your repo already defines.
3. One-time repo setup: install the GitHub App on this repo and on every
   repo listed in `app-repositories`, and give the repo access to a runner
   labelled `ubuntu-latest-arm64` (`build-image.yml`'s arm64 leg runs
   there). Workflows triggered by Dependabot only receive Dependabot
   secrets, not Actions secrets, so also add matching Dependabot secrets
   (repo Settings → Secrets → Dependabot) if Dependabot PRs should get a
   working CI run.
4. `chart/Chart.yaml`'s `name:` must match `image-name` — the chart's OCI
   push path is derived from it, not from an input.
