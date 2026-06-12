# Plain service accounts — no AWS IRSA annotations needed. The agent/worker only
# talk outbound to Octopus; they don't call AWS APIs themselves.

resource "kubernetes_namespace" "octopus_agent" {
  count = var.install_octopus_agent ? 1 : 0

  metadata {
    name   = var.octopus_agent_namespace
    labels = { name = var.octopus_agent_namespace }
  }

  # Wait for the caller's cluster-admin RBAC. Until the access entry + policy
  # association land, the Kubernetes provider's get-token identity has no
  # permissions and every call returns "Unauthorized". This gates the whole
  # in-cluster layer (SAs -> Helm releases all chain off these namespaces).
  depends_on = [aws_eks_access_policy_association.admin]
}

resource "kubernetes_service_account" "octopus_agent" {
  count = var.install_octopus_agent ? 1 : 0

  metadata {
    name      = "octopus-agent"
    namespace = kubernetes_namespace.octopus_agent[0].metadata[0].name
  }
}

resource "kubernetes_namespace" "octopus_workers" {
  count = var.install_octopus_worker ? 1 : 0

  metadata {
    name   = var.octopus_worker_namespace
    labels = { name = var.octopus_worker_namespace }
  }

  depends_on = [aws_eks_access_policy_association.admin]
}

resource "kubernetes_service_account" "octopus_worker" {
  count = var.install_octopus_worker ? 1 : 0

  metadata {
    name      = "octopus-worker"
    namespace = kubernetes_namespace.octopus_workers[0].metadata[0].name
  }
}

# Per-environment namespaces for kubearchinspect deployments. The deployment
# process and the verification runbook target the namespace named after the
# environment (Development -> development, Staging -> staging, Production ->
# production). Pre-create them so the Helm deploy and the runbook's kubectl
# find an existing namespace — no --create-namespace (and no cluster-level
# namespace-create RBAC) required. Gated on the admin access grant like the
# agent/worker namespaces above.
resource "kubernetes_namespace" "environment" {
  for_each = toset([for e in var.environments : lower(e)])

  metadata {
    name = each.value
    labels = {
      name                          = each.value
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [aws_eks_access_policy_association.admin]
}
