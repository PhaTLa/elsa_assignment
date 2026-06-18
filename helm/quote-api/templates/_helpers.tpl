{{/*
Create a default fully qualified app name.
*/}}
{{- define "quote-api.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "quote-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "quote-api.labels" -}}
helm.sh/chart: {{ include "quote-api.chart" . }}
{{ include "quote-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "quote-api.selectorLabels" -}}
app.kubernetes.io/name: quote-api
app.kubernetes.io/instance: {{ .Release.Name }}
app: quote-api
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "quote-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "quote-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
