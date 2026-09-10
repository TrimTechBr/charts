{{/*
Chart name, overridable.
*/}}
{{- define "estate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Release-qualified name. Kubernetes caps names at 63 characters and every
component appends its own suffix, so this leaves room for it.
*/}}
{{- define "estate.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 55 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 55 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 55 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "estate.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "estate.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: azure-estate-portal
{{- end -}}

{{- define "estate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "estate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-component selector. Takes a dict with "root" and "component".
*/}}
{{- define "estate.componentSelectorLabels" -}}
{{ include "estate.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "estate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "estate.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
An image reference. Takes a dict with "root" and "component".
The tag falls back to appVersion so the chart and the product it installs cannot
drift by accident.
*/}}
{{- define "estate.image" -}}
{{- $img := .root.Values.image -}}
{{- $tag := default .root.Chart.AppVersion $img.tag -}}
{{- printf "%s/%s/%s:%s" $img.registry $img.repository .component $tag -}}
{{- end -}}

{{/*
The secret holding the database connection string, and the key inside it.
*/}}
{{- define "estate.dbSecretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else -}}
{{- printf "%s-db" (include "estate.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "estate.dbSecretKey" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecretKey -}}
{{- else -}}
connectionString
{{- end -}}
{{- end -}}

{{- define "estate.clientSecretName" -}}
{{- if .Values.azure.clientSecret.existingSecret -}}
{{- .Values.azure.clientSecret.existingSecret -}}
{{- else -}}
{{- printf "%s-azure" (include "estate.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "estate.clientSecretKey" -}}
{{- if .Values.azure.clientSecret.existingSecret -}}
{{- .Values.azure.clientSecret.existingSecretKey -}}
{{- else -}}
clientSecret
{{- end -}}
{{- end -}}

{{/*
What the browser calls. Derived from the ingress host when not set, which is
right whenever the UI and the API share a hostname.
*/}}
{{- define "estate.apiBaseUrl" -}}
{{- if .Values.webapp.apiBaseUrl -}}
{{- .Values.webapp.apiBaseUrl -}}
{{- else if .Values.ingress.enabled -}}
{{- $scheme := ternary "https" "http" .Values.ingress.tls.enabled -}}
{{- printf "%s://%s/" $scheme .Values.ingress.host -}}
{{- else -}}
{{/*
  The first hostname on the route. With several, the UI can only be built for one --
  the others still serve it, and the API calls go to whichever this names. Set
  webapp.apiBaseUrl when that is not the one you want.

  The ingress wins when both are on, because during a migration the ingress is the
  hostname that already has DNS.
*/}}
{{- $scheme := ternary "https" "http" .Values.httpRoute.tls -}}
{{- printf "%s://%s/" $scheme (first .Values.httpRoute.hostnames) -}}
{{- end -}}
{{- end -}}

{{/*
The environment both the API and the worker need to reach the database and Azure.
*/}}
{{- define "estate.backendEnv" -}}
- name: ConnectionStrings__EstateDb
  valueFrom:
    secretKeyRef:
      name: {{ include "estate.dbSecretName" . }}
      key: {{ include "estate.dbSecretKey" . }}
{{- if .Values.azure.clientSecret.enabled }}
{{/*
DefaultAzureCredential reads these three before it tries workload identity, so
setting them is the whole of the non-AKS path -- no application change.
*/}}
- name: AZURE_TENANT_ID
  value: {{ .Values.azure.tenantId | quote }}
- name: AZURE_CLIENT_ID
  value: {{ .Values.azure.clientSecret.clientId | quote }}
- name: AZURE_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "estate.clientSecretName" . }}
      key: {{ include "estate.clientSecretKey" . }}
{{- end }}
{{- end -}}

{{/*
Pod labels. Workload identity is opted into per pod, not per namespace.
*/}}
{{- define "estate.backendPodLabels" -}}
{{- if .Values.azure.workloadIdentity.enabled }}
azure.workload.identity/use: "true"
{{- end }}
{{- end -}}
