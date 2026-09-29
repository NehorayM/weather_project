#!/usr/bin/env bash
# my-ip.sh - lets your current internet address into GitLab and Jenkins.
#
# When:  GitLab or Jenkins answers 403 Forbidden, usually after changing network
#        (home Wi-Fi, phone hotspot). apply.sh runs it at the start too.
# Usage: my-ip.sh               add the IP, and apply it if the environment is up
#        my-ip.sh --no-apply    only add it to terraform.tfvars
#
# Your IP is added to admin_cidrs in terraform.tfvars. Old addresses are kept so
# switching back and forth keeps working. Remove old ones from the file by hand.
# Applying touches only the two ALB allow rules and the Jenkins SG (under a minute).
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

IP=$(my_ip)
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read your public IP"

if grep '^admin_cidrs' "$TFVARS" | grep -qF "\"$IP/32\""; then
    echo "$IP is already in admin_cidrs"
    CHANGED=no
else
    sed -i -E "s|^(admin_cidrs\s*=\s*\[)|\1\"$IP/32\", |" "$TFVARS"
    grep '^admin_cidrs' "$TFVARS" | grep -qF "\"$IP/32\"" || die "could not add $IP to terraform.tfvars"
    echo "added $IP to admin_cidrs"
    CHANGED=yes
fi
grep '^admin_cidrs' "$TFVARS"

[ "${1:-}" = "--no-apply" ] && exit 0
if [ "$(instance_id jenkins)" = "None" ]; then
    echo "environment is down, the next apply.sh uses the new list"
    exit 0
fi
if [ "$CHANGED" = "no" ]; then
    echo "nothing to apply. Still 403? Your IP may have changed again: rerun in a minute"
    exit 0
fi

cd "$TF_DIR" || exit 1
terraform apply -auto-approve \
    -target=module.infrastructure.aws_lb_listener_rule.restricted_allow \
    -target=module.vpc.aws_security_group.jenkins
