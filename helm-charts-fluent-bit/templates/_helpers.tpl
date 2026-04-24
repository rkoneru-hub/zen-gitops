{{- define "fluent-bit.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fluent-bit.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app: {{ include "fluent-bit.name" . }}
app.kubernetes.io/name: {{ include "fluent-bit.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
