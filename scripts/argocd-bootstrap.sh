#!/usr/bin/env bash
# argocd-bootstrap.sh - installs ArgoCD and connects it to the chart repo.
#
# When:  apply.sh runs it every morning. Safe to run again at any time, it only
#        changes what is missing or different.
# Needs: the tunnel (tunnel.sh).
#
# The steps that used to be done by hand:
#   1. ArgoCD from the official manifest, pinned to one version so a new release
#      cannot change a morning without warning
#   2. dex and notifications scaled to 0 (local accounts, Slack comes from Jenkins)
#   3. server.insecure: the ALB terminates TLS so ArgoCD must speak plain HTTP behind it
#   4. repo secret from a GitLab deploy token (read_repository only). The chart repo is
#      private. The secret dies with the cluster every night, the token file does not
#   5. the ArgoCD ingress and the root App-of-Apps. ArgoCD takes over from there
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

ARGOCD_VERSION="v3.5.3"
TOKEN_FILE="$SECRETS_DIR/argocd-repo.env"
CHART_REPO_URL="http://10.0.3.92:8000/whetherappgroup/weather-app-chart.git"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "No deploy token saved yet ($TOKEN_FILE)."
    echo "GitLab: chart repo -> Settings -> Repository -> Deploy tokens, scope read_repository only."
    read -rp "Deploy token username: " U
    read -rsp "Deploy token (hidden): " T
    echo
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    (umask 077; printf 'ARGOCD_REPO_USERNAME=%s\nARGOCD_REPO_PASSWORD=%s\n' "$U" "$T" > "$TOKEN_FILE")
    unset U T
fi
# shellcheck disable=SC1090
source "$TOKEN_FILE"
[ -n "${ARGOCD_REPO_USERNAME:-}" ] && [ -n "${ARGOCD_REPO_PASSWORD:-}" ] || die "$TOKEN_FILE is missing a value"

step "[1/5] ArgoCD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
echo "manifest applied"

step "[2/5] dex and notifications off"
kubectl -n argocd scale deploy argocd-dex-server argocd-notifications-controller --replicas=0

step "[3/5] server.insecure"
if [ "$(kubectl -n argocd get configmap argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}')" != "true" ]; then
    kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
    kubectl -n argocd rollout restart deploy argocd-server
else
    echo "already set"
fi
kubectl -n argocd rollout status deploy argocd-server --timeout=300s
kubectl -n argocd rollout status deploy argocd-repo-server --timeout=300s

step "[4/5] chart repo secret"
# values go through a private temp file, not the command line where ps could see them
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
printf 'type=git\nurl=%s\nusername=%s\npassword=%s\n' \
    "$CHART_REPO_URL" "$ARGOCD_REPO_USERNAME" "$ARGOCD_REPO_PASSWORD" > "$ENV_FILE"
kubectl -n argocd create secret generic repo-weather-chart --from-env-file="$ENV_FILE" --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl apply --server-side --force-conflicts -f -

step "[5/5] ArgoCD ingress and root application"
kubectl apply -f "$CHART_DIR/argocd-ingress.yaml"
kubectl apply -f "$CHART_DIR/bootstrap/root-application.yaml"

# a wrong token shows up here in seconds instead of as a missing ALB ten minutes later
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for _ in $(seq 40); do
    SYNC=$(kubectl -n argocd get application root -o jsonpath='{.status.sync.status}')
    [ "$SYNC" = "Synced" ] && break
    sleep 3
done
if [ "$SYNC" != "Synced" ]; then
    kubectl -n argocd get application root -o jsonpath='{range .status.conditions[*]}{.message}{"\n"}{end}' >&2
    die "root application is $SYNC - see the message above (a wrong deploy token says 'authentication required')"
fi
echo "root application synced. Admin password: scripts/argocd-password.sh"
