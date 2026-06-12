# ---------------------------------------------------------------------------
# Verification Runbook — "Verify kubearchinspect results"
#
# Runs kubearchinspect ON DEMAND in the cluster via Octopus, so you don't need a
# local kubectl or kubeconfig. Trigger it from the project's Operations →
# Runbooks, or with `octopus runbook run` (see the README).
#
# WHY IT LAUNCHES ITS OWN JOB:
#   The deployment process runs kubearchinspect as a Helm post-install/post-
#   upgrade hook Job that auto-deletes ttlSecondsAfterFinished (600s) after it
#   finishes. So a "read the last Job's logs" runbook usually finds nothing.
#   Instead this runbook launches a fresh one-off Job and prints its report.
#   It reuses the resources the Helm deploy leaves behind and that PERSIST — the
#   kubearchinspect ServiceAccount, its ClusterRole/Binding (cluster-wide pod
#   read), and the kubearchinspect-kubeconfig ConfigMap (the in-cluster
#   kubeconfig) — so it only needs to create the Job itself.
#
# WHERE IT RUNS — the deployment target (agent), not the worker:
#   The step targets the Kubernetes AGENT (same tags as the deploy step). The
#   agent's script pods can create Jobs and read pod logs in the target
#   namespace (#{Namespace}, e.g. development) with no extra RBAC — the same
#   permissions the Helm deploy uses to create the chart's Job.
# ---------------------------------------------------------------------------

resource "octopusdeploy_runbook" "verify" {
  project_id  = octopusdeploy_project.kubearchinspect.id
  name        = "Verify kubearchinspect results"
  description = "Launches a one-off kubearchinspect Job in the environment's namespace and prints the arm64 compatibility report from its pod logs, run in-cluster on the Octopus agent."
}

resource "octopusdeploy_process" "verify" {
  project_id = octopusdeploy_project.kubearchinspect.id
  runbook_id = octopusdeploy_runbook.verify.id
}

resource "octopusdeploy_process_step" "verify_report" {
  process_id = octopusdeploy_process.verify.id
  name       = "Run kubearchinspect and show arm64 report"
  type       = "Octopus.Script"

  # Run on the in-cluster Kubernetes agent (matched by its target tags).
  properties = {
    "Octopus.Action.TargetRoles" = join(",", var.octopus_agent_tags)
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "False"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"

    # ${...} is interpolated by Terraform (the ECR repo URL). #{...} is resolved
    # by Octopus at run time. Plain $NAME (no braces) are shell variables — kept
    # brace-free so Terraform leaves them for the shell (and the nested Job
    # heredoc) to expand.
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      NS="#{Namespace}"
      IMAGE="${aws_ecr_repository.kubearchinspect.repository_url}:#{KubearchinspectImageTag}"
      SA="kubearchinspect"
      CM="kubearchinspect-kubeconfig"
      JOB="kubearchinspect-verify-$(date +%s)"

      # The ServiceAccount, RBAC and kubeconfig come from the Helm deploy and
      # persist; only the Job auto-deletes. Require a prior deploy to this env.
      if ! kubectl get serviceaccount "$SA" -n "$NS" >/dev/null 2>&1 || \
         ! kubectl get configmap "$CM" -n "$NS" >/dev/null 2>&1; then
        echo "kubearchinspect isn't deployed in namespace '$NS' yet"
        echo "(missing ServiceAccount '$SA' or ConfigMap '$CM')."
        echo "Deploy the kubearchinspect release to this environment first, then re-run."
        exit 1
      fi

      echo "Launching kubearchinspect Job '$JOB' in '$NS'"
      echo "  image: $IMAGE"
      echo

      kubectl apply -n "$NS" -f - <<JOBYAML
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: $JOB
        labels:
          app.kubernetes.io/name: kubearchinspect
          app.kubernetes.io/managed-by: octopus-runbook
      spec:
        backoffLimit: 0
        activeDeadlineSeconds: 300
        ttlSecondsAfterFinished: 120
        template:
          metadata:
            labels:
              app.kubernetes.io/name: kubearchinspect
          spec:
            serviceAccountName: $SA
            restartPolicy: Never
            nodeSelector:
              kubernetes.io/arch: arm64
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
              runAsGroup: 1000
              fsGroup: 1000
            initContainers:
              # Mint a fresh ECR token from the SA's Pod Identity role and write
              # the docker config kubearchinspect reads (~/.docker/config.json),
              # so it can query the private ECR image manifests. The region and
              # registry are baked in by Terraform; the shell vars below are
              # escaped so they expand in the init container at run time, not in
              # this agent script.
              - name: ecr-credentials
                image: ${var.kubearchinspect_aws_cli_image}
                command:
                  - /bin/sh
                  - -c
                  - |
                    set -eu
                    echo "[ecr-credentials] user \$(id -u):\$(id -g)  registry \$ECR_REGISTRY  region \$AWS_REGION"
                    aws sts get-caller-identity >/dev/null && echo "[ecr-credentials] AWS identity resolved"
                    mkdir -p /dockercfg/.docker
                    TOKEN=\$(aws ecr get-login-password --region "\$AWS_REGION")
                    AUTH=\$(printf 'AWS:%s' "\$TOKEN" | base64 | tr -d '\n')
                    printf '{"auths":{"%s":{"auth":"%s"}}}' "\$ECR_REGISTRY" "\$AUTH" > /dockercfg/.docker/config.json
                    echo "[ecr-credentials] wrote docker config (\$(wc -c < /dockercfg/.docker/config.json) bytes)"
                env:
                  - name: HOME
                    value: /dockercfg
                  - name: AWS_REGION
                    value: ${var.aws_region}
                  - name: ECR_REGISTRY
                    value: ${local.ecr_registry}
                volumeMounts:
                  - name: dockercfg
                    mountPath: /dockercfg
            containers:
              - name: kubearchinspect
                image: $IMAGE
                args: ["images", "--kube-config-path=/etc/kubearchinspect/kubeconfig"]
                env:
                  - name: HOME
                    value: /dockercfg
                volumeMounts:
                  - name: kubeconfig
                    mountPath: /etc/kubearchinspect
                    readOnly: true
                  - name: dockercfg
                    mountPath: /dockercfg
                    readOnly: true
            volumes:
              - name: kubeconfig
                configMap:
                  name: $CM
              - name: dockercfg
                emptyDir: {}
      JOBYAML

      echo "Waiting for '$JOB' to finish (up to 5 minutes)..."
      kubectl wait -n "$NS" --for=condition=complete --timeout=300s job/"$JOB" 2>/dev/null \
        || kubectl wait -n "$NS" --for=condition=failed --timeout=1s job/"$JOB" 2>/dev/null || true

      POD=$(kubectl get pods -n "$NS" -l job-name="$JOB" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

      echo
      echo "=== kubearchinspect arm64 compatibility report ==="
      if [ -n "$POD" ]; then
        # If the credential init container failed, the main container never runs;
        # surface its logs so the cause is visible in this task log.
        INIT_EXIT=$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
        if [ -n "$INIT_EXIT" ] && [ "$INIT_EXIT" != "0" ]; then
          echo "ECR credential init container failed (exit $INIT_EXIT):"
          kubectl logs -n "$NS" "$POD" -c ecr-credentials 2>&1 || true
          echo "kubearchinspect did not run. See the init container output above."
        else
          kubectl logs -n "$NS" "$POD" -c kubearchinspect || echo "(no logs available yet for $POD)"
        fi
      else
        echo "No pod was created for Job '$JOB' — check arm64 node capacity and image pull."
      fi
      echo
      echo "Legend: OK=arm64 compatible  UP=compatible after update  X=not compatible  ERR=scan error"

      echo
      echo "Cleaning up Job '$JOB'..."
      kubectl delete job "$JOB" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    EOT
  }

  depends_on = [
    octopusdeploy_runbook.verify,
    octopusdeploy_variable.namespace,
    octopusdeploy_variable.kubearchinspect_image_tag,
  ]
}

# Image tag the verification runbook runs. kubearchinspect scans the CLUSTER's
# images, so its own version barely matters — "latest" (pushed by the workflow)
# is fine; override per-run is unnecessary, so this is a plain (non-prompted)
# variable to avoid prompting on deployments.
resource "octopusdeploy_variable" "kubearchinspect_image_tag" {
  owner_id    = octopusdeploy_project.kubearchinspect.id
  name        = "KubearchinspectImageTag"
  type        = "String"
  value       = "latest"
  description = "ECR image tag the verification runbook runs."

  depends_on = [octopusdeploy_project.kubearchinspect]
}

output "kubearchinspect_verify_runbook_id" {
  description = "ID of the 'Verify kubearchinspect results' runbook"
  value       = octopusdeploy_runbook.verify.id
}
