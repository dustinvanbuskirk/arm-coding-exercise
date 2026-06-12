{{/*
Expand the name of the chart.
*/}}
{{- define "kubearchinspect.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kubearchinspect.fullname" -}}
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
Create chart label.
*/}}
{{- define "kubearchinspect.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubearchinspect.labels" -}}
helm.sh/chart: {{ include "kubearchinspect.chart" . }}
{{ include "kubearchinspect.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubearchinspect.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubearchinspect.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "kubearchinspect.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kubearchinspect.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Namespace - allows override
*/}}
{{- define "kubearchinspect.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/*
Cluster-scoped resource name (ClusterRole / ClusterRoleBinding).
Each environment deploys a SEPARATE Helm release of this chart — same release
name (kubearchinspect), different namespace (development / staging / production).
Cluster-scoped resources are global, so if they shared one name the first release
to install would own them and every later release would fail to adopt them with
"invalid ownership metadata ... release-namespace must equal ...". Suffixing the
name with the release namespace gives each release its own ClusterRole/Binding.
*/}}
{{- define "kubearchinspect.clusterRoleName" -}}
{{- printf "%s-%s" (include "kubearchinspect.fullname" .) (include "kubearchinspect.namespace" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Build the kubearchinspect CLI args from values.
The command is `images`, pointed at the mounted in-cluster kubeconfig. The only
optional flag is --debug; kubearchinspect 0.7.0 has no namespace, check-newer-
versions, or log-level flags.
*/}}
{{- define "kubearchinspect.args" -}}
{{- $args := list "images" (printf "--kube-config-path=%s/kubeconfig" .Values.kubeconfig.mountPath) }}
{{- if .Values.inspect.debug }}
{{- $args = append $args "--debug" }}
{{- end }}
{{- toJson $args }}
{{- end }}
