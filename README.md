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
| `validate.yml` | once per repo | lint, test, build, secret scan, Helm chart lint/render |
| `build-image.yml` | once **per image** | builds every arch, pushes by digest, assembles the multi-arch tag |
| `scout.yml` | once **per image** | Docker Scout vulnerability scan |
| `publish-chart.yml` | once per repo | packages and pushes the Helm chart |
| `publish-github-release.yml` | once per repo, release path only | creates the GitHub Release, marks it latest |

`ci.yml` and `release.yml` end up structurally identical across every
consumer — same blocks, same order — differing only in which inputs they
pass. A `pre-release` boolean on `release.yml` (not a separate trigger file)
picks the registry namespace/chart registry and whether a GitHub Release
gets created at all.

The composite actions under `.github/actions/` (`resolve-image-tag`,
`checkout-with-submodules`, `package-and-push-chart`, `docker-scout-scan`,
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
`!inputs.pre-release`. A two-image repo repeats the `build-image` and `scout`
jobs once per image, and passes each `build-image` call's `image-ref` output
to `publish-github-release.yml`'s `image-refs` list.

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
