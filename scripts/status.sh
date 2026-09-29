#!/usr/bin/env bash
# status.sh - one look at everything: AWS, the cluster, ArgoCD, Jenkins and every URL.
#
# When:  after apply.sh (it runs this at the end), and whenever something looks wrong.
#        Read-only. It changes nothing, it only tells you which script to run.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
set +e    # keep going and report everything, even when one check fails

ok()   { printf '  %-16s %s\n' "$1" "$2"; }
bad()  { printf '  %-16s %s   <- %s\n' "$1" "$2" "$3"; }

echo "== AWS"
for role in gitlab jenkins; do
    STATE=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=${PROJECT}-$role" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)
    if [ "$STATE" = "running" ]; then ok "$role" running; else bad "$role" "$STATE" "run apply.sh"; fi
done
EKS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query cluster.status --output text 2>/dev/null || echo none)
if [ "$EKS" = "ACTIVE" ]; then ok eks ACTIVE; else bad eks "$EKS" "run apply.sh"; fi
if [ "$(k8s_alb_arn)" != "None" ]; then
    ok k8s-alb exists
elif [ "$EKS" = "ACTIVE" ]; then
    bad k8s-alb missing "ArgoCD has not synced the Ingresses yet"
else
    bad k8s-alb missing "run apply.sh"
fi
IP=$(my_ip)
if grep '^admin_cidrs' "$TFVARS" | grep -qF "\"$IP/32\""; then ok "your IP" "$IP allowed"; else bad "your IP" "$IP not in admin_cidrs" "run my-ip.sh"; fi

if [ "$EKS" != "ACTIVE" ]; then
    echo
    echo "environment is down, nothing more to check"
    exit 0
fi

echo "== cluster"
if [ "$("$SCRIPTS_DIR/tunnel.sh" status)" = "down" ]; then
    bad tunnel down "run tunnel.sh"
    echo
    echo "no tunnel, skipping the cluster checks"
else
    ok tunnel up
    READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
    if [ "$READY" -gt 0 ]; then ok nodes "$READY Ready"; else bad nodes "none Ready" "check the node group in the AWS console"; fi
    BROKEN=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed" {print $1"/"$2" "$4}')
    if [ -z "$BROKEN" ]; then ok pods "all Running"; else bad pods "not running:" "kubectl describe pod"; echo "$BROKEN" | sed 's/^/                     /'; fi

    echo "== argocd apps"
    kubectl -n argocd get applications --no-headers 2>/dev/null \
        | awk '{printf "  %-16s %s %s\n", $1, $2, $3}'
    echo "  (weather-prod OutOfSync is normal until you press Sync in ArgoCD)"
fi

echo "== jenkins"
JENKINS_ID=$(instance_id jenkins)
if [ "$JENKINS_ID" != "None" ]; then
    TODAY=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query cluster.endpoint --output text)
    PARAMS='{"commands":["grep -o \"<serverUrl>[^<]*\" /home/ubuntu/jenkins-setup/jenkins_home/config.xml"]}'
    CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$JENKINS_ID" --document-name AWS-RunShellScript \
        --parameters "$PARAMS" --query Command.CommandId --output text 2>/dev/null)
    for _ in $(seq 10); do
        sleep 2
        S=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$JENKINS_ID" \
            --query Status --output text 2>/dev/null)
        case "$S" in Pending|InProgress|Delayed|"") ;; *) break ;; esac
    done
    JURL=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$JENKINS_ID" \
        --query StandardOutputContent --output text 2>/dev/null | sed 's/<serverUrl>//' | tr -d '[:space:]')
    if [ "$JURL" = "$TODAY" ]; then ok "k8s cloud" "points at today's cluster"; else bad "k8s cloud" "points at ${JURL:-?}" "run jenkins-sync.sh"; fi
fi

echo "== urls"
check() {    # check name url expected-codes hint
    CODE=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$2")
    if [[ " $3 " == *" $CODE "* ]]; then ok "$1" "$CODE"; else bad "$1" "$CODE" "$4"; fi
}
check weather "https://weather.$DOMAIN/"       "200"     "404 is normal until prod is synced in ArgoCD"
check staging "https://staging.$DOMAIN/"       "200"     "check weather-staging in ArgoCD"
check dev     "https://dev.$DOMAIN/"           "200"     "check weather-dev in ArgoCD"
check argocd  "https://argocd.$DOMAIN/"        "200"     "000 right after apply is DNS, wait a minute"
check grafana "https://grafana.$DOMAIN/"       "200 302" "check the monitoring app in ArgoCD"
check gitlab  "https://gitlab-privet.$DOMAIN/" "200 302" "403 means run my-ip.sh"
check jenkins "https://jenkins.$DOMAIN/login"  "200"     "403 means run my-ip.sh"
