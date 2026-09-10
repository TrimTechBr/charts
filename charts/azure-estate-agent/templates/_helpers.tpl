{{- define "agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "agent.fullname" -}}
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

{{- define "agent.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "agent.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: azure-estate-portal
{{- end -}}

{{- define "agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "agent.scanServiceAccountName" -}}
{{- default (printf "%s-scan" (include "agent.fullname" .)) .Values.serviceAccount.scanName -}}
{{- end -}}

{{- define "agent.listenerServiceAccountName" -}}
{{- default (printf "%s-listener" (include "agent.fullname" .)) .Values.serviceAccount.listenerName -}}
{{- end -}}

{{/*
The CronJob the listener instantiates. Both names come from here so they cannot
drift: a listener pointing at a CronJob that does not exist fails only when
somebody presses the button, which is the worst time to find out.
*/}}
{{- define "agent.cronJobName" -}}
{{- printf "%s-scan" (include "agent.fullname" .) -}}
{{- end -}}

{{- define "agent.image" -}}
{{- $img := .Values.image -}}
{{- printf "%s/%s:%s" $img.registry $img.repository (default .Chart.AppVersion $img.tag) -}}
{{- end -}}

{{- define "agent.secretName" -}}
{{- if .Values.portal.existingSecret -}}
{{- .Values.portal.existingSecret -}}
{{- else -}}
{{- printf "%s-key" (include "agent.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "agent.secretKey" -}}
{{- if .Values.portal.existingSecret -}}
{{- .Values.portal.existingSecretKey -}}
{{- else -}}
apiKey
{{- end -}}
{{- end -}}

{{/*
Configuration both modes share. The agent reads everything from the environment,
so this is the whole of its configuration surface.
*/}}
{{- define "agent.env" -}}
- name: Agent__PortalUrl
  value: {{ .Values.portal.url | quote }}
- name: Agent__ClusterId
  value: {{ .Values.portal.clusterId | quote }}
- name: Agent__Namespace
  value: {{ .Release.Namespace | quote }}
- name: Agent__CronJobName
  value: {{ include "agent.cronJobName" . | quote }}
- name: Agent__MaxPods
  value: {{ .Values.scan.maxPods | quote }}
- name: Agent__PollSeconds
  value: {{ .Values.listener.pollSeconds | quote }}
- name: Agent__TimeoutSeconds
  value: {{ .Values.portal.timeoutSeconds | quote }}
- name: Agent__ApiKey
  valueFrom:
    secretKeyRef:
      name: {{ include "agent.secretName" . }}
      key: {{ include "agent.secretKey" . }}
{{- end -}}

{{- define "agent.validate" -}}
{{- if not .Values.portal.url -}}
{{- fail "\n\nportal.url is required.\n\n  --set portal.url=https://estate.example.com\n\nThis cluster must be able to reach it outbound. Nothing connects the other way.\n" -}}
{{- end -}}

{{- if not .Values.portal.clusterId -}}
{{- fail "\n\nportal.clusterId is required -- the ARM resource id of THIS cluster.\n\n  az aks show -g <rg> -n <cluster> --query id -o tsv\n\nA cluster cannot know its own Azure resource id from the inside, and the portal\nrefuses a payload that names a different cluster than the key belongs to.\n" -}}
{{- end -}}

{{- if and (not .Values.portal.existingSecret) (not .Values.portal.apiKey) -}}
{{- fail "\n\nAn agent key is required. Generate one in the portal under Kubernetes -> Clusters;\nit is shown once, because only its hash is stored.\n\n  Preferred -- a secret you create:\n    kubectl create secret generic estate-agent-key --from-literal=apiKey='<key>'\n    --set portal.existingSecret=estate-agent-key\n\n  Or:\n    --set portal.apiKey='<key>'\n" -}}
{{- end -}}
{{- end -}}
