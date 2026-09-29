#!/usr/bin/env bash
# bake-amis.sh - saves GitLab and Jenkins as new golden AMIs.
#
# When:  destroy.sh runs it first every evening.
#        By hand any time you want a save point without destroying.
#
# Why: GitLab's repositories and Jenkins' jobs live only on the instances' disks.
# destroy.sh deletes those disks, so without a fresh AMI today's work is gone.
# The new AMI IDs are written into terraform.tfvars so tomorrow's apply.sh boots from them.
#
# The instances reboot during the bake so the disk is consistent (a GitLab database
# copied while running can come back corrupted). Takes about 10-20 minutes.
#
# Old AMIs are cleaned up: the newest KEEP per server stay, older ones are deregistered
# and their snapshots deleted. KEEP=all skips the cleanup.
#   KEEP=5 scripts/bake-amis.sh
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

KEEP="${KEEP:-3}"
STAMP=$(date +%Y%m%d-%H%M)
declare -A NEW_AMI

step "[1/3] creating AMIs from the servers"
for role in gitlab jenkins; do
    ID=$(instance_id "$role" running,stopped)
    [ "$ID" != "None" ] || die "no ${PROJECT}-$role instance found - nothing to bake"
    NEW_AMI[$role]=$(aws ec2 create-image --region "$REGION" --instance-id "$ID" \
        --name "$role-golden-$STAMP" --description "daily bake of ${PROJECT}-$role" \
        --query ImageId --output text)
    echo "$role: $ID -> ${NEW_AMI[$role]}"
done

step "[2/3] waiting for the AMIs to become available"
for role in gitlab jenkins; do
    for i in $(seq 120); do
        STATE=$(aws ec2 describe-images --region "$REGION" --image-ids "${NEW_AMI[$role]}" \
            --query 'Images[0].State' --output text)
        [ "$STATE" = "available" ] && break
        if [ "$STATE" = "failed" ] || [ "$i" = 120 ]; then
            die "$role AMI ${NEW_AMI[$role]} is $STATE - NOT safe to destroy"
        fi
        sleep 15
    done
    sed -i -E "s/^(${role}_ami_id\s*=\s*).*/\1\"${NEW_AMI[$role]}\"/" "$TFVARS"
    grep -q "\"${NEW_AMI[$role]}\"" "$TFVARS" || die "failed to write the $role AMI into terraform.tfvars"
    echo "$role: ${NEW_AMI[$role]} available and written to terraform.tfvars"
done

step "[3/3] removing old golden AMIs (keeping the newest $KEEP per server)"
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
