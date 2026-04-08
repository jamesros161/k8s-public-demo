{{- define "site-template.name" -}}
{{- printf "%s-%s" .Values.siteId .Values.appType | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "site-template.dbName" -}}
{{- .Values.appType | lower | trunc 63 -}}
{{- end }}
