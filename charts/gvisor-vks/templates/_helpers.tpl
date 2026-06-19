{{/* Chart name, overridable by nameOverride/fullnameOverride. */}}
{{- define "gvisor-vks.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gvisor-vks.fullname" -}}
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

{{- define "gvisor-vks.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels applied to every resource. */}}
{{- define "gvisor-vks.labels" -}}
helm.sh/chart: {{ include "gvisor-vks.chart" . }}
{{ include "gvisor-vks.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "gvisor-vks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gvisor-vks.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Target namespace: explicit override, else the release namespace (helm -n).
     The namespace is pre-created out of band (see namespace.yaml). */}}
{{- define "gvisor-vks.namespace" -}}
{{- .Values.namespace.name | default .Release.Namespace -}}
{{- end -}}

{{/* Image ref: tag falls back to chart appVersion. */}}
{{- define "gvisor-vks.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
