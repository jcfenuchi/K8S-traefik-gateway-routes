{{/*
Expand the name of the chart.
*/}}
{{- define "anubis-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "anubis-gateway.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "anubis-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "anubis-gateway.labels" -}}
helm.sh/chart: {{ include "anubis-gateway.chart" . }}
{{ include "anubis-gateway.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "anubis-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "anubis-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace helper
*/}}
{{- define "anubis-gateway.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end }}

{{/*
Retorna "true" se o endpoint usa o Anubis. "anubis: false" no endpoint
substitui anubisDefaults.enabled (hasKey, porque "default" trata false como vazio).
Uso: include "anubis-gateway.anubisEnabled" (dict "ep" $ep "root" $)
*/}}
{{- define "anubis-gateway.anubisEnabled" -}}
{{- if hasKey .ep "anubis" -}}
{{- if .ep.anubis }}true{{ end -}}
{{- else if .root.Values.anubisDefaults.enabled -}}
true
{{- end -}}
{{- end }}

{{/*
Service para onde a HTTPRoute aponta quando o endpoint NÃO usa o Anubis,
como JSON {name, namespace, port}.
  - externalIp: Service "<nome>-external" criado por este chart.
  - target: o Service do cluster da URL, que precisa ter a forma
    http://<service>.<namespace>.svc[.cluster.local][:porta]
*/}}
{{- define "anubis-gateway.directBackend" -}}
{{- $ep := .ep -}}
{{- $ns := include "anubis-gateway.namespace" .root -}}
{{- if $ep.externalIp -}}
{{- dict "name" (printf "%s-external" $ep.name) "namespace" $ns "port" (int $ep.port) | toJson -}}
{{- else if $ep.target -}}
{{- $u := urlParse $ep.target -}}
{{- $hostPort := splitList ":" $u.host -}}
{{- $parts := splitList "." (first $hostPort) -}}
{{- if or (lt (len $parts) 3) (ne (index $parts 2) "svc") (ne $u.scheme "http") -}}
{{- fail (printf "endpoint %q: sem o Anubis, 'target' precisa ser um Service do cluster no formato http://<service>.<namespace>.svc.cluster.local:<porta> (recebido: %s)" $ep.name $ep.target) -}}
{{- end -}}
{{- $port := 80 -}}
{{- if gt (len $hostPort) 1 }}{{ $port = int (last $hostPort) }}{{ end -}}
{{- dict "name" (index $parts 0) "namespace" (index $parts 1) "port" $port | toJson -}}
{{- else -}}
{{- fail (printf "endpoint %q: defina 'externalIp' e 'port', ou 'target'" $ep.name) -}}
{{- end -}}
{{- end }}
