#!/usr/bin/env bash
#
# preflight-aws.sh — check that the AWS principal you're currently authenticated
# as is ALLOWED to perform the IAM actions this Terraform module needs, before
# you run `terraform apply`. It creates and changes nothing: it uses
# `aws iam simulate-principal-policy` to evaluate your identity's policies.
#
# Usage:
#   bash scripts/preflight-aws.sh                # auto-detect your principal
#   bash scripts/preflight-aws.sh <principal-arn> # override (e.g. for SSO roles)
#
# Caveats (so the result isn't over-trusted):
#   * Requires iam:SimulatePrincipalPolicy. If your principal lacks even that,
#     the script says so — which is NOT the same as lacking apply permissions.
#   * The simulator evaluates your identity-based policies + permission boundary,
#     but NOT Organizations SCPs or resource policies, and against "*" resources.
#     So "allowed" means "your identity policy permits it", not an absolute
#     guarantee apply will succeed. Treat denials as the actionable signal.
#   * The action list is a representative set of the module's key create actions,
#     not every action Terraform will make.

set -euo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Authenticated as: $CALLER_ARN"
echo "Account:          $ACCOUNT"
echo

# simulate-principal-policy needs an IAM user or *role* ARN as the source.
SOURCE_ARN="${1:-}"
if [ -z "$SOURCE_ARN" ]; then
  case "$CALLER_ARN" in
    *:assumed-role/*)
      # arn:aws:sts::ACCT:assumed-role/ROLE/SESSION -> arn:aws:iam::ACCT:role/ROLE
      ROLE_NAME=$(printf '%s' "$CALLER_ARN" | sed -E 's#.*:assumed-role/([^/]+)/.*#\1#')
      SOURCE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
      echo "Assumed role detected — simulating against role ARN:"
      echo "  $SOURCE_ARN"
      echo "  (SSO roles live under a /aws-reserved/... path; if you get NoSuchEntity,"
      echo "   re-run with your full role ARN: bash scripts/preflight-aws.sh <role-arn>)"
      echo
      ;;
    *)
      SOURCE_ARN="$CALLER_ARN"
      ;;
  esac
fi

# Representative set of the actions the module performs at apply time.
ACTIONS=(
  # EKS Auto Mode cluster + access entries
  eks:CreateCluster eks:DescribeCluster eks:TagResource
  eks:CreateAccessEntry eks:AssociateAccessPolicy
  # IAM: cluster/node roles, managed-policy attach, PassRole, scoped CI push user
  iam:CreateRole iam:AttachRolePolicy iam:PutRolePolicy iam:PassRole iam:TagRole
  iam:CreateUser iam:PutUserPolicy iam:CreateAccessKey
  # EC2 / VPC (only needed when create_vpc = true)
  ec2:DescribeAvailabilityZones ec2:CreateVpc ec2:CreateSubnet
  ec2:CreateInternetGateway ec2:CreateNatGateway ec2:AllocateAddress
  ec2:CreateRouteTable ec2:CreateRoute ec2:CreateSecurityGroup
  ec2:AuthorizeSecurityGroupEgress ec2:CreateTags
  # ECR: image + chart repos, lifecycle policy
  ecr:CreateRepository ecr:PutLifecyclePolicy ecr:DescribeRepositories ecr:TagResource
)

echo "Simulating ${#ACTIONS[@]} actions against:"
echo "  $SOURCE_ARN"
echo

if ! RESULTS=$(aws iam simulate-principal-policy \
      --policy-source-arn "$SOURCE_ARN" \
      --action-names "${ACTIONS[@]}" \
      --query 'EvaluationResults[].[EvalActionName,EvalDecision]' \
      --output text 2>/tmp/preflight-aws.err); then
  echo "Could not run the simulation:"
  sed 's/^/  /' /tmp/preflight-aws.err
  echo
  echo "If that's AccessDenied on iam:SimulatePrincipalPolicy, your principal just"
  echo "can't use the simulator — it does NOT mean you lack the apply permissions."
  echo "If it's NoSuchEntity (common for SSO), pass your full role ARN explicitly."
  exit 2
fi

# Report each action (awk -F tab is robust regardless of shell IFS handling).
printf '%s\n' "$RESULTS" | awk -F'\t' '{ mark = ($2=="allowed") ? "✅" : "❌"; printf "  %s %-34s %s\n", mark, $1, $2 }'

ALLOWED=$(printf '%s\n' "$RESULTS" | grep -cw allowed || true)
TOTAL=$(printf '%s\n' "$RESULTS" | grep -c . || true)

echo
if [ "$TOTAL" -gt 0 ] && [ "$ALLOWED" -eq "$TOTAL" ]; then
  echo "✅ All $TOTAL simulated actions are allowed — you should be able to run terraform apply."
else
  echo "❌ $((TOTAL - ALLOWED)) of $TOTAL actions are denied (see above)."
  echo "   Get the missing permissions granted, or use the bring-your-own toggles in"
  echo "   terraform/amazon/README.md (create_vpc = false and/or create_ecr_push_user = false)"
  echo "   to drop the categories you can't create."
  exit 1
fi
