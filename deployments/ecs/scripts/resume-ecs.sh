#!/bin/bash

set -euo pipefail

echo "[INFO] Resuming ECS resources..."

# Load env vars
source deployments/ecs/scripts/export-env.sh

: "${AWS_PROFILE:?Environment variable AWS_PROFILE must be set}"

CLUSTER_NAME="carastore-cluster"
SERVICE_NAME="carastore-service"
CONTAINER_NAME="nodejs-server"
TG_NAME="carastore-tg"
LB_NAME="carastore-alb"

# Restart EC2 instances
EC2_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=carastore-ecs-instance" "Name=instance-state-name,Values=stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -n "$EC2_IDS" ]; then
  aws ec2 start-instances --instance-ids $EC2_IDS
  aws ec2 wait instance-running --instance-ids $EC2_IDS
  echo "[INFO] EC2 instances restarted: $EC2_IDS"
else
  echo "[INFO] No stopped ECS EC2 instances found"
fi

# Recreate Load Balancer listener(s)
LB_ARN=$(aws elbv2 describe-load-balancers \
  --names $LB_NAME \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

TG_ARN=$(aws elbv2 describe-target-groups \
  --names $TG_NAME \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

CERT_ARN=$(aws acm list-certificates \
  --region "$AWS_REGION" \
  --query "CertificateSummaryList[?DomainName=='carastore.local'].CertificateArn" \
  --output text 2>/dev/null || true)

aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

echo "[INFO] Listener recreated for $LB_NAME"

echo "[INFO] Setting container instances back to ACTIVE..."
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
  --cluster $CLUSTER_NAME \
  --query "containerInstanceArns[]" \
  --output text)

if [ -n "$CONTAINER_INSTANCES" ]; then
  aws ecs update-container-instances-state \
    --cluster $CLUSTER_NAME \
    --container-instances $CONTAINER_INSTANCES \
    --status ACTIVE || true
fi

# Scale service back up
aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --desired-count 1

aws ecs wait services-stable \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME

echo "[SUCCESS] ECS environment resumed and service is starting up."