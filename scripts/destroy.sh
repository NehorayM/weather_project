#!/usr/bin/env bash
# destroy.sh - EVENING. Saves GitLab and Jenkins, then takes everything down (~40 min).
#
# Daily routine:
#   morning   scripts/apply.sh      everything up
#   daytime   scripts/status.sh     is everything OK
#   evening   scripts/destroy.sh    THIS script
#
# Kept overnight: the golden AMIs, the ECR images, the Route 53 zone, terraform.tfvars
# and the deploy token in ~/.config/weather-project. Everything else is deleted.
#
# Order and why:
#   0 bake AMIs              GitLab repos exist only on that disk. If the bake fails
#                            nothing is destroyed. SKIP_BAKE=1 only if nothing changed today
#   1 k8s DNS records        removed while the ALB they point at still exists
#   2 stop ArgoCD self-heal  otherwise ArgoCD recreates every Ingress we delete and the
#                            controller builds the ALB again in the middle of the destroy
#   3 delete the Ingresses   the controller removes its own ALB, target groups and
#                            security group rules, cleanly
#   4 leftovers by API       only needed if step 3 could not run (no tunnel)
#   5 terraform state        ECR and the in-cluster resources leave the state first
#   6 terraform destroy
#   7 monitoring disks, then a check that nothing is left running
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
cd "$TF_DIR" || exit 1

CLUSTER_UP=no
cluster_exists && CLUSTER_UP=yes

step "[0/7] baking GitLab and Jenkins AMIs"
if [ "${SKIP_BAKE:-0}" = "1" ]; then
    echo "SKIP_BAKE=1 - today's GitLab commits and Jenkins changes will be lost"
else
    "$SCRIPTS_DIR/bake-amis.sh"
fi

step "[1/7] DNS records that point at the k8s ALB"
if [ -f "$ROUTE53_K8S" ]; then
    terraform destroy -auto-approve \
      -target=module.infrastructure.aws_route53_record.app \
      -target=module.infrastructure.aws_route53_record.staging \
      -target=module.infrastructure.aws_route53_record.dev \
      -target=module.infrastructure.aws_route53_record.argocd \
      -target=module.infrastructure.aws_route53_record.grafana \
      || echo "could not remove them here, the full destroy will"
    mv "$ROUTE53_K8S" "$ROUTE53_K8S.bak"
fi

if [ "$CLUSTER_UP" = "yes" ] && "$SCRIPTS_DIR/tunnel.sh" start; then
    step "[2/7] stopping ArgoCD self-heal"
    kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null || true
    kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0 2>/dev/null || true
    kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s 2>/dev/null || true

    step "[3/7] deleting Ingresses and LoadBalancer Services, the controller removes the ALB"
    kubectl delete ingress --all --all-namespaces --wait=true --timeout=300s || true
    kubectl get svc -A --no-headers 2>/dev/null | awk '$3 == "LoadBalancer" {print $1, $2}' \
        | while read -r ns name; do kubectl -n "$ns" delete svc "$name" --timeout=120s || true; done
else
    echo "cluster down or no tunnel: skipping 2 and 3, step 4 cleans up by API"
fi

step "[4/7] making sure no Kubernetes-made load balancer is left"
k8s_albs() {
    aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?LoadBalancerName=='$K8S_ALB_NAME' || starts_with(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
        --output text
}
for _ in $(seq 30); do
    [ -z "$(k8s_albs)" ] && break
    sleep 10
done
for arn in $(k8s_albs); do
    echo "deleting leftover ALB $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
    aws elbv2 wait load-balancers-deleted --region "$REGION" --load-balancer-arns "$arn"
done
# target groups the controller made but no load balancer uses any more. Free, but they
# pile up every time an ALB is deleted by API instead of by the controller
for tg in $(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-') && length(LoadBalancerArns) == \`0\`].TargetGroupArn" \
        --output text); do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$tg" || true
done
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ]; then
    sleep 15    # ENIs of a deleted ALB take a moment to release
    for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
        aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
    done
    # a controller-made SG cannot be deleted while another SG still has a rule pointing at it,
    # and a leftover SG blocks the VPC delete later
    for sg in $(aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
            --query 'SecurityGroups[].GroupId' --output text); do
        aws ec2 describe-security-group-rules --region "$REGION" \
            --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$sg' && GroupId!='$sg'].[GroupId,SecurityGroupRuleId,IsEgress]" \
            --output text | while read -r group rule egress; do
                if [ "$egress" = "True" ]; then
                    aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$group" --security-group-rule-ids "$rule" >/dev/null || true
                else
                    aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$group" --security-group-rule-ids "$rule" >/dev/null || true
                fi
            done
        aws ec2 delete-security-group --region "$REGION" --group-id "$sg" || true
    done
fi

step "[5/7] terraform state: keep ECR, drop the in-cluster resources"
# ECR stays so the images built today still exist tomorrow. apply.sh imports it back
terraform state rm module.infrastructure.aws_ecr_repository.app 2>/dev/null || true
# these live inside the cluster, which disappears with it
terraform state rm module.kubernetes 2>/dev/null || true
terraform state rm module.infrastructure.helm_release.lbc 2>/dev/null || true
"$SCRIPTS_DIR/tunnel.sh" stop

step "[6/7] terraform destroy"
terraform destroy -auto-approve

step "[7/7] monitoring disks and a final check"
# the EBS CSI driver made these for the monitoring PVCs. Not in terraform state,
# detached now that the node is gone
for vol in $(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
        --query 'Volumes[].VolumeId' --output text); do
    echo "deleting volume $vol"
    aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
done

LEFT=""
[ "$(instance_id gitlab running,pending,stopping,stopped)" != "None" ] && LEFT="$LEFT gitlab-instance"
[ "$(instance_id jenkins running,pending,stopping,stopped)" != "None" ] && LEFT="$LEFT jenkins-instance"
cluster_exists && LEFT="$LEFT eks-cluster"
[ -n "$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, '${PROJECT}-') || starts_with(LoadBalancerName, 'k8s-')].LoadBalancerName" \
    --output text)" ] && LEFT="$LEFT load-balancers"
[ "$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${PROJECT}-vpc" --query 'Vpcs[0].VpcId' --output text)" != "None" ] && LEFT="$LEFT vpc"
if [ -n "$(terraform state list 2>/dev/null)" ]; then LEFT="$LEFT terraform-state"; fi

if [ -z "$LEFT" ]; then
    echo "everything is down. Tomorrow: scripts/apply.sh"
else
    die "still there:$LEFT - look in the AWS console, then run destroy.sh again with SKIP_BAKE=1"
fi
