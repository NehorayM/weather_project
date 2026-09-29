#!/usr/bin/env bash
# apply.sh - MORNING. Builds the whole environment from nothing, unattended (~30 min).
#
# Daily routine:
#   morning   scripts/apply.sh      everything up, ends with a status report
#   daytime   scripts/status.sh     is everything OK, and what to run if not
#   evening   scripts/destroy.sh    saves GitLab and Jenkins, then everything down
#
# Safe to run again if it stops halfway. Every step skips what already exists.
#
# Order and why:
#   1 VPC                  the network everything sits in
#   2 EKS, EC2, IAM        the kubernetes and helm providers need a running cluster
#                          before they can plan, so the cluster comes first
#   3 tunnel               the EKS API is private (tunnel.sh)
#   4 ECR and app image    ECR is kept overnight and imported back into terraform.
#                          The image values-prod.yaml asks for is built only if missing
#   5 k8s basics + LBC     namespaces, service accounts, the Load Balancer Controller
#   6 ArgoCD and Jenkins   argocd-bootstrap.sh then jenkins-sync.sh
#   7 k8s ALB              the controller builds it from the Ingresses ArgoCD syncs
#   8 DNS                  route53_k8s.tf needs that ALB, so it is switched on last
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
cd "$TF_DIR" || exit 1

step "[0/8] preflight"
for tool in aws terraform docker kubectl session-manager-plugin curl python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
aws sts get-caller-identity >/dev/null || die "AWS credentials do not work"
docker info >/dev/null 2>&1 || die "docker is not running"
[ -f "$APP_DIR/Dockerfile" ] || die "no Dockerfile in $APP_DIR"
IMAGE_TAG=$(sed -nE 's/^\s*tag:\s*"?([^"]+)"?\s*$/\1/p' "$CHART_DIR/values-prod.yaml" | head -1)
[ -n "$IMAGE_TAG" ] || die "could not read image.tag from values-prod.yaml"
for role in gitlab jenkins; do
    AMI=$(sed -nE "s/^${role}_ami_id\s*=\s*\"([^\"]+)\".*/\1/p" "$TFVARS")
    STATE=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" --query 'Images[0].State' --output text 2>/dev/null || true)
    [ "$STATE" = "available" ] || die "$role AMI $AMI in terraform.tfvars is not available"
done
echo "tools, AWS, docker, AMIs OK"
"$SCRIPTS_DIR/my-ip.sh" --no-apply
# DNS for the k8s ALB is switched on only once that ALB exists
if [ "$(k8s_alb_arn)" = "None" ] && [ -f "$ROUTE53_K8S" ]; then
    mv "$ROUTE53_K8S" "$ROUTE53_K8S.bak"
fi

step "[1/8] VPC"
terraform apply -target=module.vpc -auto-approve

step "[2/8] EKS, EC2 from the golden AMIs, IAM for LBC, EBS CSI and Jenkins agents"
# the EBS CSI role and pod identity must be in this stage: the addon is created here and
# its controller health-checks the EC2 API, so without credentials it crash-loops and
# the addon sits in CREATING until terraform times out
terraform apply \
  -target=module.infrastructure.module.eks \
  -target=module.infrastructure.aws_instance.jenkins \
  -target=module.infrastructure.aws_instance.gitlab \
  -target=module.infrastructure.aws_lb.main \
  -target=module.infrastructure.aws_iam_role.lbc \
  -target=module.infrastructure.aws_iam_policy.lbc \
  -target=module.infrastructure.aws_iam_role_policy_attachment.lbc \
  -target=module.infrastructure.aws_eks_pod_identity_association.lbc \
  -target=module.infrastructure.aws_iam_role.jenkins_agent \
  -target=module.infrastructure.aws_iam_role_policy_attachment.jenkins_agent \
  -target=module.infrastructure.aws_eks_pod_identity_association.jenkins_agent \
  -target=module.infrastructure.aws_iam_role.ebs_csi \
  -target=module.infrastructure.aws_iam_role_policy_attachment.ebs_csi \
  -target=module.infrastructure.aws_eks_pod_identity_association.ebs_csi \
  -target=module.infrastructure.aws_iam_role_policy_attachment.ec2_ssm \
  -auto-approve

step "[3/8] tunnel and nodes"
"$SCRIPTS_DIR/tunnel.sh" start
kubectl wait --for=condition=Ready nodes --all --timeout=300s

step "[4/8] ECR and the app image $IMAGE_TAG"
ECR_ADDR="module.infrastructure.aws_ecr_repository.app"
if ! terraform state list | grep -qx "$ECR_ADDR"; then
    if aws ecr describe-repositories --region "$REGION" --repository-names weather >/dev/null 2>&1; then
        terraform import "$ECR_ADDR" weather
    else
        terraform apply -target="$ECR_ADDR" -auto-approve
    fi
fi
if aws ecr describe-images --region "$REGION" --repository-name weather --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
    echo "$ECR_URL:$IMAGE_TAG already exists, no build needed"
else
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URL"
    docker build -t "$ECR_URL:$IMAGE_TAG" "$APP_DIR"
    docker push "$ECR_URL:$IMAGE_TAG"
fi

step "[5/8] namespaces, service accounts and the Load Balancer Controller"
terraform apply -target=module.kubernetes -target=module.infrastructure.helm_release.lbc -auto-approve

step "[6/8] ArgoCD and Jenkins"
"$SCRIPTS_DIR/argocd-bootstrap.sh"
"$SCRIPTS_DIR/jenkins-sync.sh"

step "[7/8] waiting for the k8s ALB (up to 10 minutes)"
for _ in $(seq 60); do
    [ "$(k8s_alb_arn)" != "None" ] && break
    sleep 10
done
if [ "$(k8s_alb_arn)" = "None" ]; then
    kubectl -n argocd get applications
    die "no $K8S_ALB_NAME after 10 minutes. Check the apps above in ArgoCD, then rerun apply.sh"
fi
echo "$K8S_ALB_NAME exists"

step "[8/8] DNS and a final full apply"
if [ -f "$ROUTE53_K8S.bak" ]; then
    mv "$ROUTE53_K8S.bak" "$ROUTE53_K8S"
fi
terraform apply -auto-approve

step "done - status"
"$SCRIPTS_DIR/status.sh"
echo
echo "ArgoCD admin password: scripts/argocd-password.sh"
echo "A URL that says 000 right after apply is DNS catching up. It fixes itself in a minute."
