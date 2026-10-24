{{- define "secretskydb.name" -}}{{ .Release.Name }}{{- end -}}

{{- define "secretskydb.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "secretskydb.serviceAccountName" -}}
{{- if .Values.proxy.serviceAccount }}{{ .Values.proxy.serviceAccount }}{{- else }}{{ .Release.Name }}-sa{{- end }}
{{- end -}}
