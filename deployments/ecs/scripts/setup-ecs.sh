#!/bin/bash

set -euo pipefail

# Load required env vars
source deployments/ecs/scripts/export-env.sh

: "${AWS_PROFILE:?Environment variable AWS_PROFILE must be set}"

CLUSTER_NAME="carastore-cluster"
SERVICE_NAME="carastore-service"
TASK_DEF_NAME="carastore-server"
CONTAINER_NAME="nodejs-server"
KEY_NAME="ecs-key"
KEY_PAIR_DIR="$HOME/.ssh"
EC2_USER="ec2-user"
INSTANCE_ROLE="ecsInstanceRole"
INSTANCE_PROFILE="ecsInstanceProfile"
INSTANCE_TYPE="t3.small"
TASK_ROLE="ecsTaskExecutionRole"
ALB_SG_NAME="alb-sg"
ECS_SG_NAME="ecs-sg"
PORT=5000
SERVER_LOG_GROUP="/ecs/carastore-server"
DB_LOG_GROUP="/ecs/carastore-db"
PLATFORM_DIR="deployments/ecs"
USER_DATA_FILE="$PLATFORM_DIR/init/user-data.txt"

# Retrieve ECS-optimised AMI
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id \
  --region $AWS_REGION \
  --query "Parameters[0].Value" \
  --output text)

echo "[INFO] Using ECS-optimised AMI: $AMI_ID"

# Create ECS Cluster
aws ecs create-cluster --cluster-name $CLUSTER_NAME || true
echo "[INFO] ECS cluster created: $CLUSTER_NAME"

# -- Create Secrets in Secrets Manager --

# Substitute variables
envsubst < $PLATFORM_DIR/templates/ecs-secrets.template.json > $PLATFORM_DIR/init/ecs-secrets.json

aws secretsmanager create-secret \
  --name $SM_SECRET_NAME \
  --secret-string file://$PLATFORM_DIR/init/ecs-secrets.json \
  --region $AWS_REGION || true
echo "[INFO] Secrets Manager entry created: $SM_SECRET_NAME"

# Create IAM Role for EC2 Instance
aws iam create-role \
  --role-name $INSTANCE_ROLE \
  --assume-role-policy-document file://$PLATFORM_DIR/iam/ecs-instance-trust.json || true

aws iam attach-role-policy \
  --role-name $INSTANCE_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role || true

aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE || true

aws iam add-role-to-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE \
  --role-name $INSTANCE_ROLE || true
echo "[INFO] IAM role and instance profile setup complete"

# Create Security Group
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text)

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name $ALB_SG_NAME \
  --description "Security group for ALB" \
  --vpc-id $VPC_ID \
  --query "GroupId" \
  --output text)

ECS_SG_ID=$(aws ec2 create-security-group \
  --group-name $ECS_SG_NAME \
  --description "Security Group for ECS Instance" \
  --vpc-id $VPC_ID \
  --query "GroupId" \
  --output text)

echo "[INFO] Security groups created: ALB SG = $ALB_SG_ID, ECS SG = $ECS_SG_ID"

# Allow HTTP, HTTPS, and SSH inbound
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 || true

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 || true

aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG_ID \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 || true

aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG_ID \
  --protocol tcp --port $PORT --source-group $ALB_SG_ID || true

echo "[INFO] Inbound rules configured for ALB and ECS security groups"

# Retrieve Subnet IDs for available EC2 offerings
AZS=$(aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=$INSTANCE_TYPE \
  --region $AWS_REGION \
  --query "InstanceTypeOfferings[].Location" \
  --output text | cut -f1-2)

SUBNET_IDS=""
for AZ in $AZS; do
  SUBNET_ID=$(aws ec2 describe-subnets \
    --region $AWS_REGION \
    --filters "Name=availability-zone,Values=$AZ" \
              "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[0].SubnetId" \
    --output text)
  SUBNET_IDS="$SUBNET_IDS $SUBNET_ID"
done

# Create load balancer
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name carastore-alb \
  --subnets $SUBNET_IDS \
  --security-groups $ALB_SG_ID \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

TG_ARN=$(aws elbv2 create-target-group \
  --name carastore-tg \
  --protocol HTTP \
  --port $PORT \
  --vpc-id $VPC_ID \
  --target-type instance \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

export TG_ARN

echo "[INFO] Application load balancer configured"

# Generate self-signed TLS certificate
mkdir -p deployments/ecs/certs
CERT_DIR="deployments/ecs/certs"

# Generate cert + key
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout $CERT_DIR/privateKey.key \
  -out $CERT_DIR/certificate.crt \
  -days 365 \
  -subj "/CN=carastore.local"

echo "[INFO] Certificate and key successfully generated"

# Import the self-signed cert into ACM
CERT_ARN=$(aws acm import-certificate \
  --certificate fileb://$CERT_DIR/certificate.crt \
  --private-key fileb://$CERT_DIR/privateKey.key \
  --region $AWS_REGION \
  --query CertificateArn \
  --output text)

# Create HTTP listener that redirects to HTTPS
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=redirect,RedirectConfig="{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}" \
  --query "Listeners[0].ListenerArn" \
  --output text

# Create HTTPS listener on the ALB that forwards to target group
HTTPS_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --region $AWS_REGION \
  --query "Listeners[0].ListenerArn" \
  --output text)

echo "[INFO] HTTPS listener created: $HTTPS_LISTENER_ARN"

LB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query "LoadBalancers[0].DNSName" \
  --output text)

export VITE_API_URL=https://$LB_DNS_NAME

echo "[INFO] Load balancer created. DNS Name: $LB_DNS_NAME"

# Update client environment with HTTPS API URL
cat > client/.env <<EOF
VITE_API_URL=https://$LB_DNS_NAME
EOF

echo "[INFO] API URL added to client/.env"

# Create key pair
mkdir -p $KEY_PAIR_DIR

if [ ! -f "$KEY_PAIR_DIR/$KEY_NAME.pem" ]; then
  aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --query "KeyMaterial" \
    --output text > "$KEY_PAIR_DIR/$KEY_NAME.pem"

  chmod 400 "$KEY_PAIR_DIR/$KEY_NAME.pem"
  echo "[INFO] Key pair created and saved to $KEY_PAIR_DIR/$KEY_NAME.pem"
else
  echo "[INFO] Key pair already exists at $KEY_PAIR_DIR/$KEY_NAME.pem"
fi

# Launch ECS EC2 instance
cat > "$USER_DATA_FILE" <<EOF
#!/bin/bash
echo ECS_CLUSTER=$CLUSTER_NAME >> /etc/ecs/ecs.config
EOF

echo "[INFO] Launching ECS EC2 instance..."

EC2_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type t3.small \
  --key-name $KEY_NAME \
  --iam-instance-profile Name=$INSTANCE_PROFILE \
  --security-group-ids $ECS_SG_ID \
  --subnet-id $(echo $SUBNET_IDS | awk '{print $1}') \
  --user-data file://"$USER_DATA_FILE" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=carastore-ecs-instance}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "[INFO] Waiting for ECS instance ($EC2_ID) ready state..."
aws ec2 wait instance-status-ok --instance-ids $EC2_ID
sleep 10
echo "[INFO] ECS instance is now healthy and registered with ECS"

# Upload DB init script
EC2_PUBLIC_DNS=$(aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query "Reservations[].Instances[].PublicDnsName" \
  --output text)

# Connect and update system packages before preparing the init dir
ssh -o StrictHostKeyChecking=no -i "$KEY_PAIR_DIR/$KEY_NAME.pem" $EC2_USER@$EC2_PUBLIC_DNS \
  "sudo yum update -y && \
   sudo mkdir -p /ecs/init-sql && \
   sudo chown $EC2_USER:$EC2_USER /ecs/init-sql"

echo "[INFO] EC2 instance updated and init directory prepared"

# Upload the init script
scp -i "$KEY_PAIR_DIR/$KEY_NAME.pem" ./server/db/init.sql \
  "$EC2_USER@$EC2_PUBLIC_DNS:/ecs/init-sql/0_init.sql"

echo "[INFO] Database init script uploaded to ECS instance"

# Create ECS Task Execution Role
aws iam create-role \
  --role-name $TASK_ROLE \
  --assume-role-policy-document file://$PLATFORM_DIR/iam/ecs-task-trust.json || true

aws iam attach-role-policy \
  --role-name $TASK_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true

aws iam attach-role-policy \
  --role-name $TASK_ROLE \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || true

echo "[INFO] ECS task execution role created and policies attached"

# Create log groups
aws logs create-log-group --log-group-name $SERVER_LOG_GROUP || true
aws logs create-log-group --log-group-name $DB_LOG_GROUP || true

# Set retention policy on logs
aws logs put-retention-policy \
  --log-group-name $SERVER_LOG_GROUP \
  --retention-in-days 14

aws logs put-retention-policy \
  --log-group-name $DB_LOG_GROUP \
  --retention-in-days 14

echo "[INFO] Retention policy set"

# Set env variables for CircleCI
source deployments/ecs/scripts/set-circleci-env.sh

echo "[SUCCESS] ECS infrastructure with EC2 launch type successfully created"
echo "          Service will be launched and deployed via CircleCI"