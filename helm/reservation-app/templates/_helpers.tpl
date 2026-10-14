{{- define "reservation-app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 서비스별 이름: <릴리스>-<서비스>. 인자: (dict "root" $ "name" "auth") */}}
{{- define "reservation-app.serviceName" -}}
{{- printf "%s-%s" (include "reservation-app.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "reservation-app.labels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
{{- end -}}

{{/* 셀렉터·Pod 라벨. 차트 버전처럼 자주 바뀌는 값은 넣지 않는다 (다른 서비스 Pod 가 재시작되지 않도록). */}}
{{- define "reservation-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/* stats 가 /readyz 를 확인할 서비스 주소 (SERVICE_URLS). 인자: (dict "root" $ "names" (list "auth" ...)) */}}
{{- define "reservation-app.serviceUrls" -}}
{{- $root := .root -}}
{{- $items := list -}}
{{- range .names -}}
{{- $items = append $items (printf "%s=http://%s:%v" . (include "reservation-app.serviceName" (dict "root" $root "name" .)) $root.Values.service.port) -}}
{{- end -}}
{{- join "," $items -}}
{{- end -}}
