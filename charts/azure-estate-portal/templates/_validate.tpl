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

{{- if gt (int .Values.worker.replicaCount) 1 -}}
{{- fail "\n\nworker.replicaCount must be 1.\n\nThe worker claims sync runs from a queue in the database. A second replica races\nfor the same run and both collect the same estate twice.\n" -}}
{{- end -}}
{{- end -}}
