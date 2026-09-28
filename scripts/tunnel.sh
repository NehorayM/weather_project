#!/usr/bin/env bash
# tunnel.sh - DAYTIME. Opens the SSM tunnel that kubectl and terraform need to reach EKS.
#
# Daily order:
#   morning   scripts/apply.sh       build everything (starts this tunnel for you)
#   daytime   scripts/tunnel.sh      only if the tunnel died (reboot, sleep, "connection refused")
#   evening   scripts/destroy.sh     bake AMIs then tear everything down
#   any time  scripts/bake-amis.sh   save GitLab and Jenkins without destroying
#
# Why: the EKS API has no public endpoint. We forward local port 8443 through the Jenkins
# EC2 (via SSM) to the private endpoint. The TLS cert is issued for the EKS hostname, so
# /etc/hosts points that hostname at 127.0.0.1 and kubeconfig keeps the hostname on :8443.
# The instance ID and hostname change every day, so both are looked up, never hard-coded.
#
# Usage:  tunnel.sh [start|stop|status]     (default: start, runs in the background)
set -euo pipefail

REGION="eu-north-1"
CLUSTER_NAME="weather-eks"
JENKINS_NAME="weather-jenkins"
LOCAL_PORT=8443
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/weather-tunnel.pid"
LOG_FILE="${XDG_RUNTIME_DIR:-/tmp}/weather-tunnel.log"

is_up() { (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; }

start() {
    if is_up; then
        echo "tunnel already up on 127.0.0.1:$LOCAL_PORT"
        return
    fi

    JENKINS_ID=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Name,Values=$JENKINS_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text)
    if [ "$JENKINS_ID" = "None" ]; then
        echo "no running $JENKINS_NAME instance - is the environment up?" >&2
        exit 1
    fi

    read -r ENDPOINT ARN < <(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
        --query '[cluster.endpoint,cluster.arn]' --output text 2>/dev/null) || true
    if [ -z "${ARN:-}" ]; then
        echo "cluster $CLUSTER_NAME not found - is the environment up?" >&2
        exit 1
    fi
    HOST="${ENDPOINT#https://}"

    grep -q "$HOST" /etc/hosts || echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts >/dev/null
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null
    kubectl config set-cluster "$ARN" --server="https://$HOST:$LOCAL_PORT" >/dev/null

    # nohup keeps it alive after this terminal closes; stop kills aws and its session-manager-plugin child
    nohup aws ssm start-session --region "$REGION" \
        --target "$JENKINS_ID" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "host=$HOST,portNumber=443,localPortNumber=$LOCAL_PORT" \
        >"$LOG_FILE" 2>&1 </dev/null &
    echo $! >"$PID_FILE"

    for _ in $(seq 30); do
        if is_up; then
            echo "tunnel up: $HOST -> 127.0.0.1:$LOCAL_PORT via $JENKINS_ID"
            return
        fi
        sleep 2
    done
    echo "tunnel did not come up after 60s, see $LOG_FILE" >&2
    stop
    exit 1
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        pkill -P "$PID" 2>/dev/null || true
        kill "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    echo "tunnel stopped"
}

status() {
    if is_up; then echo "up on 127.0.0.1:$LOCAL_PORT"; else echo "down"; fi
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *)      echo "usage: $0 [start|stop|status]" >&2; exit 1 ;;
esac
