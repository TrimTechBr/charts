# TrimTechBR Helm charts

| Chart | What it installs | Where it goes |
|---|---|---|
| [`azure-estate-portal`](charts/azure-estate-portal) | The portal: API, sync worker and web UI | One cluster, yours |
| [`azure-estate-agent`](charts/azure-estate-agent) | The workload agent | Every AKS cluster you want to inventory from the inside |

The two are separate on purpose. The agent goes into clusters the portal cannot
reach — every AKS API server in a real estate is private — and it carries a
cluster-wide read role that has no business being part of a portal install.

## Installing

The packages are private while the product is. Log in once:

```bash
echo "$GITHUB_TOKEN" | helm registry login ghcr.io --username "$GITHUB_USER" --password-stdin
```

Then:

```bash
helm install estate oci://ghcr.io/trimtechbr/charts/azure-estate-portal \
  --namespace estate --create-namespace \
  --values my-values.yaml
```

Each chart's README has the values that matter and what breaks without them.

### The images are private too

Until the packages are public, every cluster needs a pull secret:

```bash
kubectl -n estate create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username="$GITHUB_USER" \
  --docker-password="$GITHUB_TOKEN"    # a PAT with read:packages
```

and `image.pullSecrets: [{name: ghcr}]` in your values.

## Releasing

There is no release tag to remember. Bump `version` in the chart's `Chart.yaml`,
merge to `main`, and CI publishes that version and signs it. A version the
registry already has is skipped rather than overwritten — republishing a number
someone already installed would change what that number means.

`appVersion` tracks the product and moves with its releases; `version` is the
chart's own and moves whenever the chart changes, including when only a template
does.

## Verifying a signature

Charts are signed with cosign, keyless, against the workflow's own identity:

```bash
cosign verify ghcr.io/trimtechbr/charts/azure-estate-portal:0.1.0 \
  --certificate-identity-regexp 'https://github.com/TrimTechBr/charts/.github/workflows/charts.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Working on the charts

```bash
helm lint charts/azure-estate-portal --values charts/azure-estate-portal/ci/default-values.yaml
helm template estate charts/azure-estate-portal --values charts/azure-estate-portal/ci/default-values.yaml
```

The files under each chart's `ci/` are what CI renders and validates. They are
not examples to copy — a pipeline has no secret to point at, so they pass
credentials inline where a real install should use `existingSecret`.

CI also asserts that the charts still **refuse** the configurations that cannot
work. Those refusals exist so a mistake fails at `helm install` rather than as a
crash-looping pod an hour later, and a guard that quietly stopped firing would be
invisible without that test.
