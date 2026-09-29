#!/usr/bin/env bash
# common.sh - settings and small helpers shared by every script in this folder.
# Not run by itself. Each script starts with: source "$(dirname "$0")/common.sh"
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file

set -euo pipefail

REGION="eu-north-1"
ACCOUNT_ID="225317159123"
PROJECT="weather"
CLUSTER_NAME="weather-eks"
DOMAIN="nehorai-menashe.click"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/weather"
K8S_ALB_NAME="weather-k8s-alb"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
TF_DIR="$ROOT_DIR/terraform"
APP_DIR="$ROOT_DIR/wetherApp"
CHART_DIR="$ROOT_DIR/weather-app-chart"
TFVARS="$TF_DIR/terraform.tfvars"
ROUTE53_K8S="$TF_DIR/modules/infrastructure/route53_k8s.tf"

# secrets that must survive the nightly destroy live here, outside every git repo
SECRETS_DIR="$HOME/.config/weather-project"

step() { echo; echo "===> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# instance_id gitlab|jenkins [states] -> instance ID, or None
instance_id() {
    aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Name,Values=${PROJECT}-$1" "Name=instance-state-name,Values=${2:-running}" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text
}

cluster_exists() {
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

# ARN of the ALB the Load Balancer Controller builds from the Ingresses, or None
k8s_alb_arn() {
    aws elbv2 describe-load-balancers --region "$REGION" --names "$K8S_ALB_NAME" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None"
}

my_ip() { curl -s --max-time 5 https://checkip.amazonaws.com; }
