# EKS ARM + Octopus + kubearchinspect — one module

From a fork of this repo plus three credentials, `terraform apply` builds an
EKS Auto Mode (Graviton/arm64) cluster, provisions ECR and the Octopus +
GitHub wiring, and installs the Octopus agent/worker. The GitHub workflow then
builds the image, and Octopus deploys the kubearchinspect Helm chart.

## The three credentials

1. A terminal authenticated to AWS (SSO, profile, or env vars).
2. An Octopus API key — `export TF_VAR_octopus_api_key="API-xxxx"`.
3. A GitHub fine-grained PAT scoped to your fork — `export TF_VAR_github_token="github_pat_xxxx"`.

Everything else Terraform creates.

## Getting started

```bash
# 1. Fork this repository on GitHub.
# 2. Configure variables.
cp terraform.tfvars.example terraform.tfvars   # edit github_owner, github_repository, octopus_*, region
export TF_VAR_octopus_api_key="API-xxxx"
export TF_VAR_github_token="github_pat_xxxx"
# 3. Make sure your terminal is logged into AWS, then:
terraform init
terraform apply
```

## Required AWS permissions

The terminal running `terraform apply` needs permission to create and manage:

- EKS — `eks:CreateCluster`, `DescribeCluster`, `CreateAccessEntry`,
  `AssociateAccessPolicy`, `TagResource`, and the matching delete/update
  actions. Also `eks:DescribeAddonVersions` if you enable the standard driver path.
- IAM — create/delete roles and policies, attach managed policies, `PassRole`
  for the cluster and node roles. For the CI push user: create user, access
  key, and inline policy. (Equivalent: `IAMFullAccess`, or a scoped policy.)
- EC2 / VPC — when `create_vpc = true`: VPC, subnets, internet gateway, NAT
  gateway, EIP, route tables, security groups, plus the matching describe/tag
  actions. (Equivalent: `AmazonVPCFullAccess` + EC2 describe.)
- ECR — `ecr:CreateRepository`, `PutLifecyclePolicy`, `DescribeRepositories`,
  `DeleteRepository`, `TagResource`.

If you cannot grant a category, use the bring-your-own fallbacks below.

> Tip: run `bash scripts/preflight-aws.sh` (from the repo root) before applying —
> it simulates the actions below against your principal and reports any that are
> denied, so you find out up front instead of mid-apply.

### Bring your own (when you lack a permission)

| You can't create | Set | And supply |
|---|---|---|
| VPC / subnets | `create_vpc = false` | `vpc_id`, `subnet_ids` (private subnets, ≥2 AZs) |
| IAM users | `create_ecr_push_user = false` | wire GitHub OIDC -> an IAM role instead (the workflow already has `id-token: write`) |
| ECR repo | (provision it yourself) | point `ecr_repository_name` at the existing repo |

The EKS cluster role, node role, and access entries are not optional — Auto
Mode requires them — so the running principal must be able to create IAM roles
and EKS access entries for the cluster itself to come up.

## What gets created

- AWS: VPC + public/private subnets + NAT/IGW (or BYO), EKS Auto Mode cluster,
  ARM Graviton NodePool, ECR repo, scoped ECR push IAM user + key, gp3
  StorageClass.
- Octopus: `kubearchinspect` project + project group, Development/Staging/
  Production environments, ECR feed, Kubernetes agent (deployment target) and
  worker, and the deployment process.
- GitHub: Actions variables (`OCTOPUS_SERVICE`, `OCTOPUS_PROJECT`,
  `OCTOPUS_SPACE`, `AWS_REGION`, `ECR_REGISTRY`, `ECR_REPOSITORY`) and secrets
  (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `OCTOPUS_SERVER_URL`,
  `OCTOPUS_API_KEY`) on your fork.

## Notes

- Single `terraform apply`: the kubernetes/helm providers use `aws eks
  get-token` exec auth against the cluster this module creates, so no separate
  kubeconfig step is needed.
- Security: `create_ecr_push_user = true` produces a long-lived access key
  stored in state and in GitHub secrets. Prefer GitHub OIDC for anything beyond
  a demo.
- ECR + EBS on Auto Mode: the EBS CSI controller is built in, so only a
  StorageClass is created (`install_ebs_csi_driver` stays false).
