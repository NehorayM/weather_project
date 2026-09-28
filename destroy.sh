#!/usr/bin/env bash
set -euo pipefail

REGION="eu-north-1"
CLUSTER_NAME="weather-eks"
VPC_NAME="weather-vpc"
ECR_REPO="weather"

echo "===> [1/7] מחיקת רשומות Route53 ונטרול תלות ב-ALB..."
if [ -f "modules/infrastructure/route53_k8s.tf" ]; then
    terraform destroy \
      -target=module.infrastructure.aws_route53_record.app \
      -target=module.infrastructure.aws_route53_record.staging \
      -target=module.infrastructure.aws_route53_record.dev \
      -target=module.infrastructure.aws_route53_record.argocd \
      -target=module.infrastructure.aws_route53_record.grafana \
      -auto-approve 2>/dev/null || true

    echo "מעביר את route53_k8s.tf למצב .bak..."
    mv modules/infrastructure/route53_k8s.tf modules/infrastructure/route53_k8s.tf.bak
fi

echo "===> [2/7] שחרור שירותי Kubernetes ומשאבי Ingress מהקלאסטר..."
if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" 2>/dev/null; then
    kubectl delete ingress --all --all-namespaces --timeout=30s 2>/dev/null || true
    kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer --timeout=30s 2>/dev/null || true
fi

echo "===> [3/7] מחיקת Load Balancers שנוצרו ע\"י Kubernetes..."
K8S_ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'weather-k8s') || contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
    --output text 2>/dev/null || true)

for arn in $K8S_ALB_ARNS; do
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then
        echo "מוחק ALB: $arn"
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
    fi
done

echo "===> [4/7] מחיקה כפויה של מאגר ECR ($ECR_REPO)..."
aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force 2>/dev/null || true
terraform state rm module.infrastructure.aws_ecr_repository.app 2>/dev/null || true

echo "===> [5/7] ניקוי יזום של כרטיסי רשת (ENIs) ו-Security Groups מה-VPC..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    echo "ממתין 15 שניות לשחרור כרטיסי רשת..."
    sleep 15

    # שחרור ומחיקת כל כרטיס רשת תקוע (ENI)
    ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>/dev/null || true)

    for eni in $ENI_IDS; do
        if [ -n "$eni" ] && [ "$eni" != "None" ]; then
            echo "מוחק ENI: $eni"
            aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null || true
        fi
    done

    # מחיקת Security Groups עודפים שיצר ה-Controller
    SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?contains(GroupName, 'k8s-traffic')].GroupId" --output text 2>/dev/null || true)

    for sg in $SG_IDS; do
        if [ -n "$sg" ] && [ "$sg" != "None" ]; then
            echo "מוחק Security Group עודף: $sg"
            aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null || true
        fi
    done
fi

echo "===> [6/7] הסרת מודול Kubernetes וה-LBC מה-Terraform State..."
terraform state rm module.kubernetes 2>/dev/null || true
terraform state rm 'module.infrastructure.helm_release.lbc' 2>/dev/null || true

echo "===> [7/7] הרצת Terraform Destroy סופית לתשתיות הנותרות..."
terraform destroy -auto-approve

echo "===> כלל התשתיות הושמדו בהצלחה מלאה!"