#!/usr/bin/env pwsh
#
# preflight-aws.ps1 — Windows/PowerShell equivalent of preflight-aws.sh.
# Checks that the AWS principal you're authenticated as is ALLOWED to perform the
# IAM actions this Terraform module needs, before you run `terraform apply`. It
# creates and changes nothing: it uses `aws iam simulate-principal-policy`.
#
# Usage:
#   pwsh scripts/preflight-aws.ps1
#   pwsh scripts/preflight-aws.ps1 -PrincipalArn <arn>     # override (e.g. SSO)
#   powershell -File scripts\preflight-aws.ps1             # Windows PowerShell 5.1
#
# Same caveats as the bash version: needs iam:SimulatePrincipalPolicy; evaluates
# your identity policies + permission boundary but NOT Organizations SCPs or
# resource policies, against "*" resources; the action list is representative,
# not exhaustive. Treat denials as the actionable signal.

param([string]$PrincipalArn)

# Don't let a non-zero native exit throw; we check $LASTEXITCODE ourselves.
$ErrorActionPreference = 'Continue'

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  Write-Host "AWS CLI not found on PATH. Install AWS CLI v2 first."
  exit 2
}

$account = (aws sts get-caller-identity --query Account --output text 2>$null)
$callerArn = (aws sts get-caller-identity --query Arn --output text 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $account) {
  Write-Host "Not authenticated to AWS (aws sts get-caller-identity failed)."
  Write-Host "Run 'aws configure' or 'aws sso login' first."
  exit 2
}
Write-Host "Authenticated as: $callerArn"
Write-Host "Account:          $account"
Write-Host ""

# simulate-principal-policy needs an IAM user or *role* ARN as the source.
$sourceArn = $PrincipalArn
if (-not $sourceArn) {
  if ($callerArn -match ':assumed-role/([^/]+)/') {
    # arn:aws:sts::ACCT:assumed-role/ROLE/SESSION -> arn:aws:iam::ACCT:role/ROLE
    $sourceArn = "arn:aws:iam::${account}:role/$($Matches[1])"
    Write-Host "Assumed role detected — simulating against role ARN:"
    Write-Host "  $sourceArn"
    Write-Host "  (SSO roles live under a /aws-reserved/... path; if you get NoSuchEntity,"
    Write-Host "   re-run with: pwsh scripts/preflight-aws.ps1 -PrincipalArn <role-arn>)"
    Write-Host ""
  } else {
    $sourceArn = $callerArn
  }
}

# Representative set of the actions the module performs at apply time.
$actions = @(
  # EKS Auto Mode cluster + access entries
  'eks:CreateCluster','eks:DescribeCluster','eks:TagResource',
  'eks:CreateAccessEntry','eks:AssociateAccessPolicy',
  # IAM: cluster/node roles, managed-policy attach, PassRole, scoped CI push user
  'iam:CreateRole','iam:AttachRolePolicy','iam:PutRolePolicy','iam:PassRole','iam:TagRole',
  'iam:CreateUser','iam:PutUserPolicy','iam:CreateAccessKey',
  # EC2 / VPC (only needed when create_vpc = true)
  'ec2:DescribeAvailabilityZones','ec2:CreateVpc','ec2:CreateSubnet',
  'ec2:CreateInternetGateway','ec2:CreateNatGateway','ec2:AllocateAddress',
  'ec2:CreateRouteTable','ec2:CreateRoute','ec2:CreateSecurityGroup',
  'ec2:AuthorizeSecurityGroupEgress','ec2:CreateTags',
  # ECR: image + chart repos, lifecycle policy
  'ecr:CreateRepository','ecr:PutLifecyclePolicy','ecr:DescribeRepositories','ecr:TagResource'
)

Write-Host "Simulating $($actions.Count) actions against:"
Write-Host "  $sourceArn"
Write-Host ""

# JSON output + ConvertFrom-Json = robust parsing (no tab/whitespace splitting).
$jsonText = (aws iam simulate-principal-policy `
  --policy-source-arn $sourceArn `
  --action-names $actions `
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' `
  --output json 2>$null | Out-String)

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) {
  Write-Host "Could not run the simulation."
  Write-Host ""
  Write-Host "If that's AccessDenied on iam:SimulatePrincipalPolicy, your principal just"
  Write-Host "can't use the simulator — it does NOT mean you lack the apply permissions."
  Write-Host "If it's NoSuchEntity (common for SSO), pass your full role ARN with -PrincipalArn."
  exit 2
}

$results = @($jsonText | ConvertFrom-Json)
$denied = 0
foreach ($r in $results) {
  if ($r.Decision -eq 'allowed') {
    $mark = 'ALLOW'
  } else {
    $mark = 'DENY '
    $denied++
  }
  '  {0}  {1,-34} {2}' -f $mark, $r.Action, $r.Decision
}

$total = $results.Count
Write-Host ""
if ($total -gt 0 -and $denied -eq 0) {
  Write-Host "All $total simulated actions are allowed - you should be able to run terraform apply."
  exit 0
} else {
  Write-Host "$denied of $total actions are denied (see above)."
  Write-Host "Get the missing permissions granted, or use the bring-your-own toggles in"
  Write-Host "terraform/amazon/README.md (create_vpc = false and/or create_ecr_push_user = false)"
  Write-Host "to drop the categories you can't create."
  exit 1
}
