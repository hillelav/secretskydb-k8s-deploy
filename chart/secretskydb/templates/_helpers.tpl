{{- define "secretskydb.name" -}}{{ .Release.Name }}{{- end -}}

{{- define "secretskydb.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "secretskydb.serviceAccountName" -}}
{{- if .Values.proxy.serviceAccount }}{{ .Values.proxy.serviceAccount }}{{- else }}{{ .Release.Name }}-sa{{- end }}
{{- end -}}

{{/* The Secret holding share hosts + every password. In-cluster shares render their own
     Secret under a derived name so a pre-existing AlloyDB Secret is never overwritten. */}}
{{- define "secretskydb.sharesSecretName" -}}
{{- if .Values.inclusterShares.enabled }}{{ .Release.Name }}-shares{{- else }}{{ .Values.alloydbShareSecret }}{{- end }}
{{- end -}}

{{/* sslmode for one share: in-cluster shares are plain Postgres on the pod network (no TLS);
     otherwise the global override, then the share's own setting, then "require".
     Call with (dict "root" $ "share" $s). */}}
{{- define "secretskydb.shareSslmode" -}}
{{- if .root.Values.inclusterShares.enabled -}}disable{{- else -}}{{ .root.Values.sharesSslmode | default .share.sslmode | default "require" }}{{- end -}}
{{- end -}}
