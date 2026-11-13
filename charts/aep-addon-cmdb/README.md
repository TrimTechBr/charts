# aep-addon-cmdb

The CMDB add-on for the Azure Estate Portal: systems, the configuration items
they are made of, and the relations between them -- discovered from what the
portal already collects, and edited from inside the portal's own UI.

**The portal collects, the CMDB consumes.** The CMDB never calls Azure and holds
no Azure RBAC. Its worker reads everything through the portal's read-only add-on
API (`/api/addons/v1`), with a token for the portal's `AEP.AddOn` app role.

## What it installs

| | |
|---|---|
| `...-api` (Deployment + Service) | The CMDB API. Also serves `manifest.json` and the UI assemblies the portal downloads at runtime. Creates the schema on its first start. |
| `...-worker` (Deployment, always 1 replica) | The discovery worker. Polls the portal for a new completed sync and mirrors, discovers and proposes. Serves no HTTP. |
| Ingress and/or HTTPRoute | One path, `pathPrefix` (default `/addons/cmdb`), **on the portal's hostname**, to the API. |
| two ServiceAccounts | The worker's carries the workload identity annotations; the API's carries none. |

Published on the portal's host on purpose: the portal's UI loads the add-on from
its own origin, so the browser makes no cross-origin request and there is no CORS
to configure. The portal keeps `/` and `/api`; this chart adds only `pathPrefix`,
and longest-prefix matching sends it here. The add-on's *pages* appear in the UI
under `/apps/cmdb/` -- a different prefix, so reloading a deep link reaches the
portal's UI and not this API.

## Prerequisites

The portal chart (`azure-estate-portal` 0.3.0 or later) installed, on a portal
that has the add-on API. Then:

1. **A PostgreSQL database of its own** -- not the portal's. The API creates the
   tables on first start; the role only needs to own that database.

   ```bash
   kubectl -n estate create secret generic cmdb-db \
     --from-literal=connectionString='Host=...;Database=cmdb;Username=cmdb;Password=...'
   ```

2. **An app registration for the CMDB API.** Either its own, or the portal's with
   two roles added -- the code does not care, and `auth.apiScope` (or the
   default `api://<auth.clientId>/access_as_user`) tells the portal's UI which
   scope to request.
   - Expose an API: Application ID URI `api://<client id>`, scope `access_as_user`
   - App roles `CMDB.Reader` and `CMDB.Operator` (users/groups)
   - Assign users or groups to them on its enterprise application
   - With a registration of its own: grant the portal's SPA registration the
     delegated permission `access_as_user` on it

3. **A user-assigned managed identity for the worker**, holding the portal's
   `AEP.AddOn` app role, with a federated credential for the worker's
   ServiceAccount. The role is an application permission, so it is assigned with
   Graph rather than in the portal blade:

   ```bash
   MI_PRINCIPAL=$(az identity show -g <rg> -n <identity> --query principalId -o tsv)
   AEP_SP=$(az ad sp show --id <portal api client id> --query id -o tsv)
   ROLE_ID=$(az ad sp show --id <portal api client id> \
     --query "appRoles[?value=='AEP.AddOn'].id" -o tsv)

   az rest --method POST \
     --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$AEP_SP/appRoleAssignedTo" \
     --body "{\"principalId\":\"$MI_PRINCIPAL\",\"resourceId\":\"$AEP_SP\",\"appRoleId\":\"$ROLE_ID\"}"

   az identity federated-credential create -g <rg> --identity-name <identity> \
     --name aep-addon-cmdb-worker \
     --issuer "$(az aks show -g <aks rg> -n <cluster> --query oidcIssuerProfile.issuerUrl -o tsv)" \
     --subject system:serviceaccount:<namespace>:<release>-aep-addon-cmdb-worker \
     --audiences api://AzureADTokenExchange
   ```

   The subject must name the worker's account exactly -- `NOTES.txt` prints it
   after the install. A token issued before the role assignment does not carry the
   role; the worker picks up a fresh one within the hour, or on a restart.

## Installing

```bash
helm install cmdb oci://ghcr.io/trimtechbr/charts/aep-addon-cmdb \
  --namespace estate \
  --values cmdb-values.yaml
```

with:

```yaml
database:
  existingSecret: cmdb-db
auth:
  tenantId: <tenant id>
  clientId: <CMDB API client id>
aep:
  # The portal's API Service, cluster-internal, the root of it.
  apiUrl: http://estate-azure-estate-portal-api.estate.svc.cluster.local/
  # The portal's API registration (api.auth.clientId of the portal chart).
  scope: api://<portal api client id>/.default
ingress:
  className: <the portal Ingress's class>
  host: estate.example.com          # the portal's hostname
  tls:
    enabled: true
    secretName: <the portal's certificate secret>
worker:
  workloadIdentity:
    clientId: <managed identity client id>
```

Then tell the portal about it -- nothing appears in its menu until then. Add to
the **portal chart's** values and upgrade it:

```yaml
addons:
  - id: cmdb
    manifestUrl: /addons/cmdb/manifest.json   # pathPrefix + /manifest.json
```

The portal lists the add-on under **Operations -> Add-ons**, with the reason if it
did not load.

> **Use a values file for `pathPrefix` and `aep.apiUrl`, not `--set`, on Git Bash.**
> MSYS rewrites an argument starting with `/` into a Windows path, so
> `--set pathPrefix=/addons/cmdb` arrives as `C:/Program Files/Git/addons/cmdb`
> -- which the chart refuses. `MSYS_NO_PATHCONV=1` also works.

## Values worth knowing

| Key | Default | |
|---|---|---|
| `database.existingSecret` | `""` | Preferred. A secret holding the connection string. |
| `database.connectionString` | `""` | Inline alternative. Stored in the release and printed by `helm get values`. |
| `auth.tenantId`, `auth.clientId` | `""` | Required. -> `AzureAd__TenantId`, `AzureAd__ClientId`. |
| `auth.audience` | `""` | An extra accepted audience. -> `AzureAd__Audience`. |
| `auth.apiScope` | `""` | The scope the portal's UI requests. Empty: `api://<clientId>/access_as_user`. -> `Cmdb__ApiScope`. |
| `aep.apiUrl` | `""` | Required. The portal's API, from inside the cluster. -> `Aep__BaseUrl`. |
| `aep.scope` | `""` | Required. `api://<portal api client id>/.default`. -> `Aep__Scope`. |
| `pathPrefix` | `/addons/cmdb` | The route and the API's path base. -> `Cmdb__PathBase`. |
| `ingress.host` | `""` | Required with the ingress. The portal's hostname. |
| `httpRoute.*` | off | The same path as an HTTPRoute, on the portal's Gateway. |
| `worker.workloadIdentity.clientId` | `""` | Required while workload identity is on. |
| `config.discoveryPollSeconds` | `60` | How often the worker checks the portal. The liveness window follows it. |
| `config.appMapMinCalls` | `10` | Application Map edges with fewer calls are ignored. |
| `config.appMapStaleAfterDays` | `14` | Unseen days before removing an Application Map relation is proposed. |
| `config.extra` | `{}` | Any other setting, e.g. `Cmdb__EnvironmentAliases__production: prd`. |

## What the chart refuses, and why

Each of these would install cleanly and fail later. The chart fails at
`helm install` instead, with a message naming the value to set.

| Refused | Because |
|---|---|
| no `database.existingSecret` and no `database.connectionString` | Both pods need the database; SQLite corrupts under two writers. |
| `auth.tenantId` or `auth.clientId` empty | The API fails closed: it will not start without them. |
| `aep.apiUrl` empty or not an absolute http(s) URL | The worker refuses to start without it. |
| `aep.scope` empty | The worker would call the portal with no token, and get 401 on every pass. |
| `worker.workloadIdentity.clientId` empty while enabled | The worker would have no token for the portal. |
| `pathPrefix` not of the form `/a/b`, or under `/api` or `/apps` | It shares the portal's hostname: `/`, `/api` and `/apps` belong to the portal, and a trailing `/` breaks the manifest URL. |
| `ingress.host` empty while the ingress is on | There is no hostname to put the path on. |
| `httpRoute` on without `parentRefs[0].name` or a hostname | A route with no hostname attaches to every hostname on the Gateway. |
| `worker.replicaCount` above 1, `worker.autoscaling.enabled` | A pass plans against the database as it found it; a second worker would plan against the first. |

## When something is wrong

| Where | What it means |
|---|---|
| Add-ons page in the portal: manifest unreachable | `ingress.host`/`className` do not match the portal's, or the portal's `addons` entry has another URL |
| API pod crash-loops at start | `AzureAd__*` missing (the guard prevents it) or the database unreachable -- `kubectl logs` |
| API not ready | `/health/ready` reads the database; 503 means it cannot |
| worker logs `401` | `aep.scope` names the wrong registration, or the identity lacks `AEP.AddOn` |
| worker logs `AADSTS70021` / no matching federated identity | the federated credential's subject or issuer does not match |
| worker logs `refuse ... major` or a missing capability | the portal is older than this add-on -- upgrade the portal |

## Uninstalling

```bash
helm uninstall cmdb --namespace estate
```

Remove the `addons` entry from the portal's values as well, or its Add-ons page
keeps reporting a manifest it cannot reach. The database is not touched.
