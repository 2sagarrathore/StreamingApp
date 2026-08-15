{{/* ---------------------------------------------------------------------
     Naming helpers
     --------------------------------------------------------------------- */}}

{{- define "streamingapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "streamingapp.fullname" -}}
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

{{- define "streamingapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Per-component resource name, e.g. streamingapp-auth */}}
{{- define "streamingapp.componentName" -}}
{{- printf "%s-%s" (include "streamingapp.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ---------------------------------------------------------------------
     Labels
     --------------------------------------------------------------------- */}}

{{- define "streamingapp.labels" -}}
helm.sh/chart: {{ include "streamingapp.chart" . }}
app.kubernetes.io/name: {{ include "streamingapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: streamingapp
{{- end -}}

{{- define "streamingapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "streamingapp.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/* ---------------------------------------------------------------------
     Image reference. Registry may be empty for local/kind testing, in which
     case we fall back to a bare repository name.
     --------------------------------------------------------------------- */}}
{{- define "streamingapp.image" -}}
{{- $registry := .root.Values.global.image.registry -}}
{{- $tag := default .root.Values.global.image.tag .svc.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .svc.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .svc.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* ---------------------------------------------------------------------
     ServiceAccount name
     --------------------------------------------------------------------- */}}
{{- define "streamingapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "streamingapp.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* ---------------------------------------------------------------------
     Secret name (generated vs. pre-existing)
     --------------------------------------------------------------------- */}}
{{- define "streamingapp.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "streamingapp.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "streamingapp.configMapName" -}}
{{- printf "%s-config" (include "streamingapp.fullname" .) -}}
{{- end -}}

{{/* ---------------------------------------------------------------------
     MongoDB connection string. Built from the in-cluster StatefulSet unless
     an external URI (DocumentDB / Atlas) was supplied.
     --------------------------------------------------------------------- */}}
{{- define "streamingapp.mongoHost" -}}
{{- printf "%s-mongodb" (include "streamingapp.fullname" .) -}}
{{- end -}}

{{- define "streamingapp.mongoUri" -}}
{{- if .Values.mongodb.externalUri -}}
{{- .Values.mongodb.externalUri -}}
{{- else if .Values.mongodb.auth.enabled -}}
{{- printf "mongodb://%s:%s@%s:27017/%s?authSource=admin&retryWrites=true" .Values.mongodb.auth.rootUsername .Values.mongodb.auth.rootPassword (include "streamingapp.mongoHost" .) .Values.mongodb.database -}}
{{- else -}}
{{- printf "mongodb://%s:27017/%s" (include "streamingapp.mongoHost" .) .Values.mongodb.database -}}
{{- end -}}
{{- end -}}

{{/* ---------------------------------------------------------------------
     Topology spread: keep replicas of a component in different AZs.
     --------------------------------------------------------------------- */}}
{{- define "streamingapp.topologySpread" -}}
{{- if .root.Values.topologySpreadEnabled }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "streamingapp.selectorLabels" . | nindent 8 }}
{{- end }}
{{- end -}}
