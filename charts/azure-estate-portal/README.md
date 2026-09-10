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

## Scaling

The API and the UI are autoscaled on CPU by default; the worker is not, and cannot
be. It claims sync runs from a queue in the database, so a second replica races the
first for the same run and collects the same estate twice -- and a sync pegs the
CPU, which makes load the one signal certain to scale it up at the worst moment.
The chart refuses `worker.autoscaling.enabled` rather than accepting it silently.

```yaml
api:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
    targetCPUUtilizationPercentage: 70
```

`minReplicas` is the floor while this is on; `replicaCount` applies only when it is
off. The Deployment then omits `replicas` entirely, because a value there is written
back on every `helm upgrade` and would undo whatever the autoscaler had decided.

**Requires metrics-server** in the cluster -- AKS ships it. Without it the HPA
reports `<unknown>` and holds at `minReplicas`, so nothing breaks, nothing scales.

Memory targets are available and off by default. Think before turning one on: the
.NET GC grows the heap toward the limit and does not hand it back, so memory reads
as permanently high and the autoscaler ratchets up and never comes back down.

## Azure identity

Two paths, and the chart refuses both at once -- `DefaultAzureCredential` reads
the environment before it tries workload identity, so a client secret would
silently win and the federated credential would never be used.

**On AKS** (default). The managed identity needs a federated credential naming
this cluster's OIDC issuer and this service account:

```
system:serviceaccount:<namespace>:<release>-azure-estate-portal-api
system:serviceaccount:<namespace>:<release>-azure-estate-portal-worker
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
| `api.autoscaling.enabled` | `true` | HPA on CPU, 2 to 6 replicas. Needs metrics-server. |
| `webapp.autoscaling.enabled` | `true` | HPA on CPU, 2 to 4 replicas. |
| `api.pdb.maxUnavailable` | `1` | One pod out at a time during a drain. `minAvailable` instead, if you want a floor. |
| `serviceAccount.create` | `true` | One account per Deployment. There is no name override. |

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
- more than one worker replica, or any attempt to autoscale it
- a disruption budget that permits no disruption at all
- `serviceAccount.name`, which no longer exists
- an autoscaler on a component whose CPU request was removed, or with minReplicas
  above maxReplicas

## Service accounts

One per Deployment: `<release>-azure-estate-portal-api`, `-worker` and `-webapp`.

A federated credential binds to a single namespace/serviceaccount subject, so a
shared account means all three authenticate as the same Azure identity and none
can be revoked without the others. The UI gets an account with no Azure
annotations at all, which is what it should have: it is a static bundle served by
nginx and never calls Azure. Before this it ran as the namespace `default`
account, which is whatever anyone else has attached to it.

The API and the worker each carry `azure.workload.identity/client-id` and, when
`azure.tenantId` is set, `tenant-id`. The tenant annotation is omitted rather than
written empty: without it the webhook falls back to the tenant the cluster's
workload identity add-on was installed with, which is right up until the identity
lives in a different tenant.

> **Coming from a chart before 0.2.3, create the federated credentials first.**
> The account names are new, so the credential pointing at the old shared
> `<release>-azure-estate-portal` matches nothing and both components fail their
> first Azure call. One credential covers one subject, so both are needed.

## Disruption budgets

`api` and `webapp` each get one, allowing one pod out at a time. It bounds
voluntary disruption -- a node drain, a cluster upgrade, the node autoscaler
compacting nodes -- and does nothing for a node that simply dies, which is what
replicas are for.

The worker has none, deliberately: it runs one replica, and a budget demanding one
available pod on a one-pod Deployment permits no disruption at all. The drain
blocks and the node upgrade hangs until someone finds the PDB and deletes it. The
chart refuses that shape for the other two as well -- `maxUnavailable: 0`, or a
`minAvailable` at or above the replica floor.

## Upgrading

```bash
helm upgrade estate oci://ghcr.io/trimtechbr/charts/azure-estate-portal \
  --namespace estate --reuse-values --version <chart version>
```

The API creates and migrates its own schema on boot. The worker rolls with
`Recreate` rather than `RollingUpdate`: a sync run is claimed from a queue and
takes tens of minutes, so two workers alive at once during a rollout would both
hold a claim on the estate.
