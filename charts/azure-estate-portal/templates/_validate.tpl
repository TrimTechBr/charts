{{/*
Configuration that cannot work, refused at render time.

Every one of these would otherwise install cleanly and fail later — a pod that
crash-loops on its first database call, or a UI that loads and then cannot reach
anything. Failing here puts the reason in front of whoever ran helm install,
which is the only moment someone is watching.

Included from configmap.yaml, which always renders. A file whose name starts with
an underscore is only evaluated when included, so validations left at its top
level would never run.
*/}}
{{- define "estate.validate" -}}

{{- if and (not .Values.database.existingSecret) (not .Values.database.connectionString) -}}
{{- fail "\n\nA PostgreSQL connection string is required.\n\n  Preferred — a secret you manage:\n    kubectl create secret generic estate-db --from-literal=connectionString='Host=...;Database=...;Username=...;Password=...'\n    --set database.existingSecret=estate-db\n\n  Or, for a first install:\n    --set database.connectionString='Host=...;Database=...;Username=...;Password=...'\n\nSQLite is not an option here: the API and the worker are separate deployments\nthat both write, and a file database corrupts under two writers.\n" -}}
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

{{- if and (not .Values.ingress.enabled) (not .Values.webapp.apiBaseUrl) -}}
{{- fail "\n\nwebapp.apiBaseUrl is required when the ingress is disabled.\n\nThe UI runs in a browser, so it needs a URL the browser can reach — a\ncluster-internal service name will not do. With the chart's ingress this is\nderived from ingress.host; without it, say what it is.\n" -}}
{{- end -}}

{{- if gt (int .Values.worker.replicaCount) 1 -}}
{{- fail "\n\nworker.replicaCount must be 1.\n\nThe worker claims sync runs from a queue in the database. A second replica races\nfor the same run and both collect the same estate twice.\n" -}}
{{- end -}}
{{- end -}}
