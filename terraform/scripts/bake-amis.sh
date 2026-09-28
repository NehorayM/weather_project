#!/usr/bin/env bash
# bake-amis.sh - EVENING. Saves GitLab and Jenkins as new golden AMIs.
#
# Daily order:
#   morning   scripts/apply.sh       build everything
#   daytime   scripts/tunnel.sh      only if the tunnel died
#   evening   scripts/destroy.sh     runs THIS script first, then tears everything down
#   any time  scripts/bake-amis.sh   save GitLab and Jenkins without destroying
#
# Why: GitLab's repositories and Jenkins' jobs live only on the instances' disks.
# destroy.sh deletes those disks, so without a fresh AMI today's commits are gone.
# The new AMI IDs are written into terraform.tfvars so tomorrow's apply.sh boots from them.
#
# The instances reboot during the bake so the disk is consistent (a GitLab database
# copied while running can come back corrupted). Takes about 10-20 minutes.
#
# Old AMIs are cleaned up: the newest KEEP per server stay, older ones are deregistered
# and their snapshots deleted. KEEP=all skips the cleanup.
#   KEEP=5 scripts/bake-amis.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="eu-north-1"
KEEP="${KEEP:-3}"
STAMP=$(date +%Y%m%d-%H%M)
TFVARS="terraform.tfvars"

declare -A NEW_AMI

echo "===> [1/3] creating AMIs from the running servers..."
for role in gitlab jenkins; do
    ID=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Name,Values=weather-$role" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text)
    if [ "$ID" = "None" ]; then
        echo "no weather-$role instance found - nothing to bake" >&2
        exit 1
    fi
    NEW_AMI[$role]=$(aws ec2 create-image --region "$REGION" --instance-id "$ID" \
        --name "$role-golden-$STAMP" --description "daily bake of weather-$role" \
        --query ImageId --output text)
    echo "$role: $ID -> ${NEW_AMI[$role]}"
done

echo "===> [2/3] waiting for the AMIs to become available..."
for role in gitlab jenkins; do
    for i in $(seq 120); do
        STATE=$(aws ec2 describe-images --region "$REGION" --image-ids "${NEW_AMI[$role]}" \
            --query 'Images[0].State' --output text)
        [ "$STATE" = "available" ] && break
        if [ "$STATE" = "failed" ] || [ "$i" = 120 ]; then
            echo "$role AMI ${NEW_AMI[$role]} is $STATE - NOT safe to destroy" >&2
            exit 1
        fi
        sleep 15
    done
    sed -i -E "s/^(${role}_ami_id\s*=\s*).*/\1\"${NEW_AMI[$role]}\"/" "$TFVARS"
    grep -q "\"${NEW_AMI[$role]}\"" "$TFVARS" || { echo "failed to write $role AMI into $TFVARS" >&2; exit 1; }
    echo "$role: ${NEW_AMI[$role]} available and written to $TFVARS"
done

echo "===> [3/3] removing old golden AMIs (keeping newest $KEEP per server)..."
if [ "$KEEP" = "all" ]; then
    echo "KEEP=all, skipping"
    exit 0
fi
for role in gitlab jenkins; do
    OLD=$(aws ec2 describe-images --region "$REGION" --owners self \
        --filters "Name=name,Values=$role-golden-*" \
        --query 'sort_by(Images,&CreationDate)[].ImageId' --output text | tr '\t' '\n' | head -n "-$KEEP")
    for ami in $OLD; do
        [ "$ami" = "${NEW_AMI[$role]}" ] && continue
        SNAPS=$(aws ec2 describe-images --region "$REGION" --image-ids "$ami" \
            --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
        aws ec2 deregister-image --region "$REGION" --image-id "$ami"
        for snap in $SNAPS; do
            aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap"
        done
        echo "deleted $ami ($SNAPS)"
    done
done
