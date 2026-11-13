{{/*
Configuration that cannot work, refused at render time.

Every one of these would otherwise install cleanly and fail later -- an API that
throws before listening, a worker whose every pass is refused by the portal, or a
manifest URL that the portal requests and nothing answers. Failing here puts the
reason in front of whoever ran helm install, which is the only moment someone is
watching.

Included at the top of every template that reads values, not only configmap.yaml.
A file whose name starts with an underscore is only evaluated when included, and
Helm stops at the first template that errors: with the guards in one file, any
other template dereferencing auth.tenantId would hit --set auth=null first and
answer with a nil pointer panic instead of the message below. It is cheap, and the
first template to render reports the reason.

Every read in here goes through dig or a default, for the same reason: --set
auth=null is how a map is cleared from the command line.
*/}}
{{- define "cmdb.validate" -}}
{{- $v := .Values.AsMap -}}

{{- if and (not (dig "database" "existingSecret" "" $v)) (not (dig "database" "connectionString" "" $v)) -}}
{{- fail "\n\nA PostgreSQL connection string for the CMDB's own database is required.\n\n  Preferred -- a secret you manage:\n    kubectl create secret generic cmdb-db --from-literal=connectionString='Host=...;Database=cmdb;Username=...;Password=...'\n    --set database.existingSecret=cmdb-db\n\n  Or, for a first install:\n    --set database.connectionString='Host=...;Database=cmdb;Username=...;Password=...'\n\nA database separate from the portal's: the CMDB creates its own tables and keeps\nits own audit log. SQLite is not an option -- the API and the worker are separate\ndeployments that both write, and a file database corrupts under two writers.\n" -}}
{{- end -}}

{{/*
  The API fails closed: outside Development it throws before listening when either
  id is missing, and there is no setting that turns authentication off.
*/}}
{{- if or (not (dig "auth" "tenantId" "" $v)) (not (dig "auth" "clientId" "" $v)) -}}
{{- fail "\n\nauth.tenantId and auth.clientId are required.\n\nThe CMDB API validates an Entra ID token on every call and will not start\nwithout them. Use an app registration that exposes the scope access_as_user and\nthe app roles CMDB.Reader and CMDB.Operator -- its own, or the portal's with the\ntwo roles added -- then:\n\n  --set auth.tenantId=<tenant id> --set auth.clientId=<client id>\n" -}}
{{- end -}}

{{/*
  The worker refuses to start without an absolute http(s) URL here, and the portal
  is the only place it learns anything from.
*/}}
{{- if not (regexMatch "^https?://[^/]" (toString (dig "aep" "apiUrl" "" $v))) -}}
{{- fail "\n\naep.apiUrl must be the absolute http(s) URL of the portal's API Service.\n\nThe worker reads everything it knows from the portal's add-on API and refuses to\nstart without it. Use the cluster-internal Service, the root of it:\n\n  --set aep.apiUrl=http://<portal release>-azure-estate-portal-api.<namespace>.svc.cluster.local/\n" -}}
{{- end -}}

{{/*
  An empty scope makes the worker send no token at all, which only a portal running
  in Development accepts. Against a real portal every pass would end in 401.
*/}}
{{- if not (dig "aep" "scope" "" $v) -}}
{{- fail "\n\naep.scope is required -- the scope of the token the worker presents to the portal.\n\nWithout it the worker calls the portal with no token, and the portal answers 401\nto every pass. It is the portal's API registration (api.auth.clientId of the\nportal chart):\n\n  --set aep.scope=api://<portal api client id>/.default\n" -}}
{{- end -}}

{{- if and (dig "worker" "workloadIdentity" "enabled" false $v) (not (dig "worker" "workloadIdentity" "clientId" "" $v)) -}}
{{- fail "\n\nworker.workloadIdentity.clientId is required when workload identity is enabled.\n\nIt is the client id of the user-assigned managed identity that holds the portal's\nAEP.AddOn app role, and whose federated credential names this cluster's OIDC\nissuer and the worker's service account. Without it the worker has no token for\nthe portal. Set worker.workloadIdentity.enabled=false only if you supply another\ncredential through worker.extraEnv.\n" -}}
{{- end -}}

{{/*
  The prefix is both the route and the API's path base, and it shares a hostname
  with the portal. "/" or "/api" would take the portal's own traffic, "/apps" is
  where the portal's UI serves add-on pages -- a reload there would reach this API
  instead of the UI. A trailing slash would make the manifest URL "//manifest.json".
*/}}
{{- $prefix := toString (default "" $v.pathPrefix) -}}
{{- if or (not (regexMatch "^(/[A-Za-z0-9._~-]+)+$" $prefix)) (regexMatch "^/(api|apps)(/|$)" $prefix) -}}
{{- fail (printf "\n\npathPrefix %q cannot be used.\n\nIt is a path on the portal's own hostname: it must start with \"/\", have no\ntrailing \"/\", and stay clear of what the portal serves -- \"/\", \"/api\" and\n\"/apps\". The default is the one the portal expects:\n\n  pathPrefix: /addons/cmdb\n" $prefix) -}}
{{- end -}}

{{- if and (dig "ingress" "enabled" false $v) (not (dig "ingress" "host" "" $v)) -}}
{{- fail "\n\ningress.host is required when the ingress is enabled.\n\nIt is the PORTAL's hostname: the portal's UI loads the add-on from that same\norigin, under pathPrefix.\n\n  --set ingress.host=<the portal's host>\n" -}}
{{- end -}}

{{- if dig "httpRoute" "enabled" false $v -}}
{{/*
  compact on a defaulted list, rather than "first", because "first" dereferences a
  nil list instead of returning nothing: hostnames=null would crash the render.
*/}}
{{- if not (compact (default (list) $v.httpRoute.hostnames)) -}}
{{- fail "\n\nhttpRoute.hostnames must name at least one hostname -- the portal's.\n\nAn HTTPRoute with none attaches to every hostname its Gateway serves, which would\nput this path on hostnames meant for other applications.\n" -}}
{{- end -}}
{{- $refs := compact (default (list) $v.httpRoute.parentRefs) -}}
{{- if or (not $refs) (not (kindIs "map" (first $refs))) (not (dig "name" "" (first $refs))) -}}
{{- fail "\n\nhttpRoute.parentRefs[0].name is required -- the Gateway the portal's route attaches to.\n\n  --set httpRoute.parentRefs[0].name=<gateway> --set httpRoute.parentRefs[0].namespace=<its namespace>\n\nIf the Gateway is in another namespace it also needs a ReferenceGrant there allowing\nthis one to attach. A route without it is accepted and never programmed.\n" -}}
{{- end -}}
{{- end -}}

{{/*
  One worker. A pass plans against the database as it found it, so a second
  replica plans against the first and both write the same changes. Neither key is
  in values.yaml; both are refused rather than ignored, because being ignored is
  how you end up believing you scaled something.
*/}}
{{- $worker := $v.worker | default dict -}}
{{- if gt (int ($worker.replicaCount | default 1)) 1 -}}
{{- fail "\n\nThe worker runs one replica, and that is not configurable.\n\nEach discovery pass plans against the database as it found it, so a second\nreplica would plan against the first and both would write the same changes. The\nDeployment hardcodes 1; remove worker.replicaCount.\n" -}}
{{- end -}}
{{- if dig "autoscaling" "enabled" false $worker -}}
{{- fail "\n\nThe worker cannot be autoscaled.\n\nEach discovery pass plans against the database as it found it, so a second\nreplica would plan against the first. Remove worker.autoscaling.\n" -}}
{{- end -}}
{{- end -}}
