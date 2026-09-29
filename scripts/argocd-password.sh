#!/usr/bin/env bash
# argocd-password.sh - prints today's ArgoCD admin password.
#
# When:  logging in to https://argocd.nehorai-menashe.click as admin.
#        The password is new every day because ArgoCD is installed fresh every morning.
# Needs: the tunnel (tunnel.sh).
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
