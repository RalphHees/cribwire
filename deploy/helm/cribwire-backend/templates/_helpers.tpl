{{/*
Chart name, overridable.
*/}}
{{- define "cribwire-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. Truncated at 63 chars because some Kubernetes name
fields are limited to that.
*/}}
{{- define "cribwire-backend.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "cribwire-backend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels applied to every object in the release.
*/}}
{{- define "cribwire-backend.labels" -}}
helm.sh/chart: {{ include "cribwire-backend.chart" . }}
{{ include "cribwire-backend.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cribwire
{{- end -}}

{{/*
Selector labels — immutable for the life of the Deployment.
*/}}
{{- define "cribwire-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cribwire-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cribwire-backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "cribwire-backend.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. A digest wins over a tag: it is the only form that cannot be
repointed in the registry after the fact.
*/}}
{{- define "cribwire-backend.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding DATABASE_URL, the TURN shared secret and the APNs
key. Fails the render rather than installing a release that cannot start.
*/}}
{{- define "cribwire-backend.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else if .Values.secret.create -}}
{{- include "cribwire-backend.fullname" . -}}
{{- else -}}
{{- fail "cribwire-backend: no credentials source. Set secret.existingSecret to a Secret holding DATABASE_URL (and, in production, TURN_SHARED_SECRET / APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID), or set secret.create=true and supply secret.data." -}}
{{- end -}}
{{- end -}}

{{/*
The migration Job is a pre-install/pre-upgrade hook, and hooks run before any
normal resource exists. A Secret the chart owns therefore has to be a hook too,
or a fresh install would fail with the Job unable to resolve DATABASE_URL.

The cost is that a hook resource is not recorded in the release manifest, so it
outlives `helm uninstall`. That only applies to the bootstrap paths
(`secret.create`, `imagePullSecrets.create`); pointing at Secrets you manage
yourself keeps everything ordinary.
*/}}
{{- define "cribwire-backend.bootstrapHookAnnotations" -}}
helm.sh/hook: pre-install,pre-upgrade
helm.sh/hook-weight: "-10"
helm.sh/hook-delete-policy: before-hook-creation
{{- end -}}

{{- define "cribwire-backend.configMapName" -}}
{{- printf "%s-config" (include "cribwire-backend.fullname" .) -}}
{{- end -}}

{{- define "cribwire-backend.valkey.fullname" -}}
{{- printf "%s-valkey" (include "cribwire-backend.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cribwire-backend.valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cribwire-backend.name" . }}-valkey
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
REDIS_URL for the ConfigMap. Rendered only for the in-cluster Valkey, which has
no password; an external Redis whose URL embeds credentials belongs in the
Secret (as REDIS_URL) instead, where `envFrom` order lets it win.
*/}}
{{- define "cribwire-backend.redisUrl" -}}
{{- if .Values.valkey.enabled -}}
{{- printf "redis://%s:%v/0" (include "cribwire-backend.valkey.fullname" .) .Values.valkey.service.port -}}
{{- else -}}
{{- .Values.externalRedis.url -}}
{{- end -}}
{{- end -}}

{{- define "cribwire-backend.imagePullSecretName" -}}
{{- default (printf "%s-registry" (include "cribwire-backend.fullname" .)) .Values.imagePullSecrets.create.name -}}
{{- end -}}

{{/*
The `imagePullSecrets` entries, combining the chart-managed Secret with any
Secret names given in `imagePullSecrets.existing`. Emits the list items only —
callers wrap it in `with` so that no key is written when there are none.
*/}}
{{- define "cribwire-backend.imagePullSecrets" -}}
{{- $names := list -}}
{{- if .Values.imagePullSecrets.create.enabled -}}
{{- $names = append $names (include "cribwire-backend.imagePullSecretName" .) -}}
{{- end -}}
{{- range .Values.imagePullSecrets.existing -}}
{{- $names = append $names . -}}
{{- end -}}
{{- range $names }}
- name: {{ . }}
{{- end }}
{{- end -}}

{{/*
Environment shared by the API Deployment and the migration Job: the ConfigMap
first, the Secret second so a key present in both resolves to the Secret.
*/}}
{{- define "cribwire-backend.envFrom" -}}
- configMapRef:
    name: {{ include "cribwire-backend.configMapName" . }}
- secretRef:
    name: {{ include "cribwire-backend.secretName" . }}
{{- with .Values.extraEnvFrom }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}
