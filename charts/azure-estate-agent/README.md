# azure-estate-agent

Reports Kubernetes workloads from inside an AKS cluster to an Azure Estate
Portal.

**The traffic is outbound only.** The portal never opens a connection to this
cluster, which is why a private API server does not matter — and why there is no
kubeconfig to store anywhere. The agent authenticates to its own cluster with the
ServiceAccount token the kubelet projects into it, and to the portal with a
per-cluster key the portal holds only as a hash.

## Two workloads, and why

| | Alive | Can do |
|---|---|---|
| `…-scan` (CronJob) | seconds a day | read every namespace, pod, node and workload |
| `…-listener` (Deployment) | always | create a Job in its own namespace, and nothing else |

The pod that runs permanently **cannot read a single workload**. The cluster-wide
read exists only while the ephemeral scan job is up.

The listener exists because nothing outside a private cluster can reach in to
start anything: someone pressing "Scan now" in the portal cannot open a
connection here, so the cluster asks.

## Installing

Generate the key in the portal under **Kubernetes → Clusters → Install agent**.
It is shown once — only its hash is stored.

```bash
kubectl create namespace estate-agent

kubectl -n estate-agent create secret generic estate-agent-key \
  --from-literal=apiKey='<the key>'

helm install estate-agent oci://ghcr.io/trimtechbr/charts/azure-estate-agent \
  --namespace estate-agent \
  --values agent-values.yaml
```

with:

```yaml
portal:
  url: https://estate.example.com
  clusterId: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<cluster>
  existingSecret: estate-agent-key
```

Then turn collection on in the portal — it is off by default:

```
Kubernetes__CollectWorkloads=true
```

Without that, the portal ignores everything the agents push.

> **Use a values file for `clusterId`, not `--set`.** On Git Bash and MSYS a
> value starting with `/` is rewritten into a Windows path, and
> `/subscriptions/...` silently becomes `C:/Program Files/Git/subscriptions/...`.
> The portal then answers 403, because the payload names a cluster the key does
> not belong to. `MSYS_NO_PATHCONV=1` also works.

## First collection

The CronJob runs at 03:17 UTC. To not wait:

```bash
CRON=$(kubectl -n estate-agent get cronjob -o name | head -1)
kubectl -n estate-agent create job --from="$CRON" first-scan
kubectl -n estate-agent logs job/first-scan
```

Or press **Scan now** in the portal; the listener picks it up within 60 seconds.

The data appears on the portal's **next sync**, not immediately. The payload is
staged and a sync run consumes it, so a snapshot stays the picture of one instant
rather than a mix of whenever each cluster happened to report.

## Secrets

`rbac.secretMetadata` is `false`, and that is not caution for its own sake:
**Kubernetes RBAC has no metadata-only verb.** Granting `list` on Secrets grants
reading their values. The agent asks the API server for `PartialObjectMetadata`
so values are stripped before they reach it, and the portal has no field to store
them in — but that is the agent behaving, not the cluster preventing.

Turning it on buys one thing: finding Secrets that no workload uses.

Without it you still get which Secrets **are** used — that comes from pod specs
and needs no permission on the Secrets at all. Only the "exists and nobody uses
it" half is missing, and the portal says so rather than showing zero.

## Values worth knowing

| Key | Default | |
|---|---|---|
| `portal.url` | `""` | Required. Must be reachable outbound from this cluster. |
| `portal.clusterId` | `""` | Required. The ARM resource id of *this* cluster. |
| `portal.existingSecret` | `""` | Preferred. A secret you create, holding the key. |
| `portal.apiKey` | `""` | Inline alternative. Stored in the release and printed by `helm get values`. |
| `scan.schedule` | `17 3 * * *` | The portal treats a payload under 26 hours old as on schedule. |
| `scan.maxPods` | `2000` | Pods included in a payload. Every count is rolled up over *all* pods first, so lowering it costs detail, never accuracy. |
| `listener.enabled` | `true` | Off means scans only ever run on the schedule. |
| `listener.pollSeconds` | `60` | How long "Scan now" waits before anything happens. |
| `rbac.secretMetadata` | `false` | Read the section above first. |
| `image.pullSecrets` | `[]` | Required while the package is private. |

## When nothing arrives

```bash
kubectl -n estate-agent logs job/<the scan job>
```

| | |
|---|---|
| `401` | the key is not registered, or was revoked in the portal |
| `403` | `portal.clusterId` names a different cluster than the key belongs to |
| `413` | the payload is over the portal's limit — lower `scan.maxPods` |
| `400` | the portal is older than this agent — upgrade the portal |
| `Agent__ApiKey is not set` | the secret is not mounted; check `portal.existingSecret` |
| nothing at all | check this cluster can reach `portal.url` outbound |

The portal's own **Kubernetes → Clusters** page distinguishes an agent that never
reported from one that reported and went quiet.

## Uninstalling

```bash
helm uninstall estate-agent --namespace estate-agent
```

Revoke the key in the portal as well, under **Kubernetes → Clusters → Revoke**.
That also discards the cluster's staged payload, so a revoked agent's last push
cannot keep appearing in new sync runs.
