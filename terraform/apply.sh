#!/usr/bin/env bash
set -euo pipefail

REGION="eu-north-1"
CLUSTER_NAME="weather-eks"
ACCOUNT_ID="225317159123"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/weather"

# וידוא שקובץ ה-Route53 מנוטרל עד שה-ALB נוצר
if [ -f "modules/infrastructure/route53_k8s.tf" ]; then
    mv modules/infrastructure/route53_k8s.tf modules/infrastructure/route53_k8s.tf.bak
fi

echo "===> [1/6] הקמת תשתית רשת בסיסית: VPC..."
terraform apply -target=module.vpc -auto-approve

echo "===> [2/6] הקמת קלאסטר EKS, שרתי EC2, ECR ופוליסות ה-IAM של ה-LBC..."
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

echo "===> [3/6] בנייה ודחיפה של תמונת האפליקציה (1.0.2) ל-ECR למניעת ImagePullBackOff..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URL"
if [ -d "$HOME/Desktop/wetherApp" ]; then
    echo "בונה אימג' עם תמיכת Prometheus Metrics מתוך תיקיית האפליקציה..."
    docker build -t "${ECR_URL}:1.0.2" -t "${ECR_URL}:bootstrap" "$HOME/Desktop/wetherApp"
    docker push "${ECR_URL}:1.0.2"
    docker push "${ECR_URL}:bootstrap"
fi

echo "===> [4/6] עדכון kubeconfig והמתנה ל-Nodes..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "===> [5/6] פריסת רכיבי Kubernetes וה-Load Balancer Controller..."
terraform apply -target=module.kubernetes -target=module.infrastructure.helm_release.lbc -auto-approve

echo "===> [6/6] המתנה אקטיבית ליצירת ה-ALB ב-AWS ע\"י ה-Controller..."
for i in {1..30}; do
    ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'weather-k8s')].LoadBalancerArn | [0]" \
        --output text 2>/dev/null || echo "None")
    
    if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
        echo "ה-ALB זוהה בהצלחה: $ALB_ARN"
        break
    fi
    echo "עדיין ממתין ליצירת ה-ALB ע\"י ה-Controller... ($i/30)"
    sleep 10
done

# החזרת קובץ ה-Route53 לפעולה כעת כשה-ALB קיים ב-AWS
if [ -f "modules/infrastructure/route53_k8s.tf.bak" ]; then
    mv modules/infrastructure/route53_k8s.tf.bak modules/infrastructure/route53_k8s.tf
fi

echo "===> החלת כלל התשתית (סנכרון Route53 וסגירת תלויות מלאה)..."
terraform apply -auto-approve

echo "===> הקמת הסביבה הסתיימה בהצלחה מלאה!"