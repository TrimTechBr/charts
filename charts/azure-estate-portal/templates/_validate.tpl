{{/*
Configuration that cannot work, refused at render time.

Every one of these would otherwise install cleanly and fail later -- a pod that
crash-loops on its first database call, or a UI that loads and then cannot reach
anything. Failing here puts the reason in front of whoever ran helm install,
which is the only moment someone is watching.

Included from configmap.yaml, which always renders. A file whose name starts with
an underscore is only evaluated when included, so validations left at its top
level would never run.
*/}}
{{- define "estate.validate" -}}

{{- if and (not .Values.database.existingSecret) (not .Values.database.connectionString) -}}
{{- fail "\n\nA PostgreSQL connection string is required.\n\n  Preferred -- a secret you manage:\n    kubectl create secret generic estate-db --from-literal=connectionString='Host=...;Database=...;Username=...;Password=...'\n    --set database.existingSecret=estate-db\n\n  Or, for a first install:\n    --set database.connectionString='Host=...;Database=...;Username=...;Password=...'\n\nSQLite is not an option here: the API and the worker are separate deployments\nthat both write, and a file database corrupts under two writers.\n" -}}
{{- end -}}

{{- if and .Values.azure.workloadIdentity.enabled .Values.azure.clientSecret.enabled -}}
{{- fail "\n\nazure.workloadIdentity.enabled and azure.clientSecret.enabled are both on.\n\nDefaultAzureCredential reads the environment before it tries workload identity,\nso the client secret would silently win and the federated identity would never\nbe used. Pick one.\n" -}}
{{- end -}}

{{- if and .Values.azure.workloadIdentity.enabled (not .Values.azure.workloadIdentity.clientId) -}}
{{- fail "\n\nazure.workloadIdentity.clientId is required when workload identity is enabled.\n\nIt is the client id of the user-assigned managed identity whose federated\ncredential names this cluster's OIDC issuer and this service account. Set\nazure.workloadIdentity.enabled=false to use a client secret instead.\n" -}}
{{- end -}}

{{- if .Values.azure.clientSecret.enabled -}}
{{- if not .Values.azure.clientSecret.clientId -}}
{{- fail "azure.clientSecret.clientId is required when azure.clientSecret.enabled is true." -}}
{{- end -}}
{{- if and (not .Values.azure.clientSecret.existingSecret) (not .Values.azure.clientSecret.value) -}}
{{- fail "azure.clientSecret needs either existingSecret or value when enabled." -}}
{{- end -}}
{{- end -}}

{{- if and .Values.ingress.enabled (not .Values.ingress.host) -}}
{{- fail "ingress.host is required when the ingress is enabled." -}}
{{- end -}}

{{- if .Values.httpRoute.enabled -}}
{{/*
  compact on a defaulted list, rather than "first", because "first" dereferences a
  nil list instead of returning nothing: hostnames=null -- which is how you clear a
  list from --set -- crashed the render with a Go nil pointer panic rather than
  printing the message below. compact also catches a list of empty strings.
*/}}
{{- if not (compact (default (list) .Values.httpRoute.hostnames)) -}}
{{- fail "\n\nhttpRoute.hostnames must name at least one hostname.\n\nAn HTTPRoute with none attaches to every hostname its Gateway serves, which would\nput the portal on hostnames meant for other applications.\n" -}}
{{- end -}}
{{- $refs := compact (default (list) .Values.httpRoute.parentRefs) -}}
{{- if or (not $refs) (not (first $refs).name) -}}
{{- fail "\n\nhttpRoute.parentRefs[0].name is required -- the Gateway this route attaches to.\n\n  --set httpRoute.parentRefs[0].name=<gateway> --set httpRoute.parentRefs[0].namespace=<its namespace>\n\nIf the Gateway is in another namespace it also needs a ReferenceGrant there allowing\nthis one to attach. The chart cannot create that, and a route without it is accepted\nand never programmed -- which reads as a routing bug and is a permission.\n" -}}
{{- end -}}
{{- end -}}

{{- if and (not .Values.ingress.enabled) (not .Values.httpRoute.enabled) (not .Values.webapp.apiBaseUrl) -}}
{{- fail "\n\nNothing publishes the portal, and webapp.apiBaseUrl is not set.\n\nThe UI runs in a browser, so it needs a URL the browser can reach -- a\ncluster-internal service name will not do. Turn on ingress.enabled or\nhttpRoute.enabled and the chart derives it; publish the portal with your own\ngateway and say what the URL is.\n" -}}
{{- end -}}

{{- $legacySA := .Values.serviceAccount | default dict -}}
{{/*
  The shared serviceAccount block moved into api/worker/webapp, so that each can
  carry its own annotations. Refused rather than ignored -- settings that are
  silently dropped are the ones you believe are in effect.

  create: true is the exception: it is what the per-component blocks default to,
  so a --reuse-values upgrade carrying it changes nothing and need not fail.
*/}}
{{- if or $legacySA.name $legacySA.annotations (and (hasKey $legacySA "create") (not $legacySA.create)) -}}
{{- fail "\n\nThe shared serviceAccount block no longer exists.\n\nEach Deployment now configures its own, so that annotations can differ:\n\n  api:\n    serviceAccount:\n      create: true\n      annotations: {}\n\nand the same under worker: and webapp:. The accounts are named\n<release>-azure-estate-portal-{api,worker,webapp}; there is no name override,\nbecause the name has to match the federated credential subject.\n" -}}
{{- end -}}

{{- range $component := list "api" "webapp" -}}
{{- $a := (index $.Values $component).autoscaling -}}
{{- if $a.enabled -}}
{{- if gt (int $a.minReplicas) (int $a.maxReplicas) -}}
{{- fail (printf "\n\n%s.autoscaling.minReplicas is above maxReplicas.\n\nThe API server rejects the HorizontalPodAutoscaler, so the deployment installs\nwithout one and stays at whatever replica count it happens to have.\n" $component) -}}
{{- end -}}
{{/*
  A CPU target is a percentage of the request. With no request there is nothing to
  take a percentage of: the HPA reports <unknown>/70%, never scales, and reads as
  a broken autoscaler rather than as missing configuration.
*/}}
{{- if not (dig "requests" "cpu" "" ((index $.Values $component).resources | default dict)) -}}
{{- fail (printf "\n\n%s.autoscaling is on but %s.resources.requests.cpu is not set.\n\nA CPU target is a percentage of the request, so with no request there is nothing\nto take a percentage of. The autoscaler reports <unknown>/%d%% and never scales.\n\nSet the request, or %s.autoscaling.enabled=false.\n" $component $component (int $a.targetCPUUtilizationPercentage) $component) -}}
{{- end -}}
{{- end -}}
{{/*
  A budget that permits no disruption at all does not protect the component, it
  pins it: the drain waits forever, and the node upgrade hangs until someone
  finds the PDB and deletes it by hand. Percentages are handled here too, since
  "0%" and "100%" pin it just as thoroughly as the integers do.
*/}}
{{- $pdb := (index $.Values $component).pdb -}}
{{- if $pdb.enabled -}}
{{- if $pdb.minAvailable -}}
{{- $m := toString $pdb.minAvailable -}}
{{- if hasSuffix "%" $m -}}
{{- if ge (int (trimSuffix "%" $m)) 100 -}}
{{- fail (printf "\n\n%s.pdb.minAvailable is 100%% or more, so no pod may ever be evicted.\n\nA node drain then blocks indefinitely and a cluster upgrade hangs on it, which\nsurfaces as a stuck node rather than as a disruption budget.\n" $component) -}}
{{- end -}}
{{- else -}}
{{- $floor := ternary (int $a.minReplicas) (int (index $.Values $component).replicaCount) $a.enabled -}}
{{- if ge (int $m) $floor -}}
{{- fail (printf "\n\n%s.pdb.minAvailable is at or above the replica floor, so no pod may be evicted.\n\nAt the floor every pod is needed to satisfy the budget, so a node drain blocks\nindefinitely and a cluster upgrade hangs on it. Lower minAvailable, raise the\nfloor, or use maxUnavailable instead.\n" $component) -}}
{{- end -}}
{{- end -}}
{{- else if le (int (trimSuffix "%" (toString $pdb.maxUnavailable))) 0 -}}
{{- fail (printf "\n\n%s.pdb.maxUnavailable is 0, so no pod may ever be evicted.\n\nA node drain then blocks indefinitely and a cluster upgrade hangs on it. Set it\nto 1, or turn the budget off.\n" $component) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  The worker has no autoscaling block. Setting one would otherwise do nothing at
  all, quietly, and someone would go looking for the HPA that never appeared.
*/}}
{{- if (.Values.worker.autoscaling | default dict).enabled -}}
{{- fail "\n\nThe worker cannot be autoscaled.\n\nIt claims sync runs from a queue in the database, so a second replica races the\nfirst for the same run and collects the same estate twice. A sync also pegs the\nCPU, so load is the one signal certain to scale it up at the worst moment.\n\nScale the API instead -- it serves the UI and is what a busy portal is short of.\n" -}}
{{- end -}}

{{/*
  worker.replicaCount is gone from values.yaml, but a --reuse-values upgrade still
  carries the old key, and someone may pass it out of habit. Defaulted so that its
  absence is not a refusal, and still refused above 1 rather than quietly ignored:
  being ignored is how you end up believing you scaled something.
*/}}
{{- if gt (int (.Values.worker.replicaCount | default 1)) 1 -}}
{{- fail "\n\nThe worker runs one replica, and that is not configurable.\n\nIt claims sync runs from a queue in the database, so a second replica races the\nfirst for the same run and both collect the same estate twice. The Deployment\nhardcodes 1; remove worker.replicaCount.\n" -}}
{{- end -}}
{{- end -}}
