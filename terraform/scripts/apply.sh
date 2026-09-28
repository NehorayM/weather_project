#!/usr/bin/env bash
# apply.sh - MORNING. Brings the whole environment up from nothing.
#
# Daily order:
#   morning   scripts/apply.sh       THIS script, build everything
#   daytime   scripts/tunnel.sh      only if the tunnel died (reboot, sleep, "connection refused")
#   evening   scripts/destroy.sh     bake AMIs then tear everything down
#   any time  scripts/bake-amis.sh   save GitLab and Jenkins without destroying
#
# Staged on purpose: the kubernetes and helm providers need a cluster that exists before
# terraform plans, and route53_k8s.tf needs the ALB that the controller creates from the
# Ingresses. So: VPC -> EKS/EC2/ECR -> image -> tunnel -> k8s resources -> ArgoCD -> DNS.
#
# ArgoCD is NOT installed by this script yet. At step 6 it pauses and waits for you to
# install ArgoCD and sync the apps by hand (terraform/README.md, "argocd").
#
# Needs: aws, terraform, docker, kubectl, session-manager-plugin, sudo (for /etc/hosts).
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="eu-north-1"
ACCOUNT_ID="225317159123"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/weather"
APP_DIR="${APP_DIR:-../wetherApp}"
CHART_DIR="${CHART_DIR:-../weather-app-chart}"

# fail now, not 20 minutes in: ECR is emptied every night so the image must be rebuilt
if [ ! -f "$APP_DIR/Dockerfile" ]; then
    echo "no Dockerfile in $APP_DIR - set APP_DIR=/path/to/wetherApp" >&2
    exit 1
fi
# build the exact tag ArgoCD will ask for, otherwise every pod is ImagePullBackOff
IMAGE_TAG=$(sed -nE 's/^\s*tag:\s*"?([^"]+)"?\s*$/\1/p' "$CHART_DIR/values-prod.yaml" | head -1)
if [ -z "$IMAGE_TAG" ]; then
    echo "could not read image.tag from $CHART_DIR/values-prod.yaml" >&2
    exit 1
fi
for f in "$CHART_DIR"/values-dev.yaml "$CHART_DIR"/values-staging.yaml; do
    grep -q "tag: \"$IMAGE_TAG\"" "$f" || echo "WARNING: $f uses a different tag than $IMAGE_TAG - that env will not find its image"
done

# keep Route53 records out until the k8s ALB exists
if [ -f "modules/infrastructure/route53_k8s.tf" ]; then
    mv modules/infrastructure/route53_k8s.tf modules/infrastructure/route53_k8s.tf.bak
fi

echo "===> [1/7] VPC..."
terraform apply -target=module.vpc -auto-approve

echo "===> [2/7] EKS, EC2 from golden AMIs, ECR, LBC and Jenkins agent IAM..."
terraform apply \
  -target=module.infrastructure.module.eks \
  -target=module.infrastructure.aws_instance.jenkins \
  -target=module.infrastructure.aws_instance.gitlab \
  -target=module.infrastructure.aws_lb.main \
  -target=module.infrastructure.aws_ecr_repository.app \
  -target=module.infrastructure.aws_iam_role.lbc \
  -target=module.infrastructure.aws_iam_policy.lbc \
  -target=module.infrastructure.aws_iam_role_policy_attachment.lbc \
  -target=module.infrastructure.aws_eks_pod_identity_association.lbc \
  -target=module.infrastructure.aws_iam_role.jenkins_agent \
  -target=module.infrastructure.aws_iam_role_policy_attachment.jenkins_agent \
  -target=module.infrastructure.aws_eks_pod_identity_association.jenkins_agent \
  -target=module.infrastructure.aws_iam_role_policy_attachment.ec2_ssm \
  -target=module.infrastructure.aws_vpc_security_group_ingress_rule.jenkins_jnlp \
  -auto-approve

echo "===> [3/7] building $ECR_URL:$IMAGE_TAG from $APP_DIR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URL"
docker build -t "${ECR_URL}:${IMAGE_TAG}" "$APP_DIR"
docker push "${ECR_URL}:${IMAGE_TAG}"

echo "===> [4/7] SSM tunnel and waiting for nodes..."
scripts/tunnel.sh start
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "===> [5/7] Kubernetes resources and the Load Balancer Controller..."
terraform apply -target=module.kubernetes -target=module.infrastructure.helm_release.lbc -auto-approve

echo "===> [6/7] waiting for the controller to create the k8s ALB..."
find_alb() {
    aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'weather-k8s')].LoadBalancerArn | [0]" \
        --output text 2>/dev/null || echo "None"
}
ALB_ARN=$(find_alb)
while [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; do
    echo
    echo "No k8s ALB yet. It appears only after ArgoCD syncs the Ingresses."
    echo "In another terminal: install ArgoCD, apply bootstrap/root-application.yaml, sync."
    read -r -p "Press Enter to check again, or q to stop here: " answer
    [ "$answer" = "q" ] && { echo "stopped before DNS. Rerun apply.sh when ArgoCD is synced."; exit 1; }
    for _ in $(seq 12); do
        ALB_ARN=$(find_alb)
        [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ] && break
        sleep 10
    done
done
echo "k8s ALB found: $ALB_ARN"

echo "===> [7/7] Route53 records and full apply..."
if [ -f "modules/infrastructure/route53_k8s.tf.bak" ]; then
    mv modules/infrastructure/route53_k8s.tf.bak modules/infrastructure/route53_k8s.tf
fi
terraform apply -auto-approve

echo "===> environment is up. The tunnel stays open for kubectl (scripts/tunnel.sh stop to close)."
