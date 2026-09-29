#!/usr/bin/env bash
# jenkins-sync.sh - points Jenkins at today's cluster so pipelines can start agent pods.
#
# When:  apply.sh runs it every morning. By hand if a pipeline hangs waiting for an
#        agent, or its log says it cannot connect to Kubernetes.
# Needs: the tunnel (tunnel.sh), to read the service account token.
#
# Why: the cluster is new every day, so its URL, its CA certificate and the token
# Jenkins logs in with (credential eks-sa-token) are new every day too.
# This script writes them to jenkins_home/eks/ on the Jenkins EC2 through SSM and
# restarts the Jenkins container. jenkins/eks-sync.groovy, installed into
# jenkins_home/init.groovy.d/, copies them into Jenkins on every start.
# No Jenkins password is needed. Jenkins is down for about a minute.
#
# The token passes through SSM Run Command, whose history keeps it. It stops
# working at the nightly destroy, when its cluster is deleted.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

JENKINS_HOME_ON_HOST="/home/ubuntu/jenkins-setup/jenkins_home"

JENKINS_ID=$(instance_id jenkins)
[ "$JENKINS_ID" != "None" ] || die "no running ${PROJECT}-jenkins instance"

read -r URL CA_B64 < <(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query '[cluster.endpoint,cluster.certificateAuthority.data]' --output text)
TOKEN_B64=$(kubectl -n jenkins get secret jenkins-controller-token -o jsonpath='{.data.token}')
[ -n "$TOKEN_B64" ] || die "no token in jenkins/jenkins-controller-token - did terraform apply module.kubernetes?"
GROOVY_B64=$(base64 -w0 "$SCRIPTS_DIR/jenkins/eks-sync.groovy")

# runs on the Jenkins EC2 as root
REMOTE=$(cat <<EOF
set -e
H=$JENKINS_HOME_ON_HOST
mkdir -p \$H/eks \$H/init.groovy.d
echo $GROOVY_B64 | base64 -d > \$H/init.groovy.d/eks-sync.groovy
echo $URL > \$H/eks/server_url
echo $CA_B64 | base64 -d > \$H/eks/ca.crt
echo $TOKEN_B64 | base64 -d > \$H/eks/token
chmod 600 \$H/eks/*
# Jenkins runs as the owner of jenkins_home, not as root
chown -R \$(stat -c '%u:%g' \$H) \$H/eks \$H/init.groovy.d
docker restart jenkins-controller >/dev/null
for i in \$(seq 60); do
  docker exec jenkins-controller curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login 2>/dev/null | grep -q 200 && break
  sleep 3
done
# --tail, not --since: an older AMI bake left a broken line in this log file
docker logs --tail 3000 jenkins-controller 2>&1 | grep -E 'eks-sync:|Failed to execute .*eks-sync' | tail -1
if grep -q "<serverUrl>$URL<" \$H/config.xml; then
  echo "config.xml: kubernetes cloud points at today's cluster"
else
  echo "config.xml still has: \$(grep -o '<serverUrl>[^<]*' \$H/config.xml)"
  exit 1
fi
curl -s -o /dev/null -w 'api check with the new token: HTTP %{http_code}\n' --cacert \$H/eks/ca.crt \
  -H "Authorization: Bearer \$(cat \$H/eks/token)" $URL/api/v1/namespaces/jenkins/pods
EOF
)
PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' <<<"$REMOTE")

step "updating Jenkins on $JENKINS_ID"
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$JENKINS_ID" \
    --document-name AWS-RunShellScript --comment "jenkins-sync" \
    --parameters "$PARAMS" --query Command.CommandId --output text)

for _ in $(seq 100); do
    STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
        --instance-id "$JENKINS_ID" --query Status --output text 2>/dev/null || echo Pending)
    case "$STATUS" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$JENKINS_ID" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
[ "$STATUS" = "Success" ] || die "jenkins-sync command ended with status $STATUS"
