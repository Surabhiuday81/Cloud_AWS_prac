#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
REGION="eu-north-1"
OWNER="ukumar"
PROJECT="2026_internship_hyd"
KEY_NAME="petclinic-key"
KEY_FILE="${KEY_NAME}.pem"

# Existing infrastructure (reused — at VPC limit)
VPC_ID="vpc-0c7993409f90d8935"
SUBNET_ID="subnet-0dcb705d65151f109"
IGW_ID="igw-07e95dec7fa0f0831"
RT_ID="rtb-05fcd2b2d56736846"

ECR_REPO_NAME="spring-petclinic"
DOCKERHUB_IMAGE="uday6395/spring-petclinic"
EC2_INSTANCE_TYPE="t3.micro"
AMI_ID="ami-0972fc275d302d38b"

STATE_FILE="infra_state.env"

# ─────────────────────────────────────────────
# Pull AWS credentials for ECR auth on EC2
# ─────────────────────────────────────────────
AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "ERROR: AWS credentials not found. Run 'aws configure' first."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPO_NAME}:latest"

echo "=========================================="
echo " Spring Petclinic — AWS Infrastructure"
echo "=========================================="
echo " Region  : $REGION"
echo " Owner   : $OWNER"
echo " Project : $PROJECT"
echo " Account : $ACCOUNT_ID"
echo " VPC     : $VPC_ID (existing petclinic-vpc)"
echo " Subnet  : $SUBNET_ID (eu-north-1a)"
echo ""

# ─────────────────────────────────────────────
# 1. KEY PAIR
# ─────────────────────────────────────────────
echo "[1/3] Checking EC2 Key Pair..."
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null; then
  echo "  Key pair '$KEY_NAME' already exists in AWS."
  if [ ! -f "$KEY_FILE" ]; then
    echo "  WARNING: Local key file $KEY_FILE not found!"
    echo "  Deleting old key pair and recreating..."
    aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
    aws ec2 create-key-pair \
      --region "$REGION" \
      --key-name "$KEY_NAME" \
      --query "KeyMaterial" \
      --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    echo "  Saved: $KEY_FILE"
  else
    echo "  Local key file found: $KEY_FILE"
  fi
else
  aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --query "KeyMaterial" \
    --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "  Key pair created: $KEY_FILE"
fi

# ─────────────────────────────────────────────
# 2. SECURITY GROUP
# ─────────────────────────────────────────────
echo "[2/3] Creating Security Group..."

# Delete existing petclinic-sg if present (from previous failed run)
EXISTING_SG=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=petclinic-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
  echo "  Found existing security group: $EXISTING_SG — reusing."
  SG_ID="$EXISTING_SG"
else
  SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "petclinic-sg" \
    --description "Spring Petclinic security group" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)

  aws ec2 create-tags --region "$REGION" \
    --resources "$SG_ID" \
    --tags \
      Key=Name,Value="petclinic-sg" \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT"

  aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "0.0.0.0/0"
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 8080 --cidr "0.0.0.0/0"
  echo "  Security Group: $SG_ID (ports 22, 8080 open)"
fi

# ─────────────────────────────────────────────
# 3. ECR + PUSH + EC2
# ─────────────────────────────────────────────
echo "[3/3] Setting up ECR, pushing image, launching EC2..."

# ECR repo
ECR_URI=$(aws ecr create-repository \
  --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" \
  --image-scanning-configuration scanOnPush=true \
  --query "repository.repositoryUri" --output text 2>/dev/null || \
  aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$ECR_REPO_NAME" \
    --query "repositories[0].repositoryUri" --output text)
echo "  ECR: $ECR_URI"

# Push image
echo "  Authenticating Docker to ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "  Pulling $DOCKERHUB_IMAGE from Docker Hub..."
docker pull "$DOCKERHUB_IMAGE"
docker tag "$DOCKERHUB_IMAGE" "$ECR_IMAGE"

echo "  Pushing to ECR..."
docker push "$ECR_IMAGE"
echo "  Image pushed."

# EC2 user-data
USER_DATA=$(cat <<EOF
#!/bin/bash
set -e
mkdir -p /root/.aws
cat > /root/.aws/credentials <<CREDS
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
region=${REGION}
CREDS
chmod 600 /root/.aws/credentials
dnf update -y
dnf install -y docker aws-cli
systemctl enable docker
systemctl start docker
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS --password-stdin ${ECR_REGISTRY}
docker pull ${ECR_IMAGE}
docker run -d \
  --name spring-petclinic \
  --restart unless-stopped \
  -p 8080:8080 \
  ${ECR_IMAGE}
EOF
)

# Launch EC2
echo "  Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$EC2_INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --user-data "$USER_DATA" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=petclinic-ec2},{Key=Owner,Value=${OWNER}},{Key=Project,Value=${PROJECT}}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=petclinic-ec2-vol},{Key=Owner,Value=${OWNER}},{Key=Project,Value=${PROJECT}}]" \
    "ResourceType=network-interface,Tags=[{Key=Name,Value=petclinic-ec2-nic},{Key=Owner,Value=${OWNER}},{Key=Project,Value=${PROJECT}}]" \
  --query "Instances[0].InstanceId" --output text)

echo "  Instance: $INSTANCE_ID"
echo "  Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

# Save state for cleanup
cat > "$STATE_FILE" <<ENVEOF
REGION=${REGION}
VPC_ID=${VPC_ID}
SUBNET_ID=${SUBNET_ID}
IGW_ID=${IGW_ID}
RT_ID=${RT_ID}
SG_ID=${SG_ID}
ECR_REPO_NAME=${ECR_REPO_NAME}
INSTANCE_ID=${INSTANCE_ID}
KEY_NAME=${KEY_NAME}
KEY_FILE=${KEY_FILE}
ENVEOF

echo ""
echo "=========================================="
echo " Infrastructure ready!"
echo "=========================================="
echo " VPC            : $VPC_ID"
echo " Subnet         : $SUBNET_ID"
echo " Security Group : $SG_ID"
echo " ECR            : $ECR_URI"
echo " Instance ID    : $INSTANCE_ID"
echo " Public IP      : $PUBLIC_IP"
echo " Key File       : $KEY_FILE"
echo ""
echo " App URL (wait ~3 min for Docker to start):"
echo "   http://${PUBLIC_IP}:8080"
echo ""
echo " SSH:"
echo "   ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
echo "=========================================="
