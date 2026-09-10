# azure-estate-portal

Discovery, analysis and observability reporting for Azure environments. Installs
three components -- the API, the sync worker and the web UI -- behind one hostname.

## Before you install

**PostgreSQL.** Required, and not bundled. The API and the worker are separate
deployments that both write, so a file database would need shared writable
storage and would corrupt under two writers. Any reachable PostgreSQL will do,
including Azure Database for PostgreSQL.

**An ingress controller**, or your own gateway. The UI runs in a browser, so it
needs a URL a browser can reach; a cluster-internal service name will not do.

**An Azure identity** with, on the subscriptions or management groups in scope:

- `Reader`
- `Monitoring Reader`
- `AcrPull`, per container registry you want inventoried from the inside

## Installing

```bash
kubectl create namespace estate

kubectl -n estate create secret generic estate-db \
  --from-literal=connectionString='Host=pg.example.com;Database=estate;Username=estate;Password=...'

helm install estate oci://ghcr.io/trimtechbr/charts/azure-estate-portal \
  --namespace estate \
  --set database.existingSecret=estate-db \
  --set azure.tenantId=<tenant> \
  --set azure.workloadIdentity.clientId=<managed identity client id> \
  --set ingress.host=estate.example.com \
  --set ingress.tls.enabled=true
```

## One hostname, on purpose

The UI is served at `/` and the API at `/api`, on the same host. The browser
therefore never makes a cross-origin request, and there is no CORS configuration
that can be wrong -- which is the failure that shows up as a blank screen with
nothing in the logs.

This works without a rewrite because the API already serves everything it has
under `/api`. Add more paths if you want them published:

```yaml
ingress:
  apiPaths:
    - /api
    - /swagger     # the API explorer
```

## Gateway API instead of Ingress

The same routing, as an `HTTPRoute`:

```yaml
ingress:
  enabled: false
httpRoute:
  enabled: true
  parentRefs:
    - name: shared-gateway
      namespace: gateway-system
      sectionName: https      # the listener, when the Gateway has more than one
  hostnames:
    - estate.example.com
  tls: true                   # whether the Gateway terminates TLS, so the UI knows the scheme
```

Off by default: it needs the Gateway API CRDs installed and a Gateway to attach to,
and a cluster without them would fail the install rather than skip the object.

**Both can be on at once**, deliberately. Migrating from Ingress to Gateway API means
running the two side by side while DNS moves, and a chart that forced the choice would
make the safe migration the one you cannot express. While both are on, the UI is built
for the ingress hostname, because that is the one that already has DNS.

> **A Gateway in another namespace needs a `ReferenceGrant` there**, allowing this
> namespace to attach. The chart cannot create it -- it belongs to whoever owns the
> Gateway -- and an HTTPRoute without one is accepted and never programmed. It reads as
> a routing bug and is a permission.

If you publish the two on different hostnames instead, set
`webapp.apiBaseUrl` and add the UI's origin to the API's CORS list through
`config.extra`:

```yaml
config:
  extra:
    Cors__AllowedOrigins__0: https://estate.example.com
```

## Azure identity

Two paths, and the chart refuses both at once -- `DefaultAzureCredential` reads
the environment before it tries workload identity, so a client secret would
silently win and the federated credential would never be used.

**On AKS** (default). The managed identity needs a federated credential naming
this cluster's OIDC issuer and this service account:

```
system:serviceaccount:<namespace>:<release>-azure-estate-portal
```

```yaml
azure:
  tenantId: <tenant>
  workloadIdentity:
    enabled: true
    clientId: <managed identity client id>
```

**Anywhere else.** A service principal, read straight from the environment:

```yaml
azure:
  tenantId: <tenant>
  workloadIdentity:
    enabled: false
  clientSecret:
    enabled: true
    clientId: <app registration client id>
    existingSecret: estate-azure     # key: clientSecret
```

## Values worth knowing

| Key | Default | |
|---|---|---|
| `database.existingSecret` | `""` | Preferred. A secret you manage, so the connection string never reaches `helm get values`. |
| `database.connectionString` | `""` | Inline alternative. Stored in the release. |
| `azure.workloadIdentity.clientId` | `""` | Required on AKS. |
| `ingress.host` | `estate.example.com` | Required unless the ingress is disabled. |
| `httpRoute.enabled` | `false` | Gateway API instead of, or alongside, the ingress. |
| `httpRoute.parentRefs[0].name` | `""` | Required when enabled -- the Gateway to attach to. |
| `ingress.apiPaths` | `[/api]` | What the API serves through the ingress. |
| `webapp.apiBaseUrl` | derived | What the browser calls. Only set it when the UI and API are on different hosts. |
| `webapp.azureAd.*` | `""` | Sign-in for the UI (MSAL). Separate from `azure.*`, which is how the worker reads Azure -- possibly a different tenant. |
| `config.collectKubernetesWorkloads` | `false` | Needs the agent chart installed in each cluster. |
| `config.collectAcrDataPlane` | `true` | Registry contents. Needs `AcrPull` per registry. |
| `config.extra` | `{}` | Any other setting, as ASP.NET configuration keys: `Metrics__WindowDays: "14"`. |
| `image.pullSecrets` | `[]` | Required while the packages are private. |
| `worker.replicaCount` | `1` | Fixed at one. A second worker races the first for the same queued run. |

## What the chart refuses

Each of these would otherwise install cleanly and fail later, when nobody is
watching the terminal:

- no database configured
- both Azure identity paths enabled
- workload identity without a client id
- nothing publishing the portal and no `webapp.apiBaseUrl`
- an HTTPRoute with no Gateway to attach to, or with no hostname -- one attaches to
  every hostname its Gateway serves, which would put the portal on hostnames meant
  for other applications
- more than one worker replica

## Upgrading

```bash
helm upgrade estate oci://ghcr.io/trimtechbr/charts/azure-estate-portal \
  --namespace estate --reuse-values --version <chart version>
```

The API creates and migrates its own schema on boot. The worker rolls with
`Recreate` rather than `RollingUpdate`: a sync run is claimed from a queue and
takes tens of minutes, so two workers alive at once during a rollout would both
hold a claim on the estate.
