#!/usr/bin/env bash
# tunnel.sh - the connection kubectl and terraform use to reach the EKS API.
#
# When:  apply.sh and destroy.sh start it for you.
#        By hand after a laptop reboot, or if kubectl says "connection refused".
# Usage: tunnel.sh [start|stop|status]      default: start
#
# Why: the EKS API has no public endpoint. Local port 8443 is forwarded through the
# Jenkins EC2 to the private endpoint with SSM. SSM drops a session after 20 minutes
# idle, so the session runs in a loop that reconnects by itself.
# kubeconfig points at 127.0.0.1:8443 and keeps the EKS hostname as tls-server-name,
# so the certificate still matches without an /etc/hosts entry (no sudo).
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

LOCAL_PORT=8443
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="$RUN_DIR/weather-tunnel.pid"
LOG_FILE="$RUN_DIR/weather-tunnel.log"

is_up()      { (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; }
loop_alive() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

start() {
    if loop_alive && is_up; then
        echo "tunnel already up on 127.0.0.1:$LOCAL_PORT"
        return
    fi
    stop >/dev/null

    JENKINS_ID=$(instance_id jenkins)
    [ "$JENKINS_ID" != "None" ] || die "no running ${PROJECT}-jenkins instance - is the environment up?"
    cluster_exists || die "cluster $CLUSTER_NAME not found - is the environment up?"

    read -r ENDPOINT ARN < <(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
        --query '[cluster.endpoint,cluster.arn]' --output text)
    HOST="${ENDPOINT#https://}"

    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null
    kubectl config set-cluster "$ARN" --server="https://127.0.0.1:$LOCAL_PORT" --tls-server-name="$HOST" >/dev/null

    # setsid gives the loop its own process group, so stop kills the loop, aws and
    # session-manager-plugin together. It gives up after ~40 quick failures in a row
    # (instance gone), so it never retries all night after a destroy.
    setsid bash -c '
        echo $$ > "$1"
        fails=0
        while [ $fails -lt 40 ]; do
            started=$(date +%s)
            aws ssm start-session --region "$2" --target "$3" \
                --document-name AWS-StartPortForwardingSessionToRemoteHost \
                --parameters "host=$4,portNumber=443,localPortNumber=$5"
            if [ $(( $(date +%s) - started )) -lt 10 ]; then fails=$((fails + 1)); else fails=0; fi
            echo "session ended $(date +%T), reconnecting"
            sleep 3
        done
        echo "giving up: $fails reconnects in a row failed"
        rm -f "$1"' _ "$PID_FILE" "$REGION" "$JENKINS_ID" "$HOST" "$LOCAL_PORT" \
        >"$LOG_FILE" 2>&1 </dev/null &

    for _ in $(seq 60); do
        if is_up; then
            echo "tunnel up: $HOST -> 127.0.0.1:$LOCAL_PORT via $JENKINS_ID"
            return
        fi
        sleep 2
    done
    stop >/dev/null
    die "tunnel did not come up after 2 minutes, see $LOG_FILE"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        # the whole group, or an older single-process tunnel and its child
        kill -- "-$PID" 2>/dev/null || { pkill -P "$PID" 2>/dev/null; kill "$PID" 2>/dev/null; } || true
        rm -f "$PID_FILE"
    fi
    for _ in $(seq 10); do is_up || break; sleep 1; done
    echo "tunnel stopped"
}

status() {
    if is_up; then echo "up on 127.0.0.1:$LOCAL_PORT"; else echo "down"; fi
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *)      die "usage: $0 [start|stop|status]" ;;
esac
