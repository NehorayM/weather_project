#!/usr/bin/env bash
# destroy.sh - EVENING. Saves GitLab and Jenkins, then tears everything down to stop the bill.
#
# Daily order:
#   morning   scripts/apply.sh       build everything
#   daytime   scripts/tunnel.sh      only if the tunnel died
#   evening   scripts/destroy.sh     THIS script
#   any time  scripts/bake-amis.sh   save GitLab and Jenkins without destroying
#
# Step 0 bakes new golden AMIs. If the bake fails the script stops and nothing is
# destroyed, because GitLab's repos exist only on that disk.
#   SKIP_BAKE=1 scripts/destroy.sh    skip it ONLY if nothing changed on GitLab/Jenkins today
#
# Resources that Kubernetes created (k8s ALB, its security groups, ENIs, the monitoring
# EBS volumes) are not in terraform state, so they are cleaned up here by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="eu-north-1"
CLUSTER_NAME="weather-eks"
VPC_NAME="weather-vpc"
ECR_REPO="weather"

echo "===> [0/8] baking GitLab and Jenkins AMIs..."
if [ "${SKIP_BAKE:-0}" = "1" ]; then
    echo "SKIP_BAKE=1 - today's GitLab commits and Jenkins changes will be lost"
else
    scripts/bake-amis.sh
fi

echo "===> [1/8] Route53 records that point at the k8s ALB..."
if [ -f "modules/infrastructure/route53_k8s.tf" ]; then
    terraform destroy \
      -target=module.infrastructure.aws_route53_record.app \
      -target=module.infrastructure.aws_route53_record.staging \
      -target=module.infrastructure.aws_route53_record.dev \
      -target=module.infrastructure.aws_route53_record.argocd \
      -target=module.infrastructure.aws_route53_record.grafana \
      -auto-approve 2>/dev/null || true
    mv modules/infrastructure/route53_k8s.tf modules/infrastructure/route53_k8s.tf.bak
fi

echo "===> [2/8] deleting Ingresses and LoadBalancer Services (needs the tunnel)..."
if scripts/tunnel.sh start; then
    kubectl delete ingress --all --all-namespaces --timeout=30s 2>/dev/null || true
    kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer --timeout=30s 2>/dev/null || true
    scripts/tunnel.sh stop
fi

echo "===> [3/8] deleting ALBs created by Kubernetes..."
K8S_ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'weather-k8s') || contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
    --output text 2>/dev/null || true)

for arn in $K8S_ALB_ARNS; do
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then
        echo "deleting ALB: $arn"
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
    fi
done

echo "===> [4/8] force-deleting ECR repository $ECR_REPO..."
aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force 2>/dev/null || true
terraform state rm module.infrastructure.aws_ecr_repository.app 2>/dev/null || true

echo "===> [5/8] cleaning leftover ENIs and controller security groups from the VPC..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    echo "waiting 15s for network interfaces to release..."
    sleep 15

    ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>/dev/null || true)

    for eni in $ENI_IDS; do
        if [ -n "$eni" ] && [ "$eni" != "None" ]; then
            echo "deleting ENI: $eni"
            aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null || true
        fi
    done

    SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?contains(GroupName, 'k8s-traffic')].GroupId" --output text 2>/dev/null || true)

    for sg in $SG_IDS; do
        if [ -n "$sg" ] && [ "$sg" != "None" ]; then
            echo "deleting security group: $sg"
            aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null || true
        fi
    done
fi

echo "===> [6/8] removing the Kubernetes module and LBC from terraform state..."
terraform state rm module.kubernetes 2>/dev/null || true
terraform state rm 'module.infrastructure.helm_release.lbc' 2>/dev/null || true

echo "===> [7/8] terraform destroy for everything else..."
terraform destroy -auto-approve

# The EBS CSI driver creates the monitoring disks (prometheus, grafana, alertmanager).
# They are not in terraform state, and deleting PVCs before the destroy does not work
# while ArgoCD self-heals them back. Once the node is gone they are detached and safe to delete.
echo "===> [8/8] deleting EBS volumes the cluster left behind..."
VOL_IDS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text)

for vol in $VOL_IDS; do
    echo "deleting volume: $vol"
    aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
done

echo "===> everything is down. Tomorrow's apply.sh boots from the AMIs baked in step 0."
