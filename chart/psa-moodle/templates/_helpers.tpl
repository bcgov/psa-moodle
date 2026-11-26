{{/*
Expand the name of the chart.
*/}}
{{- define "psa-moodle.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated at 63 chars (k8s name limit).
*/}}
{{- define "psa-moodle.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name + version label.
*/}}
{{- define "psa-moodle.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard k8s recommended labels. Applied to every resource so coexistence with
the old moodle-nginx workloads is clean (different app.kubernetes.io/instance).
*/}}
{{- define "psa-moodle.labels" -}}
helm.sh/chart: {{ include "psa-moodle.chart" . }}
{{ include "psa-moodle.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: psa-moodle
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels — must remain stable across upgrades.
*/}}
{{- define "psa-moodle.selectorLabels" -}}
app.kubernetes.io/name: {{ include "psa-moodle.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component selector labels (web / php / cron / valkey).
Usage: {{ include "psa-moodle.componentSelectorLabels" (list . "web") }}
*/}}
{{- define "psa-moodle.componentSelectorLabels" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{ include "psa-moodle.selectorLabels" $ctx }}
app.kubernetes.io/component: {{ $component }}
{{- end }}

{{/*
Per-component full labels.
*/}}
{{- define "psa-moodle.componentLabels" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{ include "psa-moodle.labels" $ctx }}
app.kubernetes.io/component: {{ $component }}
{{- end }}

{{/*
Image references — one helper per component so values.yaml stays clean.
*/}}
{{- define "psa-moodle.image.web" -}}
{{- /* C13: a digest (sha256:...) pins the exact image; otherwise the shared tag. */ -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository .Values.web.image.name -}}
{{- with .Values.web.image.digest }}{{ printf "%s@%s" $base . }}{{ else }}{{ printf "%s:%s" $base $.Values.image.tag }}{{ end }}
{{- end }}

{{- define "psa-moodle.image.php" -}}
{{- /* C13: a digest (sha256:...) pins the exact image; otherwise the shared tag. */ -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository .Values.php.image.name -}}
{{- with .Values.php.image.digest }}{{ printf "%s@%s" $base . }}{{ else }}{{ printf "%s:%s" $base $.Values.image.tag }}{{ end }}
{{- end }}

{{- define "psa-moodle.image.cron" -}}
{{- /* C13: a digest (sha256:...) pins the exact image; otherwise the shared tag. */ -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository .Values.cron.image.name -}}
{{- with .Values.cron.image.digest }}{{ printf "%s@%s" $base . }}{{ else }}{{ printf "%s:%s" $base $.Values.image.tag }}{{ end }}
{{- end }}

{{- define "psa-moodle.image.ops" -}}
{{- /* C13: a digest (sha256:...) pins the exact image; otherwise the shared tag. */ -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository .Values.image.ops.name -}}
{{- with .Values.image.ops.digest }}{{ printf "%s@%s" $base . }}{{ else }}{{ printf "%s:%s" $base $.Values.image.tag }}{{ end }}
{{- end }}

{{/*
Common env block for the Phase 6 ops CronJobs. SMTP config + Postgres cluster
identifiers; no DB credentials directly — the scripts fetch them via `oc get
secret` at runtime so we don't materialise them into pod env where they'd be
visible in `kubectl describe`.
*/}}
{{- define "psa-moodle.opsEnv" -}}
- name: TARGET_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POSTGRES_CLUSTER
  value: {{ include "psa-moodle.postgres.clusterName" . | quote }}
- name: POSTGRES_USER_SECRET
  value: {{ include "psa-moodle.postgres.userSecretName" . | quote }}
- name: POSTGRES_USER_NAME
  value: {{ .Values.postgres.user.name | quote }}
- name: POSTGRES_VERSION
  value: {{ .Values.postgres.postgresVersion | quote }}
- name: ALERT_SMTP_HOST
  value: {{ .Values.backup.alerts.smtpHost | quote }}
- name: ALERT_SMTP_PORT
  value: {{ .Values.backup.alerts.smtpPort | quote }}
- name: ALERT_FROM
  value: {{ .Values.backup.alerts.from | quote }}
- name: ALERT_TO
  value: {{ required "backup.alerts.to is required (set in values-<env>.yaml)" .Values.backup.alerts.to | quote }}
{{- end }}

{{/*
Postgres cluster name. The Crunchy operator names the credentials Secret
"<cluster>-pguser-<user>", which the php/cron deployments reference.
*/}}
{{- define "psa-moodle.postgres.clusterName" -}}
{{- printf "%s-pg" (include "psa-moodle.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "psa-moodle.postgres.userSecretName" -}}
{{- printf "%s-pguser-%s" (include "psa-moodle.postgres.clusterName" .) .Values.postgres.user.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "psa-moodle.postgres.primaryService" -}}
{{- printf "%s-primary" (include "psa-moodle.postgres.clusterName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Valkey service name.
*/}}
{{- define "psa-moodle.valkey.serviceName" -}}
{{- printf "%s-valkey" (include "psa-moodle.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "psa-moodle.valkey.fullname" -}}
{{- printf "%s-valkey" (include "psa-moodle.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Valkey AUTH secret name (holds VALKEY_PASSWORD). See secret-valkey.yaml.
*/}}
{{- define "psa-moodle.valkey.secretName" -}}
{{- printf "%s-auth" (include "psa-moodle.valkey.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common application env block — used by php Deployment, cron CronJob, and the
install Job. DB credentials come from Crunchy's pguser Secret; we never
duplicate them in our own Secret.
*/}}
{{- define "psa-moodle.appEnv" -}}
- name: DB_HOST
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.postgres.userSecretName" . }}
      key: host
- name: DB_PORT
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.postgres.userSecretName" . }}
      key: port
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.postgres.userSecretName" . }}
      key: dbname
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.postgres.userSecretName" . }}
      key: user
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.postgres.userSecretName" . }}
      key: password
- name: CACHE_HOST
  value: {{ include "psa-moodle.valkey.serviceName" . | quote }}
- name: CACHE_PORT
  value: "6379"
- name: CACHE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "psa-moodle.valkey.secretName" . }}
      key: VALKEY_PASSWORD
{{- with .Values.loadTest.generatorPasswordSecret }}
# Dev load tests only (runbook §9): the generator plan's synthetic users' password (self-review V1314).
- name: TOOL_GENERATOR_USERS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: password
{{- end }}
- name: MOODLE_WWWROOT
  value: {{ required "moodle.wwwroot is required (set in values-<env>.yaml)" .Values.moodle.wwwroot | quote }}
- name: MOODLE_BEHIND_PROXY
  value: "1"
- name: MOODLE_OUTBOUND
  value: {{ if include "psa-moodle.fenced" . }}"off"{{ else }}{{ .Values.moodle.outbound | default "off" | quote }}{{ end }}
- name: MOODLE_REVIEWER_ADMINS
  value: {{ .Values.moodle.reviewerAdmins | default "" | quote }}
- name: MOODLE_INSTALL_ENABLED
  value: {{ .Values.install.enabled | toString | quote }}
{{- if .Values.moodle.debug }}
- name: MOODLE_DEBUG
  value: "1"
{{- end }}
{{- end }}

{{/*
Migration state (replatform runbook S13, V501): "normal" or "fenced". The fenced profile renders web, php and cron at
0 replicas, HPAs off, every application CronJob suspended and outbound off, so no later upgrade can bring a writer back.
Returns "true" when fenced. Any other value fails the render.
*/}}
{{- define "psa-moodle.fenced" -}}
{{- $state := .Values.migration.state | default "normal" -}}
{{- if not (has $state (list "normal" "fenced")) -}}
{{- fail (printf "migration.state must be normal or fenced, not %q" $state) -}}
{{- end -}}
{{- if eq $state "fenced" }}true{{ end -}}
{{- end }}

{{/*
networkPolicy.externalEgress: "on" or "off" (C15). Any other value fails the render.
*/}}
{{- define "psa-moodle.externalEgress" -}}
{{- $v := toString .Values.networkPolicy.externalEgress -}}
{{- if not (has $v (list "on" "off")) -}}
{{- fail (printf "networkPolicy.externalEgress must be on or off, not %q" $v) -}}
{{- end -}}
{{- if include "psa-moodle.fenced" . }}off{{ else }}{{ $v }}{{ end -}}
{{- end -}}

{{/*
The outbound guard's effective value (C5): off while fenced, else moodle.outbound (default off).
*/}}
{{- define "psa-moodle.outbound" -}}
{{- if include "psa-moodle.fenced" . }}off{{ else }}{{ .Values.moodle.outbound | default "off" }}{{ end -}}
{{- end -}}

{{/*
"true" when the php-fpm metrics sidecar runs: monitoring on and monitoring.phpFpmExporter.enabled not false. 950003
turns it off: the only exporter image (hipages 2.2.0, unmaintained) carries CRITICAL CVEs (image scan, 2026-11-26).
*/}}
{{- define "psa-moodle.phpFpmExporter" -}}
{{- if and .Values.monitoring.enabled (ne (toString .Values.monitoring.phpFpmExporter.enabled) "false") }}true{{ end -}}
{{- end -}}
