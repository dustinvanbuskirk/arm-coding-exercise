# kubearchinspect Helm Chart

Deploys [Arm's kubearchinspect](https://github.com/ArmDeveloperEcosystem/kubearchinspect)
as a Kubernetes Job to verify that all container images running in your cluster
have `arm64` architecture support. Designed for use with AWS EKS Graviton node pools.

In this repo it is built and deployed automatically: the GitHub workflow builds the
arm64 image and packages the chart to ECR, and Octopus deploys it (see
`terraform/amazon`). The steps below are for a manual install.

## Prerequisites

- Helm 3.x
- kubectl access to your EKS cluster
- AWS ECR repository for the image (Arm does not publish an official container image)

## Step 1: Build and Push the Image to ECR

```bash
VERSION=0.7.0
ACCOUNT=336151728602
REGION=us-east-1
REPO=${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/kubearchinspect

# Create ECR repo (one-time)
aws ecr create-repository \
  --repository-name kubearchinspect \
  --region ${REGION}

# Authenticate Docker to ECR
aws ecr get-login-password --region ${REGION} \
  | docker login --username AWS --password-stdin \
  ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com

# Build for arm64 and push
docker buildx build \
  --platform linux/arm64 \
  --build-arg VERSION=${VERSION} \
  -t ${REPO}:${VERSION} \
  -t ${REPO}:latest \
  --push .
```

## Step 2: Install the Helm Chart

```bash
helm install kubearchinspect . \
  --namespace kube-system \
  --set image.repository=336151728602.dkr.ecr.us-east-1.amazonaws.com/kubearchinspect \
  --set image.tag=0.7.0
```

## Step 3: View Results

```bash
# Watch job completion
kubectl get job kubearchinspect -n kube-system -w

# View scan output
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=kubearchinspect -f
```

### Example output

```
Legend:
-------
✅ - arm64 node compatible
🆙 - arm64 node compatible (after update)
❌ - not arm64 node compatible
🚫 - error occurred

✅ 336151728602.dkr.ecr.us-east-1.amazonaws.com/petclinic:1.0.0
✅ registry.k8s.io/kube-proxy:v1.29.0
✅ quay.io/prometheus/node-exporter:v1.7.0
❌ some-amd64-only-image:latest
```

## Configuration Reference

| Parameter | Description | Default |
|---|---|---|
| `image.repository` | ECR image repository **(required)** | `""` |
| `image.tag` | Image tag | `0.7.0` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `job.ttlSecondsAfterFinished` | Auto-cleanup delay after job completes | `600` |
| `job.backoffLimit` | Retry attempts on failure | `2` |
| `job.activeDeadlineSeconds` | Job timeout in seconds | `300` |
| `inspect.debug` | Enable verbose `--debug` logging | `false` |
| `kubeconfig.mountPath` | Where the in-cluster kubeconfig is mounted | `/etc/kubearchinspect` |
| `kubeconfig.server` | In-cluster API server address | `https://kubernetes.default.svc` |
| `rbac.scope` | `cluster` or `namespace` RBAC scope | `cluster` |
| `pod.nodeSelector` | Node selector for the Job pod | `kubernetes.io/arch: arm64` |
| `pod.resources` | CPU/memory requests and limits | See values.yaml |

## Octopus Deploy Integration

This chart is deployed as a **verification step** in an Octopus Deploy project. The
deployment process (`terraform/amazon/octopus-process.tf`) runs an "Upgrade a Helm
Chart" step that pulls the chart from the ECR feed and sets `image.repository` /
`image.tag` from the release version. Recommended pipeline order:

1. **Deploy ARM Node Pool** (Terraform)
2. **Run kubearchinspect** (this chart) — gate on exit code
3. **Deploy Application** (your app's Helm chart)
