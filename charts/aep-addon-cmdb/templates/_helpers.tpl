{{/*
Chart name, overridable.
*/}}
{{- define "cmdb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Release-qualified name. Kubernetes caps names at 63 characters and every
component appends its own suffix, so this leaves room for it.
*/}}
{{- define "cmdb.fullname" -}}
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

{{- define "cmdb.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "cmdb.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: azure-estate-portal
{{- end -}}

{{- define "cmdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cmdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-component selector. Takes a dict with "root" and "component".
*/}}
{{- define "cmdb.componentSelectorLabels" -}}
{{ include "cmdb.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Per-component account name. Takes a dict with "root" and "component".
No name override: the worker's name is the federated credential's subject, and a
rename is a change on the Azure side too, not a value to flip here.
serviceAccount.create false falls back to the namespace default.
*/}}
{{- define "cmdb.serviceAccountName" -}}
{{- if (index .root.Values .component).serviceAccount.create -}}
{{- printf "%s-%s" (include "cmdb.fullname" .root) .component -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{/*
One image for both processes. The tag falls back to appVersion so the chart and
the add-on it installs cannot drift by accident.
*/}}
{{- define "cmdb.image" -}}
{{- $img := .Values.image -}}
{{- printf "%s/%s:%s" $img.registry $img.repository (default .Chart.AppVersion $img.tag) -}}
{{- end -}}

{{/*
The secret holding the database connection string, and the key inside it.
*/}}
{{- define "cmdb.dbSecretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else -}}
{{- printf "%s-db" (include "cmdb.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "cmdb.dbSecretKey" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecretKey -}}
{{- else -}}
connectionString
{{- end -}}
{{- end -}}

{{/*
The database and the tenant, which the API and the worker both read: the API
validates tokens issued by that tenant, the worker asks it for one.
*/}}
{{- define "cmdb.commonEnv" -}}
- name: ConnectionStrings__CmdbDb
  valueFrom:
    secretKeyRef:
      name: {{ include "cmdb.dbSecretName" . }}
      key: {{ include "cmdb.dbSecretKey" . }}
- name: AzureAd__TenantId
  value: {{ .Values.auth.tenantId | quote }}
{{- end -}}

{{/*
The manifest URL the portal's addons entry needs. Relative on purpose: the
portal resolves it against its own origin, which is the host this chart
publishes on.
*/}}
{{- define "cmdb.manifestUrl" -}}
{{- printf "%s/manifest.json" .Values.pathPrefix -}}
{{- end -}}
