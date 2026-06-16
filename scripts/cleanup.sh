#!/bin/bash
set -euo pipefail

STATE_FILE="infra_state.env"

if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: $STATE_FILE not found."
  exit 1
fi

source "$STATE_FILE"

echo "=========================================="
echo " Spring Petclinic — Cleanup"
echo "=========================================="
echo " The following resources will be DELETED:"
echo "   EC2 Instance  : $INSTANCE_ID"
echo "   Security Group: $SG_ID"
echo "   ECR Repo      : $ECR_REPO_NAME"
echo "   Key Pair      : $KEY_NAME"
echo ""
echo " The following will be KEPT (pre-existing):"
echo "   VPC           : $VPC_ID"
echo "   Subnet        : $SUBNET_ID"
echo "   IGW           : $IGW_ID"
echo "   Route Table   : $RT_ID"
echo ""
read -rp "Proceed? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

echo "[1/4] Terminating EC2 instance: $INSTANCE_ID ..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
echo "  Waiting for termination..."
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "  Done."

echo "[2/4] Deleting Security Group: $SG_ID ..."
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
echo "  Done."

echo "[3/4] Deleting ECR Repository: $ECR_REPO_NAME ..."
aws ecr delete-repository --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" --force > /dev/null
echo "  Done."

echo "[4/4] Deleting Key Pair: $KEY_NAME ..."
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
[ -f "$KEY_FILE" ] && rm -f "$KEY_FILE" && echo "  Local key file removed."
echo "  Done."

rm -f "$STATE_FILE"

echo ""
echo "=========================================="
echo " Cleanup complete!"
echo " VPC and networking left intact."
echo "=========================================="
